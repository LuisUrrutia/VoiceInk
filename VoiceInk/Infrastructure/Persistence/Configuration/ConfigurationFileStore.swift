import AppKit
import Combine
import Foundation
import SwiftData

enum ConfigurationLocation {
    enum Variant { case production, development, local }

    static func fileURL(environment: [String: String], home: URL, variant: Variant) -> URL {
        let configured = environment["XDG_CONFIG_HOME"] ?? ""
        let base = configured.hasPrefix("/") ? URL(fileURLWithPath: configured, isDirectory: true)
            : home.appendingPathComponent(".config", isDirectory: true)
        let directory = base.appendingPathComponent("voiceink", isDirectory: true)
        switch variant {
        case .production: return directory.appendingPathComponent("config.jsonc")
        case .development: return directory.appendingPathComponent("dev/config.jsonc")
        case .local: return directory.appendingPathComponent("local/config.jsonc")
        }
    }

    static var current: URL {
        #if LOCAL_BUILD
        let variant = Variant.local
        #elseif DEBUG
        let variant = Variant.development
        #else
        let variant = Variant.production
        #endif
        return fileURL(environment: ProcessInfo.processInfo.environment,
                       home: FileManager.default.homeDirectoryForCurrentUser, variant: variant)
    }
}

@MainActor
final class ConfigurationFileStore: ObservableObject {
    static let shared = ConfigurationFileStore(fileURL: ConfigurationLocation.current)

    let fileURL: URL
    @Published private(set) var errorMessage: String?
    @Published private(set) var isReady = false
    private let defaults: UserDefaults
    private let notifications: NotificationCenter
    private var container: ModelContainer?
    private var document: ConfigurationJSON?
    private var resolvedURL: URL?
    private var lastSnapshot: ConfigurationValue?
    private var subscriptions: [AnyCancellable] = []
    private var pendingSave: Task<Void, Never>?

    init(fileURL: URL, defaults: UserDefaults = .standard, notifications: NotificationCenter = .default) {
        self.fileURL = fileURL
        self.defaults = defaults
        self.notifications = notifications
    }

    deinit { pendingSave?.cancel() }

    func load(into container: ModelContainer) {
        self.container = container
        do {
            let target = fileURL.resolvingSymlinksInPath()
            let data = try readIfPresent(target)
            if let data {
                let document = try ConfigurationJSON(data: data)
                guard let root = document.root.value.object,
                    root["schemaVersion"] == .number(1),
                    Set(root.keys).isSubset(of: ["schemaVersion", "preferences", "dictionary"])
                else { throw ConfigurationError.invalid("Expected schemaVersion 1, preferences and dictionary.") }
                let preferences: [String: ConfigurationValue]
                if let value = root["preferences"] {
                    guard let object = value.object else { throw ConfigurationError.invalid("preferences must be an object.") }
                    preferences = object
                } else { preferences = [:] }
                try ConfigurationPreferences.validate(preferences)
                let dictionary = try root["dictionary"].map { try $0.decoded(as: ConfigurationDictionary.self) }
                try dictionary?.validate()
                // Validate all input before the dictionary transaction or any defaults mutation.
                try dictionary?.apply(to: container)
                try ConfigurationPreferences.apply(preferences, to: defaults)
                self.document = document
            }
            resolvedURL = target
            lastSnapshot = try capture()
            isReady = true
            errorMessage = nil
        } catch { fail(error) }
    }

    func startObserving() {
        guard isReady, subscriptions.isEmpty else { return }
        for name in [UserDefaults.didChangeNotification, ModelContext.didSave, .wordReplacementsDidChange,
                     NSApplication.didResignActiveNotification] {
            notifications.publisher(for: name)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.scheduleSave() }
                .store(in: &subscriptions)
        }
        notifications.publisher(for: NSApplication.willTerminateNotification)
            .sink { [weak self] _ in self?.saveNow() }
            .store(in: &subscriptions)
        saveNow()
    }

    func stopObserving() {
        pendingSave?.cancel()
        pendingSave = nil
        subscriptions.removeAll()
    }

    private func scheduleSave() {
        guard isReady else { return }
        pendingSave?.cancel()
        pendingSave = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        guard isReady else { return }
        pendingSave?.cancel()
        pendingSave = nil
        do {
            let snapshot = try capture()
            let target = fileURL.resolvingSymlinksInPath()
            guard target == resolvedURL, try readIfPresent(target) == document?.data else {
                throw ConfigurationError.externalChange
            }
            guard document == nil || snapshot != lastSnapshot else { return }
            let data: Data
            if let document, let previous = lastSnapshot {
                let updated = Self.mergingChanges(from: previous, to: snapshot, into: document.root.value)
                data = try document.updating(updated)
            } else {
                data = Data("// VoiceInk configuration. Edit while VoiceInk is closed, then reopen it.\n// API keys, model files, recordings and History are stored separately.\n".utf8)
                    + (try snapshot.data()) + Data("\n".utf8)
            }
            let parsed = try ConfigurationJSON(data: data)
            try writeAtomically(data, to: target)
            document = parsed
            lastSnapshot = snapshot
            errorMessage = nil
        } catch { fail(error) }
    }

    private static func mergingChanges(
        from previous: ConfigurationValue, to current: ConfigurationValue, into saved: ConfigurationValue
    ) -> ConfigurationValue {
        guard previous != current else { return saved }
        if let old = previous.object, let new = current.object {
            var result = saved.object ?? [:]
            for key in Set(old.keys).union(new.keys) where old[key] != new[key] {
                if let next = new[key] {
                    result[key] = mergingChanges(from: old[key] ?? .null, to: next, into: result[key] ?? .null)
                } else { result[key] = .null }
            }
            return .object(result)
        }
        return current
    }

    private func capture() throws -> ConfigurationValue {
        guard let container else { throw ConfigurationError.invalid("Storage is not available.") }
        // A fresh context sees writes made by Auto Learn and other background contexts.
        let dictionary = try ConfigurationDictionary.capture(in: ModelContext(container))
        return .object([
            "schemaVersion": .number(1),
            "preferences": .object(try ConfigurationPreferences.capture(from: defaults)),
            "dictionary": try .encoded(dictionary),
        ])
    }

    private func readIfPresent(_ url: URL) throws -> Data? {
        do { return try Data(contentsOf: url) }
        catch CocoaError.fileReadNoSuchFile { return nil }
    }

    private func writeAtomically(_ data: Data, to target: URL) throws {
        let manager = FileManager.default
        let parent = target.deletingLastPathComponent()
        try manager.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let temporary = parent.appendingPathComponent(".config-\(UUID().uuidString).tmp")
        guard manager.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteNoPermission)
        }
        defer { try? manager.removeItem(at: temporary) }
        let handle = try FileHandle(forWritingTo: temporary)
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }
        guard try readIfPresent(target) == document?.data else { throw ConfigurationError.externalChange }
        guard rename(temporary.path, target.path) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }

    private func fail(_ error: Error) {
        isReady = false
        errorMessage = error.localizedDescription
        stopObserving()
    }
}
