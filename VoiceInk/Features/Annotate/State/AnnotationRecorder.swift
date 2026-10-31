import AVFoundation
import AppKit
import Combine
import Foundation
import os

enum AnnotationRecorderError: LocalizedError, Equatable {
    case featureDisabled
    case alreadyRecording
    case screenNotAuthorized
    case microphoneNotAuthorized
    case noDisplay
    case meetingRecording
    case cancelled

    var errorDescription: String? {
        switch self {
        case .featureDisabled: String(localized: "Turn on Annotate in Labs to record annotations.")
        case .alreadyRecording: String(localized: "An annotation is already recording.")
        case .screenNotAuthorized:
            String(localized: "Allow VoiceInk under System Settings › Privacy & Security › Screen & System Audio Recording.")
        case .microphoneNotAuthorized: String(localized: "Allow VoiceInk to use the microphone to narrate annotations.")
        case .noDisplay: String(localized: "No display is available to record.")
        case .meetingRecording: String(localized: "Stop the meeting recording before annotating.")
        case .cancelled: String(localized: "The annotation was cancelled.")
        }
    }
}

/// Owns at most one annotation: the screen movie, the narration and their shared timeline. Dictation waits while
/// it records, since the narration is already speech.
@MainActor
final class AnnotationRecorder: ObservableObject {
    static let shared = AnnotationRecorder()

