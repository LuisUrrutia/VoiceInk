import AppKit
import CoreAudio
import Foundation

/// Mute and Lower act on the same output, so they are exclusive; Pause Media stays independent.
enum RecordingOutputAudioBehavior: Hashable {
    case unchanged, mute, lower

    /// Mute takes precedence when an edited configuration enables both.
    init(isMuteEnabled: Bool, isLoweringEnabled: Bool) {
        self = isMuteEnabled ? .mute : isLoweringEnabled ? .lower : .unchanged
    }
}

@MainActor
final class MediaController: ObservableObject {

    static let shared = MediaController()

    nonisolated static let muteKey = "isSystemMuteEnabled"
    nonisolated static let loweringKey = "isSystemAudioLoweringEnabled"
    nonisolated static let loweringLevelKey = "systemAudioLoweringLevel"
    nonisolated static let defaultLoweringLevel = 0.2

    // Keep responsibility across rapid recordings, including output-device changes.
    private var mutedDevices: Set<AudioDeviceID> = []
    private var recordingSessionID = UUID()
    private let defaults: UserDefaults
    private let outputLowering: OutputVolumeLowering
    private var loweredOutputRestorationSessionID: UUID?
    private var loweredOutputRestorationWaiters: [CheckedContinuation<Void, Never>] = []
    private let notificationCenter: NotificationCenter
    private var terminationObserver: NSObjectProtocol?

    @Published var isSystemMuteEnabled: Bool {
        didSet {
            defaults.set(isSystemMuteEnabled, forKey: Self.muteKey)
            if isSystemMuteEnabled { isSystemAudioLoweringEnabled = false }
        }
    }

    @Published var isSystemAudioLoweringEnabled: Bool {
        didSet {
            defaults.set(isSystemAudioLoweringEnabled, forKey: Self.loweringKey)
            if isSystemAudioLoweringEnabled { isSystemMuteEnabled = false }
        }
    }

    @Published private var storedLoweringLevel: Double {
        didSet { defaults.set(storedLoweringLevel, forKey: Self.loweringLevelKey) }
    }

    /// Fraction of each output channel's volume kept while recording.
    var systemAudioLoweringLevel: Double {
        get { storedLoweringLevel }
        set { storedLoweringLevel = Self.clampedLevel(newValue) }
    }

    @Published var audioResumptionDelay: Double {
        didSet { defaults.set(audioResumptionDelay, forKey: "audioResumptionDelay") }
    }

    var recordingOutputBehavior: RecordingOutputAudioBehavior {
        get { RecordingOutputAudioBehavior(isMuteEnabled: isSystemMuteEnabled, isLoweringEnabled: isSystemAudioLoweringEnabled) }
        set {
            isSystemMuteEnabled = newValue == .mute
            isSystemAudioLoweringEnabled = newValue == .lower
        }
    }

    var isRestoringLoweredOutput: Bool { loweredOutputRestorationSessionID != nil }

