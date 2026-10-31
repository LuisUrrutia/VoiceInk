import Foundation
import OSLog
import SwiftData

/// Owns the opt-in History access socket. The preference is machine-local: it stays out of the
/// XDG configuration file and backups so restoring settings never opens a new read channel.
@MainActor
final class HistoryAccessController: ObservableObject {
    static let shared = HistoryAccessController()
    static let enabledKey = "AgentHistoryAccessEnabled"

    enum Status: Equatable {
        case off
        case serving(socketPath: String)
        case unavailable(String)
    }

    @Published private(set) var isEnabled: Bool
    @Published private(set) var status: Status = .off

    private let defaults: UserDefaults
    private let socketURL: URL?
    private var container: ModelContainer?
    private var server: HistoryAccessServer?
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "HistoryAccess")

    init(
        defaults: UserDefaults = .standard,
        socketURL: URL? = HistoryAccess.socketURL(
            storeDirectoryName: VoiceInkPersistence.directoryURL.lastPathComponent)
    ) {
        self.defaults = defaults
        self.socketURL = socketURL
        isEnabled = defaults.bool(forKey: Self.enabledKey)
    }

    func configure(container: ModelContainer) {
        self.container = container
        refresh()
    }

    func setEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: Self.enabledKey)
        isEnabled = enabled
        refresh()
    }

    func shutdown() {
        server?.stop()
        server = nil
        status = .off
    }

    private func refresh() {
        guard isEnabled, let container else {
            shutdown()
            return
        }
        guard server == nil else { return }
        guard let socketURL else {
            status = .unavailable(String(localized: "VoiceInk could not locate its temporary directory."))
            return
        }
        let service = HistoryAccessService(container: container)
        let server = HistoryAccessServer(socketURL: socketURL) { await service.respond(to: $0) }
        do {
            try server.start()
            self.server = server
            status = .serving(socketPath: socketURL.path)
            logger.info("History access socket started")
        } catch {
            status = .unavailable(Self.message(for: error))
            logger.error("History access socket failed to start: \(String(describing: error), privacy: .public)")
        }
    }

    private static func message(for error: Error) -> String {
        switch error as? HistoryAccessServer.StartError {
        case .inUse:
            return String(localized: "Another running copy of this VoiceInk build already serves History.")
        case .pathTooLong:
            return String(localized: "The socket path is too long for macOS.")
        case .unsafeDirectory, .notASocket:
            return String(localized: "The socket location is not private to your account.")
        case .system, nil:
            return String(localized: "VoiceInk could not open the History access socket.")
        }
    }
}