    struct Dependencies {
        var store: AnnotationStore = .default
        var makeScreen: () -> any ScreenRecording = { ScreenCaptureKitRecording() }
        var makeMicrophone: @MainActor () -> MeetingMicrophoneCapture = { MeetingMicrophoneCapture() }
        var isScreenAuthorized: () -> Bool = { CGPreflightScreenCaptureAccess() }
        var requestScreenAccess: () async -> Bool = { await ScreenCaptureService.requestScreenCapturePermissionRegistration() }
        var isMicrophoneAuthorized: () -> Bool = { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }
        var isMeetingRecording: @MainActor () -> Bool = { MeetingRecorder.shared.isBusy }
        var displayUnderPointer: () -> CGDirectDisplayID? = { NSScreen.displayUnderPointer }
        var idleSleep: IdleSleepPrevention = .shared
        var now: () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }
        var defaults: UserDefaults = .standard
        var maximumDuration: Duration = .seconds(20 * 60)
    }

    static let assertionName = "VoiceInk annotation"

    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "AnnotationRecorder")
    private let dependencies: Dependencies

    @Published private(set) var activeAnnotation: AnnotationManifest?
    @Published private(set) var recordingStartedAt: Date?
    @Published private(set) var isStarting = false
    @Published private(set) var isStopping = false
    @Published private(set) var annotations: [AnnotationManifest] = []
    /// The annotation whose files are open: from the first start step through the end of Stop or Cancel.
    @Published private(set) var ownedAnnotationID: UUID?

    /// Called with each annotation once its files are closed; processing subscribes here.
    var onRecorded: ((AnnotationManifest) -> Void)?
    /// Whether processing is writing this annotation's bundle; set by the processor.
    var isProcessing: (UUID) -> Bool = { _ in false }

    private struct Session {
        var manifest: AnnotationManifest
        let startNanoseconds: UInt64
        let screen: any ScreenRecording
        let microphone: MeetingMicrophoneCapture
        let sleepHold: IdleSleepPrevention.Hold
        var limitTask: Task<Void, Never>?
    }

    private var session: Session?
    private var startGeneration = 0
    /// Cancel or switching Annotate off while Stop closes the files: the closed bundle is then discarded.
    private var discardsTeardown = false
    private var labsCancellable: AnyCancellable?

    var isRecording: Bool { activeAnnotation != nil }
    /// Starting, recording or closing files; another capture or dictation must wait.
    var isBusy: Bool { isStarting || session != nil || isStopping }
    var store: AnnotationStore { dependencies.store }

    init(dependencies: Dependencies = Dependencies()) {
        self.dependencies = dependencies
        annotations = dependencies.store.loadAll()
        labsCancellable = Labs.enabledPublisher(.annotate, in: dependencies.defaults).dropFirst()
            .sink { [weak self] isEnabled in
                MainActor.assumeIsolated {
                    guard let self, !isEnabled else { return }
                    Task { await self.cancel() }
                }
            }
    }

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

    func start() async throws {
        guard Labs.isEnabled(.annotate, in: dependencies.defaults) else { throw AnnotationRecorderError.featureDisabled }
        guard !isBusy else { throw AnnotationRecorderError.alreadyRecording }
        guard !dependencies.isMeetingRecording() else { throw AnnotationRecorderError.meetingRecording }
        guard dependencies.isMicrophoneAuthorized() else { throw AnnotationRecorderError.microphoneNotAuthorized }
        // Reserved before the first suspension, so a meeting or a second annotation cannot start meanwhile.
        isStarting = true
        defer { isStarting = false }
        let generation = startGeneration
        if !dependencies.isScreenAuthorized() {
            guard await dependencies.requestScreenAccess() else { throw AnnotationRecorderError.screenNotAuthorized }
        }
        try checkStillWanted(generation)
        guard let displayID = dependencies.displayUnderPointer() else { throw AnnotationRecorderError.noDisplay }

        let store = dependencies.store
        var manifest = AnnotationManifest()
        try store.createDirectory(for: manifest.id)
        ownedAnnotationID = manifest.id
        let startNanoseconds = dependencies.now()
        let screen = dependencies.makeScreen()
        let microphone = dependencies.makeMicrophone()
        do {
            try store.save(manifest)
            manifest.display = try await screen.start(
                displayID: displayID, writingTo: store.url(for: manifest.id, file: AnnotationManifest.videoFileName)
            )
            do {
                try checkStillWanted(generation)
                try await microphone.start(
                    writingTo: store.url(for: manifest.id, file: AnnotationManifest.narrationFileName),
                    meetingStartNanoseconds: startNanoseconds
                )
                try checkStillWanted(generation)
            } catch {
                _ = await microphone.stop()
                _ = try? await screen.stop()
                throw error
            }
        } catch {
            try? store.delete(id: manifest.id)
            ownedAnnotationID = nil
            reload()
            logger.error("Annotation failed to start: \(error, privacy: .public)")
            throw error
        }
        try? store.save(manifest)

        var session = Session(
            manifest: manifest, startNanoseconds: startNanoseconds, screen: screen, microphone: microphone,
            sleepHold: dependencies.idleSleep.begin(name: Self.assertionName)
        )
        let limit = dependencies.maximumDuration
        session.limitTask = Task { [weak self] in
            try? await Task.sleep(for: limit)
            guard !Task.isCancelled, let self, self.session?.manifest.id == manifest.id else { return }
            self.logger.notice("Annotation reached its maximum duration")
            // A separate task: Stop cancels this one, which must not cancel the movie's finalization.
            Task { await self.stop() }
        }
        self.session = session
        activeAnnotation = manifest
        recordingStartedAt = Date()
        reload()
        logger.notice("Annotation started id=\(manifest.id.uuidString, privacy: .public)")
    }

    /// Closes the movie and narration; returns the recorded annotation for processing.
    @discardableResult
    func stop() async -> AnnotationManifest? {
        guard let session = beginTeardown() else { return nil }
        defer { endTeardown() }
        let end = dependencies.now()
        let microphone = await session.microphone.stop()
        var manifest = session.manifest
        do {
            let screen = try await session.screen.stop()
            manifest.display = screen.display
            manifest.videoOffset = screen.firstFrameNanoseconds.map { seconds($0, since: session.startNanoseconds) }
        } catch {
            manifest.failure = error.localizedDescription
        }
        session.sleepHold.release()
        if discardsTeardown {
            try? dependencies.store.delete(id: manifest.id)
            reload()
            return nil
        }
        manifest.duration = seconds(end, since: session.startNanoseconds)
        manifest.narrationTimeline = microphone.timeline
        manifest.status = manifest.failure == nil ? .processing : .failed
        try? dependencies.store.save(manifest)
        reload()
        if manifest.status == .processing { onRecorded?(manifest) }
        return manifest
    }

    /// Discards the annotation and its files, or abandons a start that has not finished.
    func cancel() async {
        if isStarting { startGeneration += 1 }
        if isStopping {
            discardsTeardown = true
            return
        }
        guard let session = beginTeardown() else { return }
        defer { endTeardown() }
        _ = await session.microphone.stop()
        _ = try? await session.screen.stop()
        session.sleepHold.release()
        try? dependencies.store.delete(id: session.manifest.id)
        reload()
    }

    /// What the dictation's Stop Annotation does: a pending start is abandoned, a recording is stopped.
    func stopOrCancelStart() async {
        if isStarting, session == nil {
            startGeneration += 1
        } else {
            await stop()
        }
    }

    func update(_ manifest: AnnotationManifest) {
        try? dependencies.store.save(manifest)
        reload()
    }

    func delete(_ manifest: AnnotationManifest) {
        guard manifest.id != ownedAnnotationID, !isProcessing(manifest.id) else { return }
        try? dependencies.store.delete(id: manifest.id)
        reload()
    }

    func reload() {
        annotations = dependencies.store.loadAll()
    }

    /// The files stay owned, and the capsule and dictation block stay up, until the awaited teardown ends.
    private func beginTeardown() -> Session? {
        guard let session, !isStopping else { return nil }
        session.limitTask?.cancel()
        isStopping = true
        discardsTeardown = false
        self.session = nil
        return session
    }

    private func endTeardown() {
        isStopping = false
        activeAnnotation = nil
        recordingStartedAt = nil
        ownedAnnotationID = nil
    }

    private func checkStillWanted(_ generation: Int) throws {
        guard Labs.isEnabled(.annotate, in: dependencies.defaults) else { throw AnnotationRecorderError.featureDisabled }
        guard generation == startGeneration else { throw AnnotationRecorderError.cancelled }
    }

    private func seconds(_ nanoseconds: UInt64, since start: UInt64) -> TimeInterval {
        Double(Int64(bitPattern: nanoseconds &- start)) / 1_000_000_000
    }
}
