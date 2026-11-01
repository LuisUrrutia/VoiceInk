import AppKit
import Foundation

enum AnnotationSettings {
    /// A shell command run after each annotation, with the summary on standard input; empty runs nothing.
    static let agentCommandKey = "AnnotateAgentCommand"
    static let agentTimeoutKey = "AnnotateAgentTimeoutSeconds"
    static let retentionKey = "AnnotateRetention"
    static let defaultAgentTimeout: TimeInterval = 300

    static func agentCommand(in defaults: UserDefaults = .standard) -> String? {
        let command = defaults.string(forKey: agentCommandKey)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return command.isEmpty ? nil : command
    }

    static func agentTimeout(in defaults: UserDefaults = .standard) -> TimeInterval {
        let value = defaults.double(forKey: agentTimeoutKey)
        return value > 0 ? min(value, 3_600) : defaultAgentTimeout
    }

    /// Fields of General backups; a missing field keeps the current value.
    struct Backup: Codable, Equatable {
        var agentCommand: String?
        var agentTimeoutSeconds: Double?
        var retention: String?

        static func capture(from defaults: UserDefaults = .standard) -> Backup {
            Backup(
                agentCommand: defaults.string(forKey: agentCommandKey) ?? "",
                agentTimeoutSeconds: AnnotationSettings.agentTimeout(in: defaults),
                retention: AnnotationRetention.current(in: defaults).rawValue
            )
        }

        func restore(in defaults: UserDefaults = .standard) {
            if let agentCommand { defaults.set(agentCommand, forKey: agentCommandKey) }
            if let agentTimeoutSeconds, agentTimeoutSeconds > 0 { defaults.set(agentTimeoutSeconds, forKey: agentTimeoutKey) }
            if let retention, AnnotationRetention(rawValue: retention) != nil { defaults.set(retention, forKey: retentionKey) }
        }
    }
}

/// What a configured agent command receives about one annotation, besides the summary on standard input.
enum AnnotationAgentHandoff {
    static let outputFileName = "agent-output.txt"

    /// `VOICEINK_ANNOTATION_DIR`, `_SUMMARY`, `_CONTACT_SHEET` (when rendered) and `_IMAGES` (newline-separated,
    /// the contact sheet first, then each keyframe), all absolute paths.
    static func environment(for manifest: AnnotationManifest, store: AnnotationStore) -> [String: String] {
        let folder = store.directory(for: manifest.id)
        var environment = [
            "VOICEINK_ANNOTATION_DIR": folder.path,
            "VOICEINK_ANNOTATION_SUMMARY": store.url(for: manifest.id, file: AnnotationManifest.summaryFileName).path,
        ]
        var images: [String] = []
        if let sheet = manifest.contactSheet {
            let path = store.url(for: manifest.id, file: sheet).path
            environment["VOICEINK_ANNOTATION_CONTACT_SHEET"] = path
            images.append(path)
        }
        images += manifest.keyframes.compactMap(\.file).map { folder.appendingPathComponent($0).path }
        environment["VOICEINK_ANNOTATION_IMAGES"] = images.joined(separator: "\n")
        return environment
    }

    /// The contact sheet as an image, for chat apps that accept pasted images; false when it does not exist.
    @MainActor
    @discardableResult
    static func copyContactSheet(of manifest: AnnotationManifest, store: AnnotationStore, to pasteboard: NSPasteboard = .general) -> Bool {
        guard let sheet = manifest.contactSheet, let image = NSImage(contentsOf: store.url(for: manifest.id, file: sheet)) else {
            return false
        }
        pasteboard.clearContents()
        return pasteboard.writeObjects([image])
    }
}

/// A finished agent command.
struct AnnotationAgentRun: Codable, Equatable, Sendable {
    var command: String
    var exitStatus: Int32?
    var failure: String?
    var finishedAt: Date
}

protocol AnnotationAgentRunning {
    func run(
        command: String, standardInput: Data, timeout: TimeInterval, environment: [String: String]
    ) async throws -> (status: Int32, output: Data)
}

/// The Local CLI enhancement runner: a login-shell command in its own process group with drained output, a deadline
/// and cancellation that stops the whole group.
struct LoginShellAgentRunner: AnnotationAgentRunning {
    func run(
        command: String, standardInput: Data, timeout: TimeInterval, environment: [String: String]
    ) async throws -> (status: Int32, output: Data) {
        let result = try await LocalCLIProcessRunner.run(
            command: command, standardInput: standardInput, timeout: timeout,
            environment: { ShellCommandEnvironment.commandEnvironment(additionalEnvironment: environment) }
        )
        return (result.status, result.stdout + result.stderr)
    }
}

/// How long annotation files are kept, as Hex's capture retention: heavy media first, then the whole bundle.
/// Bundles still processing or open are never removed.
enum AnnotationRetention: String, CaseIterable, Sendable {
    case week, month, forever

    static let `default` = AnnotationRetention.week
    static let mediaFiles = [AnnotationManifest.videoFileName, AnnotationManifest.narrationFileName]

    var displayName: String {
        switch self {
        case .week: String(localized: "Movie 7 days, rest 30 days")
        case .month: String(localized: "Movie 30 days, rest 90 days")
        case .forever: String(localized: "Forever")
        }
    }

    var mediaDays: Double? {
        switch self {
        case .week: 7
        case .month: 30
        case .forever: nil
        }
    }

    var bundleDays: Double? {
        switch self {
        case .week: 30
        case .month: 90
        case .forever: nil
        }
    }

    static func current(in defaults: UserDefaults = .standard) -> AnnotationRetention {
        defaults.string(forKey: AnnotationSettings.retentionKey).flatMap(AnnotationRetention.init(rawValue:)) ?? .default
    }

    enum Action: Equatable {
        case removeMedia(UUID)
        case removeBundle(UUID)
    }

    func actions(for annotations: [AnnotationManifest], now: Date, isBusy: (UUID) -> Bool) -> [Action] {
        annotations.compactMap { annotation in
            guard annotation.status != .recording, annotation.status != .processing, !isBusy(annotation.id) else { return nil }
            let age = now.timeIntervalSince(annotation.createdAt) / 86_400
            if let bundleDays, age >= bundleDays { return .removeBundle(annotation.id) }
            if let mediaDays, age >= mediaDays { return .removeMedia(annotation.id) }
            return nil
        }
    }
}
