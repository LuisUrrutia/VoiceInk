import AppKit

struct PasteApplication: Equatable {
    let processID: pid_t
    let bundleIdentifier: String?
    var launchDate: Date? = nil

    init(processID: pid_t, bundleIdentifier: String?, launchDate: Date? = nil) {
        self.processID = processID
        self.bundleIdentifier = bundleIdentifier
        self.launchDate = launchDate
    }

    init(_ application: NSRunningApplication) {
        self.init(
            processID: application.processIdentifier,
            bundleIdentifier: application.bundleIdentifier,
            launchDate: application.launchDate
        )
    }

    @MainActor static var frontmost: PasteApplication? {
        NSWorkspace.shared.frontmostApplication.map(PasteApplication.init)
    }

    var runningApplication: NSRunningApplication? {
        guard let application = NSRunningApplication(processIdentifier: processID),
            !application.isTerminated,
            PasteApplication(application) == self
        else { return nil }
        return application
    }
}

enum PasteDestination: Equatable {
    case currentApplication
    case originalApplication(PasteApplication?)
}

enum PasteTargetSettings {
    static let key = "PinPasteTargetToRecordStart"
    static let remoteClipboardPushCommandKey = "remoteClipboardPushCommand"

    static func isEnabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: key) as? Bool ?? true
    }
}

@MainActor
final class RecordingDeliverySession {
    let destination: PasteDestination
    private(set) var isCancelled = false
    private var cancelPendingTask: (() -> Void)?

    init(destination: PasteDestination) {
        self.destination = destination
    }

    static func capture(
        defaults: UserDefaults = .standard,
        frontmost: @MainActor () -> PasteApplication? = { .frontmost }
    ) -> RecordingDeliverySession {
        RecordingDeliverySession(
            destination: PasteTargetSettings.isEnabled(in: defaults)
                ? .originalApplication(frontmost()) : .currentApplication
        )
    }

    func own<Result>(_ task: Task<Result, Never>) {
        cancelPendingTask = { task.cancel() }
        if isCancelled { task.cancel() }
    }

    func cancel() {
        isCancelled = true
        cancelPendingTask?()
        cancelPendingTask = nil
    }
}
