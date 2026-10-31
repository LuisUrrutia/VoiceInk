import AVFoundation
import Combine
import Foundation
import os

/// What a dictation recorder needs from a meeting in progress.
@MainActor
protocol DictationMeetingCoordinating: AnyObject {
    /// While a meeting records, dictation leaves output volume and media alone so the call stays audible.
    var suppressesDictationOutputEffects: Bool { get }
    func dictationCaptureBegan()
    func dictationCaptureEnded()
}

enum MeetingRecorderError: LocalizedError, Equatable {
    case featureDisabled
    case alreadyRecording
    case microphoneNotAuthorized
    case systemAudioDenied

    var errorDescription: String? {
        switch self {
        case .featureDisabled: String(localized: "Turn on Meetings in Labs to record meetings.")
        case .alreadyRecording: String(localized: "A meeting is already recording.")
        case .microphoneNotAuthorized: String(localized: "Allow VoiceInk to use the microphone to record meetings.")
        case .systemAudioDenied:
            String(localized: "Allow VoiceInk under System Settings › Privacy & Security › Screen & System Audio Recording.")
        }
    }
}

/// Owns at most one meeting: its two tracks, manifest, idle-sleep hold and stall recovery. Dictation keeps
/// working while it records.
@MainActor
final class MeetingRecorder: ObservableObject, DictationMeetingCoordinating {
    static let shared = MeetingRecorder()

