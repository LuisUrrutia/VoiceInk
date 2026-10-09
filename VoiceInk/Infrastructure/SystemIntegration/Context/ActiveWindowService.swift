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
    private var pendingLookup: Task<Void, Never>?

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

    @discardableResult
    func beginApplyingConfiguration(
        modeId: UUID? = nil,
        shouldApply: @escaping @MainActor () -> Bool = { true }
    ) -> Task<Void, Never> {
        guard shouldApply() else { return Task {} }
        pendingLookup?.cancel()
        pendingLookup = nil
        selectionID = UUID()
        let selectionID = selectionID
        let configurations = configurations()

        if let modeId, let config = configurations.first(where: { $0.id == modeId }) {
            apply(config)
            return Task {}
        }

        guard let application = frontmostApplication() else { return Task {} }
        currentApplication = application.runningApplication
        let bundleIdentifier = application.bundleIdentifier
        let enabledConfigurations = configurations.filter(\.isEnabled)
        let quickConfig = enabledConfigurations.first {
            $0.allAppConfigs.contains { $0.bundleIdentifier == bundleIdentifier }
        } ?? enabledConfigurations.first(where: \.isDefault)
        if let quickConfig { apply(quickConfig) }

        let rules = Self.urlRules(in: configurations)
        guard !rules.isEmpty,
            let browser = BrowserType.allCases.first(where: { $0.bundleIdentifier == bundleIdentifier })
        else { return Task {} }

        let task = Task { [weak self] in
            guard let self else { return }
            defer { if self.selectionID == selectionID { self.pendingLookup = nil } }
            do {
                try Task.checkCancellation()
                let url = try await self.currentURL(browser)
                try Task.checkCancellation()
                // Recorder focus changes do not replace the recording's original application.
                guard self.selectionID == selectionID, shouldApply(),
                    application.runningApplication?.isTerminated != true,
                    Self.urlRules(in: self.configurations()) == rules,
                    let config = self.configuration(for: url, rules: rules)
                else { return }
                self.apply(config)
            } catch is CancellationError {
                return
            } catch {
                self.logger.error("Browser URL lookup failed for \(browser.displayName, privacy: .public)")
            }
        }
        pendingLookup = task
        return task
    }

    func applyConfiguration(modeId: UUID? = nil) async {
        await beginApplyingConfiguration(modeId: modeId).value
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
