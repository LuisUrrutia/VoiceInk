import AVFoundation
import Combine
import CoreAudio
import Foundation
import os

@MainActor
class Recorder: NSObject, ObservableObject {
    var recorder: (any RecordingHardware)? {
        didSet { preRollPress.bind(recorder) }
    }
    nonisolated let preRollPress = RecordingPreRollPress()
    let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "Recorder")
    let deviceManager: AudioDeviceManager
    private let defaults: UserDefaults
    private let isMicrophoneAuthorized: @MainActor () -> Bool
    private var isPreRollObserverAvailable: @MainActor () -> Bool
    @Published private(set) var hasPreRollObserver = false
    private var lifecycleCancellable: AnyCancellable?
    private var keepReadyCancellable: AnyCancellable?
    private var permissionCheckCancellable: AnyCancellable?
    private var observerAvailabilityCancellable: AnyCancellable?
    private var isSystemSleeping = false
    var recordingDeviceChangeObserver: NSObjectProtocol?
    var recordingDeviceNotificationTask: Task<Void, Never>?
    private let mediaController = MediaController.shared
    private let playbackController = PlaybackController.shared
    /// Dedicated serial queue for hardware setup.
    let audioSetupQueue = DispatchQueue(label: "com.prakashjoshipax.voiceink.audioSetup", qos: .userInitiated)
    private let recordingAudioActionDelayNanoseconds: UInt64 = 220_000_000
    private var audioMuteTask: Task<Void, Never>?
    private var mediaPauseTask: Task<Void, Never>?
    private var audioRestorationTask: Task<Void, Never>?
    private var playbackSessionID: UUID?
    private var recordingStartID: UUID?
    private var hasStoppedRecording = false
    private let recordingFinalization = RecordingFinalization()
    private(set) var recordingError: Error?
    var firstAudioTimestampNanoseconds: UInt64? { recorder?.firstAudioTimestampNanoseconds }
    private let smoothedValuesLock = NSLock()
    private var smoothedAverage: Float = 0
    private var smoothedPeak: Float = 0

    /// Audio chunk callback for streaming. Can be updated while recording;
    /// changes are forwarded to the live CoreAudioRecorder.
    var onAudioChunk: ((_ data: Data) -> Void)? {
        didSet { recorder?.onAudioChunk = onAudioChunk }
    }

    enum RecorderError: Error {
        case couldNotStartRecording
        case noUsableMicrophone(internalMicrophoneBlockedByClosedLid: Bool)
        case audioSystemNotRunning
    }

    init(
        hardware: (any RecordingHardware)? = nil, deviceManager: AudioDeviceManager = .shared,
        defaults: UserDefaults = .standard,
        isMicrophoneAuthorized: @escaping @MainActor () -> Bool = {
            AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        },
        isPreRollObserverAvailable: @escaping @MainActor () -> Bool = { false }
    ) {
        self.deviceManager = deviceManager
        self.defaults = defaults
        self.isMicrophoneAuthorized = isMicrophoneAuthorized
        self.isPreRollObserverAvailable = isPreRollObserverAvailable
        recorder = hardware
        super.init()
        preRollPress.bind(hardware)
        lifecycleCancellable = LifecycleObserver.shared.publisher(
            for: [.audioDeviceChanged, .systemWillSleep, .systemDidWake, .applicationDidBecomeActive]
        ).sink { [weak self] event in
            Task { @MainActor in
                self?.handleLifecycleEvent(event)
            }
        }
        keepReadyCancellable = defaults.publisher(for: \.keepMicrophoneReady, options: [.new])
            .removeDuplicates()
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.updateIdleCapture(reason: "setting")
                }
            }
        observerAvailabilityCancellable = NotificationCenter.default.publisher(for: ShortcutMonitor.captureAvailabilityDidChange)
            .sink { [weak self] _ in
                Task { @MainActor in self?.updateIdleCapture(reason: "shortcut-observer") }
            }
        setupRecordingDeviceChangeObserver()
        schedulePrepareForCurrentDevice(reason: "init")
        updateIdleCapture(reason: "init")
    }

    func startMicrophoneTest(toOutputFile url: URL) async throws {
        try await startRecording(toOutputFile: url, applyRecordingEffects: false)
    }

    func setPreRollObserverProvider(_ provider: @escaping @MainActor () -> Bool) {
        isPreRollObserverAvailable = provider
        updateIdleCapture(reason: "observer-provider")
    }

    /// Retains idle pre-roll for a press until its recording starts; a no-op unless the microphone is kept ready.
    func holdPreRoll(forPressAt pressNanoseconds: UInt64) {
        recorder?.holdPreRoll(forPressAt: pressNanoseconds)
    }

    func startRecording(
        toOutputFile url: URL, applyRecordingEffects: Bool = true, preRollPressNanoseconds: UInt64? = nil
    ) async throws {
        await recordingFinalization.waitUntilFinished()
        try Task.checkCancellation()
        recordingError = nil
        let resolution = deviceManager.resolveCurrentRecordingDevice()
        guard var deviceID = resolution.deviceID else {
            onAudioChunk = nil
            throw RecorderError.noUsableMicrophone(
                internalMicrophoneBlockedByClosedLid: resolution.internalMicrophoneBlockedByClosedLid
            )
        }

        deviceManager.beginRecordingSetup(deviceID: deviceID)

        let playbackSessionID = playbackController.beginRecordingSession()
        self.playbackSessionID = playbackSessionID
        recordingStartID = playbackSessionID
        hasStoppedRecording = false
        mediaController.beginRecordingSession(sessionID: playbackSessionID)
        audioRestorationTask?.cancel()
        audioRestorationTask = nil
        if applyRecordingEffects {
            pauseMedia(sessionID: playbackSessionID)
            muteSystemAudio(sessionID: playbackSessionID)
        }

        let coreAudioRecorder = recorder ?? CoreAudioRecorder()
        coreAudioRecorder.onAudioChunk = onAudioChunk
        recorder = coreAudioRecorder

        hasPreRollObserver = isPreRollObserverAvailable()
        let canUsePreRoll = defaults.keepMicrophoneReady && hasPreRollObserver
        if !canUsePreRoll {
            audioSetupQueue.async { coreAudioRecorder.stopIdleCapture() }
        }

        do {
            do {
                try await startHardwareRecording(
                    coreAudioRecorder, to: url, deviceID: deviceID,
                    preRollPressNanoseconds: canUsePreRoll ? preRollPressNanoseconds : nil
                )
            } catch {
                guard recordingStartID == playbackSessionID else { throw CancellationError() }
                let retryResolution = deviceManager.resolveCurrentRecordingDevice(excluding: deviceID)
                guard deviceManager.isClamshellClosed,
                    deviceManager.isInternalMicrophone(deviceID),
                    let fallbackDeviceID = retryResolution.deviceID
                else {
                    throw error
                }

                deviceID = fallbackDeviceID
                deviceManager.beginRecordingSetup(deviceID: fallbackDeviceID)
                try await startHardwareRecording(
                    coreAudioRecorder, to: url, deviceID: fallbackDeviceID, preRollPressNanoseconds: nil
                )
            }

            guard recordingStartID == playbackSessionID else { throw CancellationError() }
            deviceManager.recordingDidStart(deviceID: deviceID)
            showRecordingDeviceNotification(for: deviceID)
            resetAudioMeter()
        } catch {
            guard recordingStartID == playbackSessionID else { throw CancellationError() }
            logger.error(
                "Failed to start recording deviceID=\(deviceID, privacy: .public) file=\(url.lastPathComponent, privacy: .public) error=\(error, privacy: .public)"
            )
            await stopRecording()
            if (error as? CoreAudioRecorderError)?.status == kAudioHardwareNotRunningError {
                throw RecorderError.audioSystemNotRunning
            }
            throw error
        }
    }

    func stopRecording() async {
        await finishRecording(releaseTail: nil)
    }

    /// Restores output and plays the release tone now, then keeps capturing through the tail.
    @discardableResult
    func stopRecording(
        after releaseTail: RecordingReleaseTail,
        playReleaseTone: @escaping @MainActor () -> Void,
        shouldEndTailEarly: @escaping @MainActor () -> Bool
    ) async -> RecordingReleaseTail.Outcome? {
        await finishRecording(
            releaseTail: (releaseTail, playReleaseTone, shouldEndTailEarly)
        )
    }

    private func finishRecording(
        releaseTail: (
            tail: RecordingReleaseTail,
            playTone: @MainActor () -> Void,
            shouldEndEarly: @MainActor () -> Bool
        )?
    ) async -> RecordingReleaseTail.Outcome? {
        guard let finalizationID = recordingFinalization.begin() else {
            await recordingFinalization.waitUntilFinished()
            return nil
        }
        defer { recordingFinalization.finish(finalizationID) }

        recordingDeviceNotificationTask?.cancel()
        recordingDeviceNotificationTask = nil
        guard !hasStoppedRecording else { return nil }
        hasStoppedRecording = true
        recordingStartID = nil
        let playbackSessionID = self.playbackSessionID
        audioMuteTask?.cancel()
        audioMuteTask = nil
        mediaPauseTask?.cancel()
        mediaPauseTask = nil
        // Capture current recorder to stop it on the serial hardware queue.
        let currentRecorder = self.recorder

        var tailOutcome: RecordingReleaseTail.Outcome?
        if let releaseTail {
            restoreRecordingAudio(sessionID: playbackSessionID, afterOutputUnmuted: releaseTail.playTone)
            tailOutcome = await releaseTail.tail.waitForCapture(
                capturedThrough: { currentRecorder?.capturedThroughNanoseconds },
                shouldEndEarly: releaseTail.shouldEndEarly
            )
        }

        let failure = await withCheckedContinuation { continuation in
            audioSetupQueue.async {
                currentRecorder?.stopRecording()
                continuation.resume(returning: currentRecorder?.recordingError)
            }
        }
        guard self.playbackSessionID == playbackSessionID else { return tailOutcome }
        recordingError = failure
        onAudioChunk = nil

        resetAudioMeter()

        if releaseTail == nil {
            restoreRecordingAudio(sessionID: playbackSessionID, afterOutputUnmuted: nil)
        }
        deviceManager.recordingDidStop()
        updateIdleCapture(reason: "recording-stopped")
        return tailOutcome
    }

    private func restoreRecordingAudio(
        sessionID: UUID?, afterOutputUnmuted: (@MainActor () -> Void)?
    ) {
        audioRestorationTask?.cancel()
        audioRestorationTask = Task { [mediaController, playbackController] in
            if let sessionID {
                await mediaController.unmuteSystemAudio(sessionID: sessionID)
            }
            // A muted output must be audible before the release tone plays.
            if let afterOutputUnmuted, !Task.isCancelled {
                afterOutputUnmuted()
            }
            if let sessionID {
                await playbackController.resumeMedia(sessionID: sessionID)
            }
        }
    }

    private func muteSystemAudio(sessionID: UUID) {
        audioMuteTask?.cancel()
        audioMuteTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: self.recordingAudioActionDelayNanoseconds)
            guard !Task.isCancelled else { return }
            _ = self.mediaController.muteSystemAudio(sessionID: sessionID)
        }
    }

    private func pauseMedia(sessionID: UUID) {
        mediaPauseTask?.cancel()
        mediaPauseTask = Task { [weak self] in
            guard let self else { return }
            await self.playbackController.pauseMedia(sessionID: sessionID)
        }
    }

    private func schedulePrepareForCurrentDevice(reason: String) {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            return
        }

        let deviceID = deviceManager.getCurrentDevice()
        guard deviceID != 0 else {
            recorder?.teardown()
            return
        }

        let coreAudioRecorder = recorder ?? CoreAudioRecorder()
        coreAudioRecorder.onAudioChunk = onAudioChunk
        recorder = coreAudioRecorder

        let selectedChannels = deviceManager.selectedInputChannels(for: deviceID)
        audioSetupQueue.async { [logger] in
            do {
                try coreAudioRecorder.prepare(deviceID: deviceID, selectedInputChannels: selectedChannels)
            } catch {
                logger.warning(
                    "Recorder prepare failed reason=\(reason, privacy: .public) deviceID=\(deviceID, privacy: .public) error=\(error, privacy: .public)"
                )
            }
        }
    }

    func handleLifecycleEvent(_ event: LifecycleObserver.Event) {
        switch event {
        case .systemWillSleep:
            isSystemSleeping = true
            invalidatePreparedAudioUnit()
        case .systemDidWake:
            isSystemSleeping = false
            invalidatePreparedAudioUnit()
            updateIdleCapture(reason: "wake")
        case .audioDeviceChanged:
            // Idle capture follows the newly resolved input; a recording keeps its own switching path.
            if shouldKeepMicrophoneReady {
                updateIdleCapture(reason: "device-change")
            } else {
                invalidatePreparedAudioUnit()
            }
        case .applicationDidBecomeActive:
            updateIdleCapture(reason: "activation")
        case .displaysDidWake, .screenConfigurationChanged:
            break
        }
    }

    private var shouldKeepMicrophoneReady: Bool {
        defaults.keepMicrophoneReady && !isSystemSleeping && isMicrophoneAuthorized() && isPreRollObserverAvailable()
    }

    /// Opens or closes the idle microphone; an open microphone is not an active recording.
    func updateIdleCapture(reason: String) {
        hasPreRollObserver = isPreRollObserverAvailable()
        // A recording owns the input; stopping it reconciles idle capture again.
        guard !deviceManager.isRecordingActive else { return }

        let deviceID = shouldKeepMicrophoneReady ? deviceManager.resolveCurrentRecordingDevice().deviceID : nil
        updatePermissionChecks(enabled: defaults.keepMicrophoneReady && !isSystemSleeping && isMicrophoneAuthorized())
        guard let deviceID else {
            if let hardware = recorder {
                audioSetupQueue.async { hardware.stopIdleCapture() }
            }
            return
        }

        let hardware = recorder ?? CoreAudioRecorder()
        hardware.onAudioChunk = onAudioChunk
        recorder = hardware
        let selectedChannels = deviceManager.selectedInputChannels(for: deviceID)
        audioSetupQueue.async { [logger] in
            do {
                try hardware.startIdleCapture(deviceID: deviceID, selectedInputChannels: selectedChannels)
            } catch {
                logger.warning(
                    "Idle capture failed reason=\(reason, privacy: .public) deviceID=\(deviceID, privacy: .public) error=\(error, privacy: .public)"
                )
                hardware.invalidatePreparation()
            }
        }
    }

    /// Permission revocation and silent tap failures have no reliable change notification.
    private func updatePermissionChecks(enabled: Bool) {
        guard enabled else {
            permissionCheckCancellable = nil
            return
        }
        guard permissionCheckCancellable == nil else { return }
        permissionCheckCancellable = Timer.publish(every: 5, tolerance: 1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.updateIdleCapture(reason: "readiness-check")
            }
    }

    private func invalidatePreparedAudioUnit() {
        guard let coreAudioRecorder = recorder else { return }
        audioSetupQueue.async {
            coreAudioRecorder.invalidatePreparation()
        }
    }

    func audioMeterSnapshot() -> AudioMeter {
        guard let recorder else {
            return AudioMeter(averagePower: 0, peakPower: 0)
        }

        // Sample audio levels (thread-safe read)
        let averagePower = recorder.averagePower
        let peakPower = recorder.peakPower

        // Normalize values
        let minVisibleDb: Float = -60.0
        let maxVisibleDb: Float = 0.0

        let normalizedAverage: Float
        if averagePower < minVisibleDb {
            normalizedAverage = 0.0
        } else if averagePower >= maxVisibleDb {
            normalizedAverage = 1.0
        } else {
            normalizedAverage = (averagePower - minVisibleDb) / (maxVisibleDb - minVisibleDb)
        }

        let normalizedPeak: Float
        if peakPower < minVisibleDb {
            normalizedPeak = 0.0
        } else if peakPower >= maxVisibleDb {
            normalizedPeak = 1.0
        } else {
            normalizedPeak = (peakPower - minVisibleDb) / (maxVisibleDb - minVisibleDb)
        }

        // Apply EMA smoothing with thread-safe access
        smoothedValuesLock.lock()
        smoothedAverage = smoothedAverage * 0.6 + normalizedAverage * 0.4
        smoothedPeak = smoothedPeak * 0.6 + normalizedPeak * 0.4
        let audioMeter = AudioMeter(
            averagePower: Double(smoothedAverage),
            peakPower: Double(smoothedPeak)
        )
        smoothedValuesLock.unlock()

        return audioMeter
    }

    private func resetAudioMeter() {
        smoothedValuesLock.lock()
        smoothedAverage = 0
        smoothedPeak = 0
        smoothedValuesLock.unlock()
    }

    // MARK: - Cleanup

    deinit {
        recordingDeviceNotificationTask?.cancel()
        audioMuteTask?.cancel()
        mediaPauseTask?.cancel()
        audioRestorationTask?.cancel()
        if let observer = recordingDeviceChangeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        recorder?.teardown()
    }
}

struct AudioMeter: Equatable {
    let averagePower: Double
    let peakPower: Double
}
