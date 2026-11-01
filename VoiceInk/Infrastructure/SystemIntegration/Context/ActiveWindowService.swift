import AppKit
import Foundation
import os

@MainActor
class ActiveWindowService: ObservableObject {
    struct Application {
        let bundleIdentifier: String
        var runningApplication: NSRunningApplication?
    }

    private struct URLRules: Equatable {
        let modeID: UUID
        let urls: [String]
    }

    static let shared = ActiveWindowService()
    @Published var currentApplication: NSRunningApplication?

    private let frontmostApplication: () -> Application?
    private let configurations: () -> [ModeConfig]
    private let apply: (ModeConfig) -> Void
    private let currentURL: (BrowserType) async throws -> String
    private var selectionID = UUID()

    private let logger = Logger(
        subsystem: "com.prakashjoshipax.voiceink",
        category: "browser.detection"
    )

    init(
        frontmostApplication: @escaping () -> Application? = {
            guard let app = NSWorkspace.shared.frontmostApplication,
                let bundleIdentifier = app.bundleIdentifier
            else { return nil }
            return Application(bundleIdentifier: bundleIdentifier, runningApplication: app)
        },
        configurations: @escaping () -> [ModeConfig] = { ModeManager.shared.configurations },
        apply: @escaping (ModeConfig) -> Void = { ModeManager.shared.setActiveConfiguration($0) },
        currentURL: @escaping (BrowserType) async throws -> String = {
            try await BrowserURLService.shared.getCurrentURL(from: $0)
        }
    ) {
        self.frontmostApplication = frontmostApplication
        self.configurations = configurations
        self.apply = apply
        self.currentURL = currentURL
    }

    /// Applies the recording's mode and returns it to the recording; nil means no decision.
    /// A later request never cancels an earlier lookup, but only the newest one updates the global mode.
    @discardableResult
    func beginApplyingConfiguration(
        modeId: UUID? = nil,
        shouldApply: @escaping @MainActor () -> Bool = { true }
    ) -> Task<UUID?, Never> {
        guard shouldApply() else { return Task { nil } }
        selectionID = UUID()
        let selectionID = selectionID
        let configurations = configurations()

        if let modeId, let config = configurations.first(where: { $0.id == modeId }) {
            apply(config)
            return Task { config.id }
        }

        guard let application = frontmostApplication() else { return Task { nil } }
        currentApplication = application.runningApplication
        let bundleIdentifier = application.bundleIdentifier
        let enabledConfigurations = configurations.filter(\.isEnabled)
        let quickConfig = enabledConfigurations.first {
            $0.allAppConfigs.contains { $0.bundleIdentifier == bundleIdentifier }
        } ?? enabledConfigurations.first(where: \.isDefault)
        if let quickConfig { apply(quickConfig) }
        let fallbackID = quickConfig?.id

        let rules = Self.urlRules(in: configurations)
        guard !rules.isEmpty,
            let browser = BrowserType.allCases.first(where: { $0.bundleIdentifier == bundleIdentifier })
        else { return Task { fallbackID } }

        return Task { [weak self] in
            guard let self else { return fallbackID }
            do {
                try Task.checkCancellation()
                let url = try await self.currentURL(browser)
                try Task.checkCancellation()
                // Recorder focus changes do not replace the recording's original application.
                guard shouldApply(),
                    application.runningApplication?.isTerminated != true,
                    Self.urlRules(in: self.configurations()) == rules,
                    let config = self.configuration(for: url, rules: rules)
                else { return fallbackID }
                if self.selectionID == selectionID { self.apply(config) }
                return config.id
            } catch is CancellationError {
                return fallbackID
            } catch {
                self.logger.error("Browser URL lookup failed for \(browser.displayName, privacy: .public)")
                return fallbackID
            }
        }
    }

    func applyConfiguration(modeId: UUID? = nil) async {
        _ = await beginApplyingConfiguration(modeId: modeId).value
    }

    private static func urlRules(in configurations: [ModeConfig]) -> [URLRules] {
        configurations.filter(\.isEnabled).compactMap {
            let urls = $0.allURLConfigs.map { ModeManager.normalizedURL($0.url) }.filter { !$0.isEmpty }
            return urls.isEmpty ? nil : URLRules(modeID: $0.id, urls: urls)
        }
    }

    private func configuration(for url: String, rules: [URLRules]) -> ModeConfig? {
        let cleanedURL = ModeManager.normalizedURL(url)
        guard let rule = rules.first(where: {
            $0.urls.contains { cleanedURL.contains($0) }
        }) else { return nil }
        return configurations().first { $0.id == rule.modeID && $0.isEnabled }
    }
}