    struct Dependencies {
        var store: MeetingStore = .default
        var permission: any SystemAudioAuthorizing = TCCSystemAudioAuthorization()
        var makeSystemAudio: () -> any SystemAudioCapturing = { ProcessTapSystemAudioCapture() }
        var makeMicrophone: @MainActor () -> MeetingMicrophoneCapture = { MeetingMicrophoneCapture() }
        var isMicrophoneAuthorized: () -> Bool = { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }
        var idleSleep: IdleSleepPrevention = .shared
        var now: () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }
        var defaults: UserDefaults = .standard
        var stallCheckInterval: Duration = .seconds(1)
    }

    static let assertionName = "VoiceInk meeting recording"
    /// A tap that delivers nothing for this long is replaced.
    static let stallTimeoutNanoseconds: UInt64 = 3_000_000_000

    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "MeetingRecorder")
    private let dependencies: Dependencies

    @Published private(set) var activeMeeting: MeetingManifest?
    @Published private(set) var isStarting = false
    @Published private(set) var isStopping = false
    @Published private(set) var recordingStartedAt: Date?
    @Published private(set) var meetings: [MeetingManifest] = []
    @Published private(set) var systemAudioAuthorization: SystemAudioAuthorization

    /// Called with each meeting once its audio is closed; transcription subscribes here.
    var onRecorded: ((MeetingManifest) -> Void)?

    private var session: Session?
    private var openDictationStart: UInt64?
    private var labsCancellable: AnyCancellable?

    private struct Session {
        var manifest: MeetingManifest
        let startNanoseconds: UInt64
        let systemAudio: any SystemAudioCapturing
        let microphone: MeetingMicrophoneCapture
        let sleepHold: IdleSleepPrevention.Hold
        var stallTask: Task<Void, Never>?
    }

    var isRecording: Bool { activeMeeting != nil }
    var activeMicrophone: MeetingMicrophoneCapture? { session?.microphone }

    init(dependencies: Dependencies = Dependencies()) {
        self.dependencies = dependencies
        systemAudioAuthorization = dependencies.permission.status()
        meetings = dependencies.store.loadAll()
        labsCancellable = Labs.enabledPublisher(.meetings, in: dependencies.defaults)
            .dropFirst()
            .sink { [weak self] isEnabled in
                Task { @MainActor in await self?.labsSwitchChanged(isEnabled) }
            }
    }

    // MARK: - Dictation coordination

    var suppressesDictationOutputEffects: Bool { isRecording || isStarting }

    func dictationCaptureBegan() {
        guard session != nil else { return }
        openDictationStart = dependencies.now()
    }

    func dictationCaptureEnded() {
        guard let start = openDictationStart, var session else { return }
        openDictationStart = nil
        session.manifest.dictationIntervals.append(
            MeetingManifest.Interval(start: seconds(start, since: session.startNanoseconds),
                                     end: seconds(dependencies.now(), since: session.startNanoseconds))
        )
        self.session = session
    }

    // MARK: - Permission

    func refreshAuthorization() {
        systemAudioAuthorization = dependencies.permission.status()
    }

    /// Asks for System Audio Recording only when it is undecided.
    @discardableResult
    func requestSystemAudioAccess() async -> SystemAudioAuthorization {
        if dependencies.permission.status() == .notDetermined {
            systemAudioAuthorization = await dependencies.permission.request()
        } else {
            refreshAuthorization()
        }
        return systemAudioAuthorization
    }

    private func labsSwitchChanged(_ isEnabled: Bool) async {
        if isEnabled {
            await requestSystemAudioAccess()
        } else if isRecording {
            _ = await stop()
        }
    }

    // MARK: - Recording

    func toggle() async {
        if isRecording {
            _ = await stop()
        } else {
            do {
                try await start()
            } catch {
                NotificationManager.shared.showNotification(title: error.localizedDescription, type: .error, duration: 7)
            }
        }
    }

    func start(title: String? = nil, provider: String? = nil) async throws {
        guard Labs.isEnabled(.meetings, in: dependencies.defaults) else { throw MeetingRecorderError.featureDisabled }
        guard session == nil, !isStarting else { throw MeetingRecorderError.alreadyRecording }
        guard dependencies.isMicrophoneAuthorized() else { throw MeetingRecorderError.microphoneNotAuthorized }
        isStarting = true
        defer { isStarting = false }
        guard await requestSystemAudioAccess().allowsCapture else { throw MeetingRecorderError.systemAudioDenied }

        let store = dependencies.store
        var manifest = MeetingManifest(title: title ?? Self.defaultTitle(for: Date()), provider: provider)
        let directory = try store.createDirectory(for: manifest.id)
        let startNanoseconds = dependencies.now()
        let systemAudio = dependencies.makeSystemAudio()
        let microphone = dependencies.makeMicrophone()
        do {
            try store.save(manifest)
            try systemAudio.start(writingTo: store.audioURL(for: manifest.id, track: .system), meetingStartNanoseconds: startNanoseconds)
            do {
                try await microphone.start(writingTo: store.audioURL(for: manifest.id, track: .microphone), meetingStartNanoseconds: startNanoseconds)
            } catch {
                _ = systemAudio.stop()
                throw error
            }
        } catch {
            manifest.status = .failed
            manifest.failure = error.localizedDescription
            try? store.save(manifest)
            reloadMeetings()
            logger.error("Meeting failed to start: \(error, privacy: .public)")
            throw error
        }
        for track in MeetingManifest.TrackKind.allCases { store.protect(store.audioURL(for: manifest.id, track: track)) }
        logger.notice("Meeting started id=\(manifest.id.uuidString, privacy: .public) folder=\(directory.lastPathComponent, privacy: .public)")

        var session = Session(
            manifest: manifest, startNanoseconds: startNanoseconds, systemAudio: systemAudio, microphone: microphone,
            sleepHold: dependencies.idleSleep.begin(name: Self.assertionName)
        )
        session.stallTask = superviseSystemAudio(systemAudio, startNanoseconds: startNanoseconds)
        self.session = session
        activeMeeting = manifest
        recordingStartedAt = Date()
        reloadMeetings()
    }

    /// Closes both tracks and the manifest; returns the recorded meeting.
    func stop() async -> MeetingManifest? {
        guard var session, !isStopping else { return nil }
        isStopping = true
        defer { isStopping = false }
        session.stallTask?.cancel()
        if openDictationStart != nil { dictationCaptureEnded() }
        if let updated = self.session { session.manifest = updated.manifest }

        let endNanoseconds = dependencies.now()
        let system = session.systemAudio.stop()
        let microphone = await session.microphone.stop()
        session.sleepHold.release()

        var manifest = session.manifest
        manifest.duration = seconds(endNanoseconds, since: session.startNanoseconds)
        apply(system, to: .system, in: &manifest)
        apply(microphone, to: .microphone, in: &manifest)
        manifest.status = .recorded
        do {
            try dependencies.store.save(manifest)
        } catch {
            logger.error("Could not save meeting manifest: \(error, privacy: .public)")
        }
        self.session = nil
        openDictationStart = nil
        activeMeeting = nil
        recordingStartedAt = nil
        reloadMeetings()
        logger.notice("Meeting recorded id=\(manifest.id.uuidString, privacy: .public) duration=\(manifest.duration, privacy: .public)s systemHeard=\(manifest.track(.system)?.heardSignal == true, privacy: .public)")
        onRecorded?(manifest)
        return manifest
    }

    /// Closes both files and leaves the meeting interrupted, to transcribe at the next launch.
    func closeForTermination() {
        guard let session else { return }
        session.stallTask?.cancel()
        if openDictationStart != nil { dictationCaptureEnded() }
        var manifest = self.session?.manifest ?? session.manifest
        manifest.duration = seconds(dependencies.now(), since: session.startNanoseconds)
        apply(session.systemAudio.stop(), to: .system, in: &manifest)
        apply(session.microphone.stopForTermination(), to: .microphone, in: &manifest)
        session.sleepHold.release()
        manifest.status = .interrupted
        try? dependencies.store.save(manifest)
        self.session = nil
        activeMeeting = nil
    }

    func reloadMeetings() {
        meetings = dependencies.store.loadAll()
    }

    /// Persists a manifest another stage (transcription) changed and refreshes the list.
    func update(_ manifest: MeetingManifest) {
        do {
            try dependencies.store.save(manifest)
        } catch {
            logger.error("Could not save meeting manifest: \(error, privacy: .public)")
        }
        reloadMeetings()
    }

    func delete(_ manifest: MeetingManifest) {
        guard manifest.id != activeMeeting?.id else { return }
        do {
            try dependencies.store.delete(id: manifest.id)
        } catch {
            logger.error("Could not delete meeting: \(error, privacy: .public)")
        }
        reloadMeetings()
    }

    var store: MeetingStore { dependencies.store }

    private func apply(_ result: MeetingTrackCaptureResult, to kind: MeetingManifest.TrackKind, in manifest: inout MeetingManifest) {
        manifest.updateTrack(kind) { track in
            track.timeline = result.timeline
            track.droppedBuffers = result.droppedBuffers
            track.heardSignal = result.heardSignal
            track.failure = result.failure
        }
    }

    /// Replaces a tap that stopped delivering, backing off from 0.5 s to 5 s between attempts.
    private func superviseSystemAudio(_ capture: any SystemAudioCapturing, startNanoseconds: UInt64) -> Task<Void, Never> {
        let interval = dependencies.stallCheckInterval
        let now = dependencies.now
        return Task { [weak self, logger] in
            var retryDelay = Duration.milliseconds(500)
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled else { return }
                let last = capture.lastDeliveryNanoseconds ?? startNanoseconds
                guard now() &- last > Self.stallTimeoutNanoseconds else {
                    retryDelay = .milliseconds(500)
                    continue
                }
                logger.warning("System audio tap stalled; restarting")
                do {
                    try capture.restart()
                } catch {
                    logger.error("System audio tap restart failed: \(error, privacy: .public)")
                    try? await Task.sleep(for: retryDelay)
                    retryDelay = min(retryDelay * 2, .seconds(5))
                }
                guard self != nil else { return }
            }
        }
    }

    private func seconds(_ nanoseconds: UInt64, since start: UInt64) -> TimeInterval {
        Double(Int64(bitPattern: nanoseconds &- start)) / 1_000_000_000
    }

    static func defaultTitle(for date: Date) -> String {
        String(localized: "Meeting") + " " + date.formatted(date: .abbreviated, time: .shortened)
    }
}