    init(
        defaults: UserDefaults = .standard,
        outputLowering: OutputVolumeLowering? = nil,
        notificationCenter: NotificationCenter = .default
    ) {
        self.defaults = defaults
        self.outputLowering = outputLowering ?? OutputVolumeLowering()
        self.notificationCenter = notificationCenter
        let behavior = RecordingOutputAudioBehavior(
            isMuteEnabled: defaults.bool(forKey: Self.muteKey),
            isLoweringEnabled: defaults.bool(forKey: Self.loweringKey)
        )
        isSystemMuteEnabled = behavior == .mute
        isSystemAudioLoweringEnabled = behavior == .lower
        storedLoweringLevel = Self.clampedLevel(
            defaults.object(forKey: Self.loweringLevelKey) as? Double ?? Self.defaultLoweringLevel
        )
        audioResumptionDelay = defaults.double(forKey: "audioResumptionDelay")
        terminationObserver = notificationCenter.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.outputLowering.restoreImmediately() }
        }
    }

    deinit {
        if let terminationObserver { notificationCenter.removeObserver(terminationObserver) }
    }

    nonisolated static func clampedLevel(_ level: Double) -> Double {
        level.isFinite ? min(max(level, 0), 1) : defaultLoweringLevel
    }

    func beginRecordingSession(sessionID: UUID) {
        // Invalidate delayed restoration before the recorder's 220 ms mute delay.
        recordingSessionID = sessionID
        finishLoweredOutputRestoration(for: nil)
    }

    func muteSystemAudio(sessionID: UUID) -> Bool {
        guard sessionID == recordingSessionID, !Task.isCancelled, isSystemMuteEnabled else { return false }
        guard let deviceID = CoreAudioOutputVolumeSystem().defaultOutputDevice(),
            let currentlyMuted = isSystemAudioMuted(deviceID: deviceID) else {
            return false
        }
        // A device already muted by the user is never added to our ownership.
        guard !currentlyMuted else { return true }
        guard setSystemMuted(true, deviceID: deviceID) else {
            return false
        }
        mutedDevices.insert(deviceID)
        return true
    }

    /// Reads the level now, so changes apply to the next recording.
    @discardableResult
    func lowerSystemAudio(sessionID: UUID) -> Bool {
        guard sessionID == recordingSessionID, !Task.isCancelled, recordingOutputBehavior == .lower else {
            return false
        }
        return outputLowering.lower(to: systemAudioLoweringLevel)
    }

    func restoreSystemAudio(sessionID: UUID) async {
        guard sessionID == recordingSessionID, !Task.isCancelled,
            !mutedDevices.isEmpty || outputLowering.ownsOutput
        else { return }
        if outputLowering.ownsOutput { loweredOutputRestorationSessionID = sessionID }
        let delay = audioResumptionDelay
        if delay > 0 {
            do {
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            } catch {
                finishLoweredOutputRestoration(for: sessionID)
                return
            }
        }
        guard sessionID == recordingSessionID, !Task.isCancelled else {
            finishLoweredOutputRestoration(for: sessionID)
            return
        }

        // Restore the devices we actually muted, rather than the current default.
        // Restore ownership even if the preference was disabled during recording.
        for deviceID in Array(mutedDevices) {
            if setSystemMuted(false, deviceID: deviceID) {
                mutedDevices.remove(deviceID)
            }
        }

        guard outputLowering.ownsOutput else {
            finishLoweredOutputRestoration(for: sessionID)
            return
        }
        // Media resumption does not wait for the ramp; the stop tone does.
        let outputLowering = outputLowering
        Task { [weak self] in
            await outputLowering.restore()
            self?.finishLoweredOutputRestoration(for: sessionID)
        }
    }

    /// Returns once a pending restoration of lowered output finishes or a newer recording supersedes it.
    func waitForLoweredOutputRestoration() async {
        guard isRestoringLoweredOutput else { return }
        await withCheckedContinuation { loweredOutputRestorationWaiters.append($0) }
    }

    private func finishLoweredOutputRestoration(for sessionID: UUID?) {
        guard sessionID == nil || sessionID == loweredOutputRestorationSessionID else { return }
        loweredOutputRestorationSessionID = nil
        let waiters = loweredOutputRestorationWaiters
        loweredOutputRestorationWaiters = []
        waiters.forEach { $0.resume() }
    }

    private func isSystemAudioMuted(deviceID: AudioDeviceID) -> Bool? {
        var muted: UInt32 = 0
        var propertySize = UInt32(MemoryLayout<UInt32>.size)

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        if !AudioObjectHasProperty(deviceID, &address) {
            address.mElement = 0
            if !AudioObjectHasProperty(deviceID, &address) { return nil }
        }

        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &propertySize, &muted)
        return status == noErr ? muted != 0 : nil
    }

    private func setSystemMuted(_ muted: Bool, deviceID: AudioDeviceID) -> Bool {
        var muteValue: UInt32 = muted ? 1 : 0
        let propertySize = UInt32(MemoryLayout<UInt32>.size)

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        if !AudioObjectHasProperty(deviceID, &address) {
            address.mElement = 0
            if !AudioObjectHasProperty(deviceID, &address) { return false }
        }

        var isSettable: DarwinBoolean = false
        var status = AudioObjectIsPropertySettable(deviceID, &address, &isSettable)
        if status != noErr || !isSettable.boolValue { return false }

        status = AudioObjectSetPropertyData(deviceID, &address, 0, nil, propertySize, &muteValue)
        return status == noErr
    }
}
