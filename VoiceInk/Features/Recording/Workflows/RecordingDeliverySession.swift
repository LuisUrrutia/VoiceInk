import AppKit

struct PasteApplication: Hashable {
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
    let timing: RecordingTimingTrace
    private(set) var isCancelled = false
    /// Set at the first clipboard write or typed chunk, after which a user cancellation is refused.
    private(set) var hasCommittedOutput = false
    private(set) var feedback = DictationFeedback()
    private var completedPipeline = false
    private var cancelPendingTask: (() -> Void)?
    private var idleSleepHold: IdleSleepPrevention.Hold?
    private var modelUseLease: IdleModelUnloadCoordinator.Lease?
    private let playFeedback: @MainActor (DictationFeedback.Tone) -> Void
    private let now: () -> TimeInterval

    init(
        destination: PasteDestination,
        timing: RecordingTimingTrace = RecordingTimingTrace(),
        playFeedback: (@MainActor (DictationFeedback.Tone) -> Void)? = nil,
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.destination = destination
        self.timing = timing
        self.playFeedback = playFeedback ?? DictationFeedback.playWithSoundManager
        self.now = now
    }

    static func capture(
        defaults: UserDefaults = .standard,
        frontmost: @MainActor () -> PasteApplication? = { .frontmost },
        shortcutPressNanoseconds: UInt64? = nil
    ) -> RecordingDeliverySession {
        let receivedAt = DispatchTime.now().uptimeNanoseconds
        return RecordingDeliverySession(
            destination: PasteTargetSettings.isEnabled(in: defaults)
                ? .originalApplication(frontmost()) : .currentApplication,
            timing: RecordingTimingTrace(
                originNanoseconds: shortcutPressNanoseconds ?? receivedAt,
                requestReceivedNanoseconds: receivedAt
            )
        )
    }

    func own<Result, Failure: Error>(_ task: Task<Result, Failure>) {
        cancelPendingTask = { task.cancel() }
        if isCancelled { task.cancel() }
    }

    /// Keeps the hold until this session ends: pipeline completion, failed start or cancellation.
    func preventIdleSleep(_ hold: IdleSleepPrevention.Hold) {
        guard !isCancelled else { return hold.release() }
        idleSleepHold?.release()
        idleSleepHold = hold
    }

    /// Keeps local models from an idle unload until this session ends, like the idle-sleep hold.
    func holdModelUse(_ lease: IdleModelUnloadCoordinator.Lease) {
        guard !isCancelled else { return lease.release() }
        modelUseLease?.release()
        modelUseLease = lease
    }

    /// Ends the session like `cancel()`, but a stop tone still waiting for restored output plays.
    func completePipeline() {
        if !isCancelled { completedPipeline = true }
        cancel()
    }

    /// The commit point: false once the session is canceled, so a canceled dictation inserts nothing.
    func commitOutput() -> Bool {
        guard !isCancelled else { return false }
        hasCommittedOutput = true
        return true
    }

    /// A user's Cancel, which stops a dictation only before its output begins; teardown uses `cancel()`.
    @discardableResult
    func cancelBeforeOutput() -> Bool {
        guard !hasCommittedOutput else { return false }
        cancel()
        return true
    }

    func cancel() {
        isCancelled = true
        cancelPendingTask?()
        cancelPendingTask = nil
        idleSleepHold?.release()
        idleSleepHold = nil
        modelUseLease?.release()
        modelUseLease = nil
    }

    // Canceled and superseded sessions stay silent.
    func recordingStopped() {
        guard !isCancelled || completedPipeline, let tone = feedback.recordingStopped(at: now()) else { return }
        playFeedback(tone)
    }

    func pasteFinished(_ result: CursorPaster.PasteResult) {
        guard !isCancelled, let tone = feedback.pasteFinished(result, at: now()) else { return }
        playFeedback(tone)
    }

    func dictationFailed() {
        guard !isCancelled, let tone = feedback.failed() else { return }
        playFeedback(tone)
    }
}
