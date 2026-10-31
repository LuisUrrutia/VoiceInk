import AVFoundation
import AppKit
import Combine
import Foundation
import SwiftData
import SwiftUI
import os

@MainActor
class VoiceInkEngine: NSObject, ObservableObject {
    @Published var recordingState: RecordingState = .idle {
        didSet {
            if !isSyncingRecordingState {
                // Tests fabricate a capture or job by assigning the state it would have.
                isSyncingRecordingState = true
                placeRecordingState(recordingState)
                isSyncingRecordingState = false
            }
            guard oldValue != recordingState else { return }
            ShortcutDiagnostics.notice("recording-state old=\(oldValue) new=\(recordingState) visible=\(recorderUIManager?.isRecorderPanelVisible ?? false) startID=\(activeRecordingStartID?.uuidString ?? "none") job=\(job.map { String($0.sequence) } ?? "none")")
        }
    }
    private var isSyncingRecordingState = false
    @Published var partialTranscript: String = ""
    @Published private(set) var recordingError: String?
    @Published private(set) var recordingNotice: String?
    /// Stops still running their pipeline; Cancel makes the state idle before a canceled pipeline saves History.
    @Published private(set) var unfinishedPipelineCount = 0
    private var recordingNoticeTask: Task<Void, Never>?
    let captureReadiness: CaptureReadinessController
    private var readinessSubscription: AnyCancellable?
    lazy var microphoneDiagnostic = MicrophoneDiagnostic(
        recorder: recorder,
        canStart: { [weak self] in
            guard let self else { return false }
            return self.recordingState == .idle && !self.finalization.isRunning
        },
        captureIssue: { [weak self] in
            self?.captureReadiness.currentSnapshot().issues(for: .microphoneTest).first
        }
    )
    private(set) var capture: DictationCapture? {
        didSet { refreshRecordingState() }
    }
    private(set) var job: DictationJob? {
        didSet { refreshRecordingState() }
    }
    private var lastJobSequence: UInt64 = 0
    /// A start waits for preflight before it owns a capture, so cancel, reset and a newer start supersede it here.
    private var startRequestGeneration: UInt64 = 0
    /// One admitted dictation keeps the single-session behavior: a new start supersedes the previous job.
    static let dictationCapacity = 1
    let outputQueue = DictationOutputQueue(capacity: VoiceInkEngine.dictationCapacity)
    /// The stopped capture's awaited hardware stop, after Stop has handed it to its job.
    private var isStoppingCaptureHardware = false {
        didSet { if !isStoppingCaptureHardware { outputQueue.releaseHeldOutputs() } }
    }
    private let finalization = DictationFinalization()
    /// Releases shared models and enhancement state once no dictation owns them.
    private(set) lazy var residency = TranscriptionResidency { [weak self] in
        await self?.releaseSharedResources()
    }
    private let recordingContextCapture = RecordingContextCapture()
    private var voiceInkRefinePreparationTask: Task<Void, Never>?

    let recorder: Recorder
    let recordingsDirectory: URL

    // Injected managers
    let whisperModelManager: WhisperModelManager
    let transcriptionModelManager: TranscriptionModelManager
    weak var recorderUIManager: RecorderPanelPresenting?

    let modelContext: ModelContext
    internal let serviceRegistry: TranscriptionServiceRegistry
    let enhancementService: AIEnhancementService?
    let assistantSession = AssistantSession()
    let assistantChat: AssistantChatService?
    private let pipeline: TranscriptionPipeline
    private let speechDetector: SpeechDetecting?
    private let isNoSpeechGateEnabled: () -> Bool
    private let startSoundPlayback: @MainActor () -> SoundPlayback?
    private let idleSleepPrevention: IdleSleepPrevention

    let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "VoiceInkEngine")

    init(
        modelContext: ModelContext,
        whisperModelManager: WhisperModelManager,
        transcriptionModelManager: TranscriptionModelManager,
        enhancementService: AIEnhancementService? = nil,
        recorder: Recorder? = nil,
        captureReadiness: CaptureReadinessController? = nil,
        speechDetector: SpeechDetecting? = nil,
        isNoSpeechGateEnabled: @escaping () -> Bool = { NoSpeechGateSettings.isEnabled },
        startSoundPlayback: @escaping @MainActor () -> SoundPlayback? = { SoundManager.shared.lastStartSoundPlayback },
        idleSleepPrevention: IdleSleepPrevention = .shared,
        idleModelUnload: IdleModelUnloadCoordinator? = nil,
        fluidAudioService: FluidAudioTranscriptionService? = nil
    ) {
        self.modelContext = modelContext
        self.idleSleepPrevention = idleSleepPrevention
        self.whisperModelManager = whisperModelManager
        self.transcriptionModelManager = transcriptionModelManager
        self.enhancementService = enhancementService
        self.recorder = recorder ?? Recorder()
        self.captureReadiness = captureReadiness ?? CaptureReadinessController(
            models: transcriptionModelManager, devices: self.recorder.deviceManager
        )
        if let aiService = enhancementService?.getAIService() {
            self.assistantChat = AssistantChatService(
                modelContext: modelContext,
                aiService: aiService
            )
        } else {
            self.assistantChat = nil
        }

        let appSupportDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.prakashjoshipax.VoiceInk")
        self.recordingsDirectory = appSupportDirectory.appendingPathComponent("Recordings")

        self.serviceRegistry = TranscriptionServiceRegistry(
            modelProvider: whisperModelManager,
            modelsDirectory: whisperModelManager.modelsDirectory,
            modelContext: modelContext,
            fluidAudioService: fluidAudioService,
            idleUnload: idleModelUnload
        )
        self.pipeline = TranscriptionPipeline(
            modelContext: modelContext,
            serviceRegistry: serviceRegistry,
            enhancementService: enhancementService,
            outputQueue: outputQueue
        )
        self.speechDetector = speechDetector ?? serviceRegistry.fluidAudioTranscriptionService
        self.isNoSpeechGateEnabled = isNoSpeechGateEnabled
        self.startSoundPlayback = startSoundPlayback

        super.init()
        outputQueue.isCaptureActive = { [weak self] in
            guard let self else { return false }
            return self.isStoppingCaptureHardware || (self.capture.map { $0.phase != .idle } ?? false)
        }

        readinessSubscription = self.captureReadiness.objectWillChange.sink { [weak self] in
            self?.objectWillChange.send()
        }
        setupNotifications()
        createRecordingsDirectoryIfNeeded()
    }

    private func createRecordingsDirectoryIfNeeded() {
        do {
            try FileManager.default.createDirectory(
                at: recordingsDirectory, withIntermediateDirectories: true, attributes: nil)
        } catch {
            logger.error("❌ Error creating recordings directory: \(error, privacy: .public)")
        }
    }

    // MARK: - Toggle Record

    func toggleRecord(
        modeId: UUID? = nil, processing: DictationProcessing = .standard, isAssistantFollowUp: Bool = false,
        sendAfterPaste: Bool = false,
        deliverySession: RecordingDeliverySession? = nil, releaseTail: RecordingReleaseTail? = nil,
        preRollPressNanoseconds: UInt64? = nil
    ) async {
        let capturedDelivery = deliverySession ?? RecordingDeliverySession.capture()
        await finalization.waitUntilFinished()
        guard !Task.isCancelled else { return }
        guard !microphoneDiagnostic.isBusy else {
            await recorderUIManager?.dismissRecorderPanel()
            return
        }
        if recordingState == .starting {
            await cancelRecording()
            return
        }

        if recordingState == .recording {
            guard let finalizationID = finalization.beginCapture() else { return }
            defer { finalization.finishCapture(finalizationID) }
            guard let capture else { return }
            pipelineDidBegin()
            defer { pipelineDidEnd() }
            // Before the handoff clears the capture, so a held output keeps waiting through the hardware stop.
            isStoppingCaptureHardware = true
            let job = beginJob(stopping: capture, sendAfterPaste: sendAfterPaste)
            defer { if job.task == nil { endJob(job) } }
            let fileBeingStopped = job.audioURL
            let preparation = job.preparation
            let delivery = job.delivery
            // Canceled and failed recordings play no stop tone.
            let playStopTone: @MainActor () -> Void = { [weak self] in
                guard let self, !job.cancelRequested, self.recorder.recordingError == nil else { return }
                delivery?.recordingStopped()
            }
            if let releaseTail {
                preparation?.timing.mark(.shortcutReleased, at: releaseTail.releasedAtNanoseconds)
                let outcome = await recorder.stopRecording(
                    after: releaseTail,
                    playReleaseTone: playStopTone,
                    shouldEndTailEarly: { [weak self] in self == nil || job.cancelRequested }
                )
                recordReleaseTailTiming(outcome, timing: preparation?.timing)
            } else {
                await recorder.stopRecording(playStopTone: playStopTone)
            }
            isStoppingCaptureHardware = false
            recordClosedAudioTiming(preparation?.timing)
            preparation?.startSoundPlayback = startSoundPlayback()

            if let recordedFile = fileBeingStopped {
                if !job.cancelRequested {
                    let transcription = makeRecordingTranscription(
                        for: recordedFile,
                        text: "",
                        duration: 0,
                        transcriptionStatus: .pending,
                        modeSnapshot: modeSnapshot(for: preparation),
                        processing: job.processing
                    )
                    modelContext.insert(transcription)
                    try? modelContext.save()
                    NotificationCenter.default.post(name: .transcriptionCreated, object: transcription)

                    if let error = recorder.recordingError {
                        recordingError = String(localized: "Recording failed. Check the microphone and try again.")
                        transcription.text = error.localizedDescription
                        transcription.transcriptionStatus = TranscriptionStatus.failed.rawValue
                        try? modelContext.save()
                        delivery?.dictationFailed()
                        NotificationManager.shared.showNotification(
                            title: error.localizedDescription, type: .error, playsSound: false
                        )
                        cancelCurrentSession()
                        job.audioURL = nil
                        job.phase = .idle
                        await cleanupResources()
                        return
                    }

                    job.transcriptionID = transcription.id
                    finalization.finishCapture(finalizationID)
                    // Read now, as when the pipeline ran inline: a reset may clear them before the task starts.
                    let inputs = PipelineInputs(
                        audioURL: recordedFile, context: job.context, deliverySession: delivery,
                        preparation: preparation, session: job.session, configuration: job.sessionConfiguration
                    )
                    let task = Task { @MainActor in
                        await self.runPipeline(job, on: transcription, inputs: inputs)
                        self.endJob(job)
                    }
                    job.task = task
                    await withTaskCancellationHandler {
                        await task.value
                    } onCancel: {
                        task.cancel()
                    }
                } else {
                    await finishActiveRecorderCancellation()
                }
            } else {
                cancelCurrentSession()
                if !job.cancelRequested {
                    logger.error("❌ No recorded file found after stopping recording")
                }
                job.phase = .idle
                await cleanupResources()
            }
        } else {
            guard recordingState == .idle else { return }
            startRequestGeneration &+= 1
            let startRequest = startRequestGeneration
            capturedDelivery.timing.mark(.engineStart)
            let pressNanoseconds = preRollPressNanoseconds ?? capturedDelivery.timing.originNanoseconds
            recorder.holdPreRoll(forPressAt: pressNanoseconds)
            let canContinueAssistantSession = isAssistantFollowUp && assistantSession.canSendFollowUp
            let recordingUseCase: DictationUseCase = canContinueAssistantSession ? .assistantFollowUp : .newSession

            // A new recording supersedes the previous job.
            job?.delivery?.cancel()
            let previousPreparation = job?.preparation
            previousPreparation?.cancel()
            await previousPreparation?.finish()
            guard startRequest == startRequestGeneration, recordingState == .idle, !Task.isCancelled else { return }
            job?.context?.cancel()
            if let job {
                residency.relinquish(job.dictationID)
                outputQueue.skip(job.sequence)
                outputQueue.withdraw(job.dictationID)
            }
            job = nil
            capture?.delivery?.cancel()
            capture?.context?.cancel()
            if let capture {
                residency.relinquish(capture.dictationID)
                outputQueue.withdraw(capture.dictationID)
            }
            capture = nil
            recordingError = nil
            clearRecordingNotice()
            partialTranscript = ""

            if !recordingUseCase.isAssistantFollowUp {
                assistantSession.reset()
            }

            let readiness = await captureReadiness.refreshedSnapshot()
            guard startRequest == startRequestGeneration, !Task.isCancelled,
                await passesRecordingPreflight(readiness: readiness, delivery: capturedDelivery),
                !microphoneDiagnostic.isBusy, recordingState == .idle
            else { return }

            let preparation = RecordingTranscriptionPreparation(timing: capturedDelivery.timing)
            let startID = preparation.recordingID
            guard outputQueue.admit(startID) else {
                logger.notice("admission=rejected pending=\(self.outputQueue.admittedCount, privacy: .public)")
                capturedDelivery.cancel()
                await recorderUIManager?.dismissRecorderPanel()
                return
            }
            let realtimeAudioGate = RealtimeAudioChunkGate()
            let capture = DictationCapture(
                startID: startID, delivery: capturedDelivery, preparation: preparation,
                audioGate: realtimeAudioGate, useCase: recordingUseCase, processing: processing,
                didChangePhase: { [weak self] in self?.refreshRecordingState() }
            )
            self.capture = capture
            residency.acquire(capture.dictationID)
            capturedDelivery.preventIdleSleep(idleSleepPrevention.begin())
            capturedDelivery.holdModelUse(serviceRegistry.beginModelUse())
            let modeManager = ModeManager.shared
            let activeModeTask = ActiveWindowService.shared.beginApplyingConfiguration(modeId: modeId) {
                [weak self] in
                guard let self else { return false }
                return !preparation.isCancelled
                    && (self.capture?.preparation === preparation || self.job?.preparation === preparation)
            }
            // The lookup's own immediate apply is this recording's fallback, not a user selection.
            let initialModeID = modeManager.currentEffectiveConfiguration?.id
            let initialSelectionGeneration = modeManager.selectionGeneration
            preparation.ownModeResolution(activeModeTask)
            preparation.timing.mark(.modeResolutionStarted)

            do {
                let fileName = "\(UUID().uuidString).wav"
                let permanentURL = self.recordingsDirectory.appendingPathComponent(fileName)
                capture.fileURL = permanentURL

                self.recorder.onAudioChunk = realtimeAudioGate.receive

                capture.phase = .starting

                preparation.timing.mark(.audioStartRequested)
                try await self.recorder.startRecording(
                    toOutputFile: permanentURL, preRollPressNanoseconds: pressNanoseconds
                )

                guard self.activeRecordingStartID == startID,
                    self.recorderUIManager?.isRecorderPanelVisible ?? false,
                    !self.shouldCancelRecording
                else {
                    preparation.cancel()
                    self.endFailedRecordingDelivery(capturedDelivery)
                    if self.activeRecordingStartID == startID {
                        guard let finalizationID = self.finalization.beginCapture() else { return }
                        defer { self.finalization.finishCapture(finalizationID) }
                        await self.recorder.stopRecording()
                        if self.shouldCancelRecording {
                            await self.finishActiveRecorderCancellation()
                        } else {
                            capture.fileURL = nil
                            capture.phase = .idle
                            capture.startID = nil
                            await self.cleanupResources()
                        }
                    }
                    return
                }

                capture.phase = .recording
                preparation.timing.mark(.audioStarted)
                let context = self.recordingContextCapture.makeSession(
                    recordingID: startID,
                    savedVocabulary: CustomVocabularyService.shared.loadSavedVocabulary(from: self.modelContext)
                )
                capture.context = context
                let contextStore = context.store
                preparation.timing.mark(.contextStarted)

                let registry = self.serviceRegistry
                let models = self.transcriptionModelManager
                let whisper = self.whisperModelManager
                let resolveEnhancement = DictationModeSnapshot.enhancementResolver(for: self.enhancementService)
                preparation.start(
                    resolveModeSnapshot: { modeID in
                        DictationModeSnapshot.resolve(
                            modeID: modeID ?? initialModeID, resolveEnhancement: resolveEnhancement
                        )
                    },
                    freezeModeSnapshots: {
                        DictationModeSnapshot.frozenResolver(
                            fallbackModeID: initialModeID, resolveEnhancement: resolveEnhancement
                        )
                    },
                    userModeSelection: { modeManager.selectedConfigurationID(since: initialSelectionGeneration) },
                    resolveConfiguration: { snapshot in
                        let configuration = ModeRuntimeResolver.transcriptionConfiguration(
                            mode: snapshot?.mode, transcriptionModelManager: models
                        )
                        contextStore.resolveRecognitionLanguage(
                            configuration.map { TranscriptionLanguageSupport.recognitionLanguage(for: $0.languages) }
                        )
                        return configuration
                    },
                    retireAutoLearn: {
                        if AutoLearnSettings.isEnabled {
                            await AutoLearnService.shared.recordingDidStart()
                        }
                    },
                    prepareModel: { [residency] configuration in
                        await residency.waitForPendingRelease()
                        try await registry.prepareForRecording(
                            configuration, recordingID: startID, whisperModelManager: whisper
                        )
                    },
                    prepareSession: { [weak self, residency] configuration in
                        await residency.waitForPendingRelease()
                        guard let session = await registry.makeRealtimeSession(
                            for: configuration,
                            onPartialTranscript: { [weak self] partial in
                                Task { @MainActor in
                                    guard let self, self.activeRecordingStartID == startID,
                                        self.recordingState == .recording
                                    else { return }
                                    self.partialTranscript = partial
                                }
                            }
                        ) else {
                            _ = realtimeAudioGate.reset()
                            return nil
                        }
                        do {
                            let callback = try await session.prepare(
                                configuration: configuration,
                                vocabulary: contextStore.vocabularyPreparation.current
                            )
                            try Task.checkCancellation()
                            if let callback {
                                let dropped = realtimeAudioGate.activate(callback)
                                if dropped > 0 {
                                    self?.logger.warning("Realtime startup audio gate dropped \(dropped, privacy: .public) chunks")
                                }
                            } else {
                                _ = realtimeAudioGate.reset()
                            }
                            return session
                        } catch {
                            session.cancel()
                            await session.finishPreparation()
                            throw error
                        }
                    },
                    releaseResources: { configuration in
                        await registry.releaseRecordingPreparation(recordingID: startID, configuration: configuration)
                    }
                )

                let setup = try await preparation.setup()
                guard self.activeRecordingPreparation === preparation,
                    self.recordingState == .recording, !preparation.isCancelled
                else { return }

                guard let setup else {
                    let resolution = ModeRuntimeResolver.transcriptionModelResolution(
                        mode: preparation.modeSnapshot?.mode, transcriptionModelManager: models
                    )
                    let failure = self.recordingModelFailure(for: resolution)
                    self.recordingError = failure.title
                    capturedDelivery.dictationFailed()
                    NotificationManager.shared.showNotification(
                        title: failure.title, type: .error, duration: 7.0,
                        actionButton: (failure.actionLabel, failure.action), playsSound: false
                    )
                    self.endFailedRecordingDelivery(capturedDelivery)
                    guard let finalizationID = self.finalization.beginCapture() else { return }
                    defer { self.finalization.finishCapture(finalizationID) }
                    await self.recorder.stopRecording()
                    self.recordClosedAudioTiming(preparation.timing)
                    if self.shouldCancelRecording {
                        await self.finishActiveRecorderCancellation()
                    } else {
                        try? FileManager.default.removeItem(at: permanentURL)
                        capture.fileURL = nil
                        capture.phase = .idle
                        capture.context?.cancel()
                        capture.context = nil
                        await self.cleanupResources()
                    }
                    await self.recorderUIManager?.dismissRecorderPanel()
                    return
                }

                capture.session = setup.session
                capture.sessionConfiguration = setup.configuration
                if setup.session == nil { self.recorder.onAudioChunk = nil }
                self.scheduleVoiceInkRefinePreparation(for: startID)

            } catch {
                preparation.cancel()
                guard self.activeRecordingStartID == startID else { return }
                // Ending the delivery silences it, so a start failure plays its error tone first.
                if !self.shouldCancelRecording { capturedDelivery.dictationFailed() }
                self.endFailedRecordingDelivery(capturedDelivery)
                guard let finalizationID = self.finalization.beginCapture() else { return }
                defer { self.finalization.finishCapture(finalizationID) }
                self.logger.error("Recording failed to start: \(error, privacy: .public)")
                let audioFailure = self.recordingAudioFailure(for: error)
                if audioFailure == nil {
                    await self.recorder.stopRecording()
                }
                if self.shouldCancelRecording {
                    await self.finishActiveRecorderCancellation()
                    return
                }
                self.cancelCurrentSession()
                if let recordedFile = capture.fileURL {
                    try? FileManager.default.removeItem(at: recordedFile)
                }
                capture.phase = .idle
                self.recordingError = audioFailure?.title ?? String(localized: "Recording failed to start")
                capture.fileURL = nil
                capture.startID = nil
                capture.context?.cancel()
                capture.context = nil
                await self.cleanupResources()
                if let failure = audioFailure {
                    NotificationManager.shared.showNotification(
                        title: failure.title,
                        type: .error,
                        duration: 7.0,
                        actionButton: (failure.actionLabel, failure.action),
                        playsSound: false
                    )
                } else {
                    NotificationManager.shared.showNotification(
                        title: String(localized: "Recording failed to start"), type: .error, playsSound: false)
                }
                await self.recorderUIManager?.dismissRecorderPanel()
            }
        }
    }

    /// Stop hands the capture's ownership to a new job; the job replaces the capture without an idle gap.
    private func beginJob(stopping capture: DictationCapture, sendAfterPaste: Bool) -> DictationJob {
        let preparation = capture.preparation
        preparation?.timing.mark(.stopReceived)
        preparation?.freezeModeSelection()
        let job = DictationJob(
            sequence: outputQueue.assignSequence(), capture: capture, sendAfterPaste: sendAfterPaste,
            didChangePhase: { [weak self] in self?.refreshRecordingState() }
        )
        capture.startID = nil
        partialTranscript = ""
        self.job = job
        // The release is the user-visible boundary; the tail stays invisible capture.
        self.capture = nil
        return job
    }

    private func endJob(_ job: DictationJob) {
        job.delivery?.completePipeline()
        job.context?.cancel()
        outputQueue.skip(job.sequence)
        outputQueue.withdraw(job.dictationID)
        if self.job === job { self.job = nil }
    }

    private func refreshRecordingState() {
        // A capture that ends releases an output held behind it.
        defer { outputQueue.releaseHeldOutputs() }
        guard !isSyncingRecordingState else { return }
        let derived: RecordingState
        if let capture, capture.phase != .idle {
            derived = capture.phase
        } else {
            derived = job?.phase ?? .idle
        }
        guard recordingState != derived else { return }
        isSyncingRecordingState = true
        defer { isSyncingRecordingState = false }
        recordingState = derived
    }

    private func placeRecordingState(_ state: RecordingState) {
        switch state {
        case .idle:
            capture?.phase = .idle
            job?.phase = .idle
        case .starting, .recording:
            openCapture().phase = state
        case .transcribing, .enhancing, .busy:
            if let job, capture == nil || capture?.phase == .idle {
                job.phase = state
            } else {
                openCapture().phase = state
            }
        }
    }

    private func openCapture() -> DictationCapture {
        if let capture { return capture }
        let capture = DictationCapture(
            startID: nil, delivery: nil, preparation: nil, audioGate: nil, useCase: .newSession,
            didChangePhase: { [weak self] in self?.refreshRecordingState() }
        )
        self.capture = capture
        return capture
    }

    // Tests fabricate a live capture through these accessors.
    var activeRecordingDelivery: RecordingDeliverySession? {
        get { capture?.delivery }
        set { if newValue != nil || capture != nil { openCapture().delivery = newValue } }
    }

    var activeRecordingPreparation: RecordingTranscriptionPreparation? {
        get { capture?.preparation }
        set { if newValue != nil || capture != nil { openCapture().preparation = newValue } }
    }

    var recordedFile: URL? {
        get { capture?.fileURL ?? job?.audioURL }
        set { if newValue != nil || capture != nil { openCapture().fileURL = newValue } }
    }

    var activeRecordingStartID: UUID? { capture?.startID }
    var currentSession: TranscriptionSession? { capture?.session ?? job?.session }
    var shouldCancelRecording: Bool { capture?.cancelRequested == true || job?.cancelRequested == true }

    /// Only for starts that never reached Stop; Stop transfers the delivery to the pipeline.
    private func endFailedRecordingDelivery(_ delivery: RecordingDeliverySession) {
        delivery.cancel()
        if capture?.delivery === delivery { capture?.delivery = nil }
    }

    @MainActor
    private func recordingModelFailure(
        for resolution: ModeTranscriptionModelResolution
    ) -> (title: String, actionLabel: String, action: () -> Void) {
        switch resolution {
        case .noMode:
            return (
                String(localized: "No mode configured"),
                String(localized: "Manage Modes"),
                ModeSetupNavigator.openModesSettings
            )
        case .noSelection(let mode):
            return (
                String(
                    format: String(localized: "No transcription model is selected for the '%@' mode"),
                    mode.name
                ),
                String(localized: "Manage Modes"),
                ModeSetupNavigator.openModesSettings
            )
        case .modelNotFound(let mode):
            return (
                String(
                    format: String(localized: "The transcription model selected for the '%@' mode is unavailable"),
                    mode.name
                ),
                String(localized: "Manage Modes"),
                ModeSetupNavigator.openModesSettings
            )
        case .unavailable(let mode, let model), .available(let mode, let model):
            return (
                String(
                    format: String(localized: "'%@' is not available for the %@ mode"),
                    model.displayName,
                    mode.name
                ),
                String(localized: "Manage AI Models"),
                ModeSetupNavigator.openModelsSettings
            )
        }
    }

    /// Checks requirements that do not depend on asynchronous app and URL mode resolution.
    @MainActor
    private func passesRecordingPreflight(
        readiness: CaptureReadiness, delivery: RecordingDeliverySession
    ) async -> Bool {
        if let issue = readiness.issues(for: .microphoneTest).first {
            await failRecordingPreflight(
                title: issue.message,
                actionLabel: String(localized: "Audio Settings"),
                action: AudioSetupNavigator.openAudioSettings,
                delivery: delivery
            )
            return false
        }
        if !ModeManager.shared.hasEnabledConfiguration {
            await failRecordingPreflight(
                title: String(localized: "No mode configured"),
                actionLabel: String(localized: "Manage Modes"),
                action: ModeSetupNavigator.openModesSettings,
                delivery: delivery
            )
            return false
        }

        return true
    }

    @MainActor
    private func failRecordingPreflight(
        title: String,
        actionLabel: String,
        action: @escaping () -> Void,
        delivery: RecordingDeliverySession
    ) async {
        logger.error("❌ Recording preflight failed: \(title, privacy: .public)")
        recordingState = .idle
        recordingError = title
        delivery.dictationFailed()
        NotificationManager.shared.showNotification(
            title: title,
            type: .error,
            duration: 7.0,
            actionButton: (actionLabel, action),
            playsSound: false
        )
        await recorderUIManager?.dismissRecorderPanel()
    }

    // MARK: - Pipeline Dispatch

    private func isActive(_ transcriptionID: UUID) -> Bool {
        job?.transcriptionID == transcriptionID
    }

    private struct PipelineInputs {
        let audioURL: URL
        let context: RecordingContextCapture.Session?
        let deliverySession: RecordingDeliverySession?
        let preparation: RecordingTranscriptionPreparation?
        let session: TranscriptionSession?
        let configuration: TranscriptionRuntimeConfiguration?
    }

    private func runPipeline(_ job: DictationJob, on transcription: Transcription, inputs: PipelineInputs) async {
        let transcriptionID = transcription.id
        let audioURL = inputs.audioURL
        let context = inputs.context
        let deliverySession = inputs.deliverySession
        let preparation = inputs.preparation
        var resolvedConfiguration = inputs.configuration
        var session = inputs.session
        if let preparation {
            do {
                let setup = try await preparation.setup()
                resolvedConfiguration = setup?.configuration
                session = setup?.session
                await preparation.waitUntilPrepared()
            } catch {
                resolvedConfiguration = nil
            }
        } else if resolvedConfiguration == nil {
            resolvedConfiguration = ModeRuntimeResolver.transcriptionConfiguration(transcriptionModelManager: transcriptionModelManager)
        }
        guard
            let transcriptionConfiguration = resolvedConfiguration
        else {
            if preparation?.isCancelled == true || job.cancelRequested {
                let duration = await AudioFileMetadata.duration(for: audioURL)
                transcription.markAsCanceledTranscription(duration: duration > 0 ? duration : nil)
            } else {
                recordingError = String(localized: "Transcription failed. Select a model for this mode.")
                transcription.text = String(localized: "Transcription Failed: No model selected")
                transcription.transcriptionStatus = TranscriptionStatus.failed.rawValue
                deliverySession?.dictationFailed()
            }
            try? modelContext.save()
            await finishPipeline(job, transcription, preparation: preparation)
            return
        }

        if await discardsRecordingWithoutSpeech(
            job, transcription, audioURL: audioURL, session: session, preparation: preparation
        ) {
            return
        }

        let modeSnapshot = self.modeSnapshot(for: preparation)
        let vocabularyPreparation = context?.store.vocabularyPreparation ?? RecordingVocabularyPreparation(
            savedVocabulary: CustomVocabularyService.shared.loadSavedVocabulary(from: modelContext)
        )

        await pipeline.run(
            transcription: transcription,
            audioURL: audioURL,
            transcriptionConfiguration: transcriptionConfiguration,
            modeSnapshot: modeSnapshot,
            session: session,
            triggerWordModeSelection: { [resolveEnhancement] text in
                DictationModeSnapshot.triggerWordSelection(in: text, resolveEnhancement: resolveEnhancement)
            },
            vocabularyPreparation: vocabularyPreparation,
            recordingContextSnapshot: {
                context?.store.snapshot
            },
            cancelContextCapture: {
                context?.cancelCapture()
            },
            sendAfterPaste: job.sendAfterPaste,
            laneSequence: job.sequence,
            deliverySession: deliverySession,
            preparation: preparation,
            onStateChange: { [weak self] state in
                guard let self, self.isActive(transcriptionID) else { return }
                job.phase = state
            },
            shouldCancel: {
                job.cancelRequested
            },
            onCancel: { [weak self, session] in
                guard let self else { return }
                self.cancelPipelineSession(job, transcriptionID: transcriptionID, session: session)
            },
            onDismiss: { [weak self] in
                guard let self, self.isActive(transcriptionID) else { return }
                await self.recorderUIManager?.dismissRecorderPanel()
            },
            assistant: TranscriptionPipeline.AssistantHooks(
                isFollowUp: job.useCase.isAssistantFollowUp,
                sendFollowUp: { [weak self] text, transcription in
                    guard let self, self.isActive(transcriptionID) else { return }
                    await self.sendAssistantFollowUp(text, transcription: transcription)
                },
                startResponse: { [weak self] transcript, configuration in
                    guard let self, self.isActive(transcriptionID) else { return }
                    self.assistantSession.beginInitialResponse(
                        transcript: transcript,
                        provider: configuration.provider,
                        modelName: configuration.modelName ?? configuration.provider?.defaultModel,
                        modeName: configuration.mode?.name,
                        modeEmoji: configuration.mode?.icon.value,
                        promptName: configuration.prompt?.title
                    )
                },
                showResponse: { [weak self] response, systemPrompt in
                    guard let self, self.isActive(transcriptionID) else { return }
                    await self.completeAssistantResponse(response, systemPrompt: systemPrompt)
                },
                failResponse: { [weak self] message in
                    guard let self, self.isActive(transcriptionID) else { return }
                    self.assistantSession.fail(message)
                }
            )
        )

        await finishPipeline(job, transcription, preparation: preparation)
    }

    private func finishPipeline(
        _ job: DictationJob, _ transcription: Transcription, preparation: RecordingTranscriptionPreparation?
    ) async {
        let outcome: RecordingTimingTrace.Outcome =
            transcription.transcriptionStatus == TranscriptionStatus.canceled.rawValue ? .canceled
            : transcription.transcriptionStatus == TranscriptionStatus.failed.rawValue ? .failed : .completed
        await finishPipeline(job, transcriptionID: transcription.id, outcome: outcome, preparation: preparation)
    }

    @discardableResult
    private func finishPipeline(
        _ job: DictationJob, transcriptionID: UUID, outcome: RecordingTimingTrace.Outcome,
        preparation: RecordingTranscriptionPreparation?
    ) async -> Bool {
        await finalization.waitForCapture()
        let didFinishActivePipeline = isActive(transcriptionID)
        if didFinishActivePipeline {
            if outcome == .failed {
                recordingError = String(localized: "Transcription failed. Check the model or provider in Models.")
            }
            guard finalization.beginFinish(of: job.dictationID) else { return false }
            defer { finalization.endFinish(of: job.dictationID) }
            await releaseResources(of: job)
            job.transcriptionID = nil
            job.session = nil
            job.sessionConfiguration = nil
            job.audioURL = nil
        }
        if didFinishActivePipeline {
            job.phase = .idle
            preparation?.timing.mark(.idle, outcome: outcome)
        }
        return didFinishActivePipeline
    }

    // MARK: - No-Speech Gate

    /// Discards a live recording without speech before transcription; returns false to continue the pipeline.
    private func discardsRecordingWithoutSpeech(
        _ job: DictationJob, _ transcription: Transcription, audioURL: URL, session: TranscriptionSession?,
        preparation: RecordingTranscriptionPreparation?
    ) async -> Bool {
        let timing = preparation?.timing
        guard isNoSpeechGateEnabled() else {
            timing?.mark(.speechGate, outcome: .skipped)
            return false
        }
        let transcriptionID = transcription.id
        let events = timing?.snapshot ?? []
        guard let trace = timing, let firstAudio = events.first(where: { $0.phase == .firstAudio }),
            let release = events.first(where: { $0.phase == .shortcutReleased })
                ?? events.first(where: { $0.phase == .stopReceived })
        else {
            timing?.mark(.speechGate, outcome: .skipped)
            return false
        }
        let firstAudioNanoseconds = trace.preRollStartNanoseconds
            ?? trace.originNanoseconds + firstAudio.elapsedNanoseconds
        let releasedFrames = NoSpeechGate.releasedFrameCount(
            firstAudioNanoseconds: firstAudioNanoseconds,
            releaseNanoseconds: trace.originNanoseconds + release.elapsedNanoseconds
        )
        let startSound = preparation?.startSoundPlayback
        let startSoundOffset = NoSpeechGate.startSoundOffsetFrames(
            playback: startSound, requestNanoseconds: trace.originNanoseconds,
            firstAudioNanoseconds: firstAudioNanoseconds
        )
        let evaluation = await NoSpeechGate.evaluate(
            audioURL: audioURL, startSound: startSound, startSoundOffsetFrames: startSoundOffset,
            releasedFrameCount: releasedFrames, detector: speechDetector
        )
        guard let evaluation, evaluation.decision.discardsRecording else {
            timing?.mark(.speechGate)
            return false
        }
        // An explicit Cancel keeps its canceled History entry.
        guard !job.cancelRequested else {
            timing?.mark(.speechGate, outcome: .canceled)
            return false
        }
        timing?.mark(.speechGate, outcome: .discarded)

        // A streaming session must not finalize or deliver its transcript.
        session?.cancel()
        let isAssistantFollowUp = job.useCase.isAssistantFollowUp
        modelContext.delete(transcription)
        do {
            try modelContext.save()
        } catch {
            logger.error("Failed to remove discarded recording from History: \(error, privacy: .public)")
        }
        NotificationCenter.default.post(name: .transcriptionDeleted, object: nil)
        do {
            try FileManager.default.removeItem(at: audioURL)
        } catch {
            logger.error("Failed to remove discarded recording audio: \(error, privacy: .public)")
        }

        let didFinish = await finishPipeline(
            job, transcriptionID: transcriptionID, outcome: .discarded, preparation: preparation
        )
        if didFinish, recordingState == .idle, activeRecordingStartID == nil {
            showNoSpeechNotice(dismissesRecorder: !isAssistantFollowUp)
        }
        return true
    }

    private func showNoSpeechNotice(dismissesRecorder: Bool) {
        let notice = String(localized: "No speech detected")
        recordingNotice = notice
        if let application = NSApp {
            NSAccessibility.post(
                element: application, notification: .announcementRequested,
                userInfo: [.announcement: notice, .priority: NSAccessibilityPriorityLevel.medium.rawValue]
            )
        }
        recordingNoticeTask?.cancel()
        recordingNoticeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled, let self, self.recordingNotice == notice else { return }
            self.recordingNotice = nil
            self.recordingNoticeTask = nil
            guard dismissesRecorder, self.recordingState == .idle,
                self.recorderUIManager?.isRecorderPanelVisible == true
            else { return }
            await self.recorderUIManager?.dismissRecorderPanel()
        }
    }

    private func clearRecordingNotice() {
        recordingNoticeTask?.cancel()
        recordingNoticeTask = nil
        recordingNotice = nil
    }

    /// Before a recording starts resolving its mode, the current mode applies.
    private var resolveEnhancement: DictationModeSnapshot.EnhancementResolver {
        DictationModeSnapshot.enhancementResolver(for: enhancementService)
    }

    private func modeSnapshot(for preparation: RecordingTranscriptionPreparation?) -> DictationModeSnapshot {
        preparation?.currentModeSnapshot
            ?? DictationModeSnapshot.resolve(modeID: nil, resolveEnhancement: resolveEnhancement)
    }

    // MARK: - Cancellation

    func cancelRecording() async {
        startRequestGeneration &+= 1
        let timing = (capture?.preparation ?? job?.preparation)?.timing
        timing?.mark(.cancelReceived)
        defer {
            if recordingState == .idle, !finalization.isRunning {
                timing?.mark(.idle, outcome: .canceled)
            }
        }
        recordingError = nil
        if microphoneDiagnostic.isBusy {
            await microphoneDiagnostic.cancel()
            return
        }
        if finalization.isRunning {
            requestRecordingCancellation()
            await finalization.waitUntilFinished()
            return
        }
        let shouldFinishSessionImmediately: Bool
        switch recordingState {
        case .starting, .recording:
            guard let finalizationID = finalization.beginCapture() else { return }
            defer { finalization.finishCapture(finalizationID) }
            requestRecordingCancellation()
            await finishActiveRecorderCancellation()
            shouldFinishSessionImmediately = false
        case .transcribing, .enhancing:
            if job?.outputStarted == true {
                logger.notice("cancel=refused output=committed")
                return
            }
            guard let finalizationID = finalization.beginCapture() else { return }
            defer { finalization.finishCapture(finalizationID) }
            let job = self.job
            requestRecordingCancellation()
            await job?.preparation?.finish()
            partialTranscript = ""
            job?.phase = .idle
            shouldFinishSessionImmediately = false
        case .idle, .busy:
            partialTranscript = ""
            capture?.cancelRequested = false
            capture?.phase = .idle
            job?.phase = .idle
            shouldFinishSessionImmediately = true
        }

        if shouldFinishSessionImmediately {
            guard let finalizationID = finalization.beginCapture() else { return }
            defer { finalization.finishCapture(finalizationID) }
            // Enhancement state that another dictation owns stays until that dictation releases it.
            if !residency.isOwned { await finishRecorderSession() }
        }
    }

    func resetRecordingSession() async {
        startRequestGeneration &+= 1
        await microphoneDiagnostic.cancel()
        recordingError = nil
        await finalization.waitUntilFinished()
        guard let finalizationID = finalization.beginCapture() else { return }
        defer { finalization.finishCapture(finalizationID) }
        let capture = self.capture
        let job = self.job
        capture?.preparation?.cancel()
        job?.preparation?.cancel()
        cancelCurrentSession()
        capture?.delivery?.cancel()
        capture?.delivery = nil
        job?.delivery?.cancel()
        job?.delivery = nil
        capture?.startID = nil
        job?.transcriptionID = nil
        partialTranscript = ""
        assistantSession.reset()
        capture?.context?.cancel()
        capture?.context = nil
        job?.context?.cancel()
        job?.context = nil
        await recorder.stopRecording()
        capture?.fileURL = nil
        job?.audioURL = nil
        capture?.phase = .idle
        job?.phase = .idle
        await cleanupResources()
        if self.job === job { self.job = nil }
    }

    private func requestRecordingCancellation() {
        capture?.preparation?.cancel()
        capture?.delivery?.cancel()
        capture?.cancelRequested = true
        capture?.session?.cancel()
        capture?.session = nil
        capture?.sessionConfiguration = nil

        // A job past its commit point finishes its output.
        guard let job, job.delivery?.cancelBeforeOutput() ?? true else { return }
        job.preparation?.cancel()
        job.cancelRequested = true
        outputQueue.skip(job.sequence)
        if recordingState == .transcribing || recordingState == .enhancing {
            job.context?.cancel()
            job.context = nil
        }
        job.session?.cancel()
        job.session = nil
        job.sessionConfiguration = nil
    }

    /// Ends the capture, or a job still inside its Stop, as a canceled History entry.
    private func finishActiveRecorderCancellation() async {
        let capture = self.capture
        let job = self.job
        let fileBeingCancelled = capture?.fileURL ?? job?.audioURL
        capture?.delivery?.cancel()
        capture?.delivery = nil
        capture?.startID = nil
        capture?.context?.cancel()
        capture?.context = nil
        let preparation = capture?.preparation ?? job?.preparation
        preparation?.freezeModeSelection()
        await recorder.stopRecording()
        recordClosedAudioTiming(preparation?.timing)
        await saveCanceledRecording(
            at: fileBeingCancelled, modeSnapshot: modeSnapshot(for: preparation),
            processing: capture?.processing ?? job?.processing ?? .standard
        )
        capture?.fileURL = nil
        job?.audioURL = nil
        partialTranscript = ""
        capture?.phase = .idle
        job?.phase = .idle
        await cleanupResources()
    }

    private func saveCanceledRecording(
        at recordedFile: URL?, modeSnapshot: DictationModeSnapshot, processing: DictationProcessing
    ) async {
        guard let recordedFile,
            FileManager.default.fileExists(atPath: recordedFile.path)
        else { return }

        let duration = await AudioFileMetadata.duration(for: recordedFile)
        let transcription = makeRecordingTranscription(
            for: recordedFile,
            text: Transcription.canceledTranscriptionText,
            duration: duration,
            transcriptionStatus: .canceled,
            modeSnapshot: modeSnapshot,
            processing: processing
        )

        modelContext.insert(transcription)

        do {
            try modelContext.save()
            NotificationCenter.default.post(name: .transcriptionCreated, object: transcription)
        } catch {
            logger.error("Failed to save canceled recording: \(error, privacy: .public)")
        }
    }

    private func makeRecordingTranscription(
        for audioURL: URL,
        text: String,
        duration: TimeInterval,
        transcriptionStatus: TranscriptionStatus,
        modeSnapshot: DictationModeSnapshot,
        processing: DictationProcessing
    ) -> Transcription {
        let modeMetadata = modeSnapshot.metadata

        return Transcription(
            text: text,
            duration: duration,
            audioFileURL: audioURL.absoluteString,
            transcriptionModelName: ModeRuntimeResolver.transcriptionConfiguration(
                mode: modeSnapshot.mode, transcriptionModelManager: transcriptionModelManager
            )?.model.displayName,
            modeName: modeMetadata.name,
            modeEmoji: modeMetadata.emoji,
            transcriptionStatus: transcriptionStatus,
            isRawDictation: processing == .raw
        )
    }

    private func scheduleVoiceInkRefinePreparation(for recordingStartID: UUID) {
        voiceInkRefinePreparationTask?.cancel()

        voiceInkRefinePreparationTask = Task { @MainActor [weak self] in
            guard let self,
                self.recordingState == .recording,
                self.activeRecordingStartID == recordingStartID,
                !self.shouldCancelRecording,
                let enhancementService = self.enhancementService,
                let aiService = enhancementService.getAIService()
            else {
                return
            }

            let initialConfiguration = ModeRuntimeResolver.currentEnhancementConfiguration(
                enhancementService: enhancementService,
                aiService: aiService
            )
            guard initialConfiguration.isEnabled,
                initialConfiguration.provider == .voiceInkRefine
            else {
                return
            }

            // Preserve an already-warm XPC model immediately, while retaining the
            // debounce below before any new model preparation begins.
            await aiService.voiceInkRefineService.keepPreparedModelWarmForRecording()

            do {
                try await Task.sleep(for: .milliseconds(450))
            } catch {
                return
            }

            guard self.recordingState == .recording,
                self.activeRecordingStartID == recordingStartID,
                !self.shouldCancelRecording
            else {
                return
            }

            let configuration = ModeRuntimeResolver.currentEnhancementConfiguration(
                enhancementService: enhancementService,
                aiService: aiService
            )
            guard configuration.isEnabled, configuration.provider == .voiceInkRefine else {
                return
            }

            await aiService.voiceInkRefineService.prepareForRecording()
        }
    }

    // MARK: - Resource Cleanup

    private func cancelPipelineSession(_ job: DictationJob, transcriptionID: UUID, session: TranscriptionSession?) {
        session?.cancel()

        guard isActive(transcriptionID) else {
            logger.notice("Skipping stale pipeline cleanup")
            return
        }

        job.session = nil
        job.sessionConfiguration = nil
    }

    private func cancelCurrentSession() {
        capture?.session?.cancel()
        job?.session?.cancel()
        capture?.session = nil
        capture?.sessionConfiguration = nil
        job?.session = nil
        job?.sessionConfiguration = nil
    }

    private func finishRecorderSession() async {
        let preparationTask = voiceInkRefinePreparationTask
        voiceInkRefinePreparationTask = nil
        preparationTask?.cancel()
        enhancementService?.clearCapturedContexts()

        await preparationTask?.value
        await enhancementService?
            .getAIService()?
            .voiceInkRefineService
            .unloadPreparedModelIfNeeded()
    }

    private func recordReleaseTailTiming(_ outcome: RecordingReleaseTail.Outcome?, timing: RecordingTimingTrace?) {
        guard let outcome else { return }
        let traceOutcome: RecordingTimingTrace.Outcome
        switch outcome.reason {
        case .captured: traceOutcome = .completed
        case .stalled: traceOutcome = .failed
        case .endedEarly: traceOutcome = .canceled
        }
        timing?.mark(.releaseTailEnded, outcome: traceOutcome, at: outcome.endedAtNanoseconds)
    }

    private func recordClosedAudioTiming(_ timing: RecordingTimingTrace?) {
        if let preRollStart = recorder.preRollStartNanoseconds {
            timing?.recordPreRollStart(at: preRollStart)
        }
        if let firstAudio = recorder.firstAudioTimestampNanoseconds {
            timing?.mark(.firstAudio, at: firstAudio)
        }
        timing?.mark(.wavClosed, outcome: recorder.recordingError == nil ? .completed : .failed)
    }

    /// True while a recording, stop pipeline, finalization or microphone test could still lose audio or History.
    var hasUnfinishedDictationWork: Bool {
        AppRelauncher.blocksRelaunch(
            recordingState: recordingState, unfinishedPipelines: unfinishedPipelineCount,
            finalizationRunning: finalization.isRunning, microphoneTestBusy: microphoneDiagnostic.isBusy
        )
    }

    func pipelineDidBegin() { unfinishedPipelineCount += 1 }
    func pipelineDidEnd() { unfinishedPipelineCount -= 1 }

    /// Capture and finalization that hold no model lease still keep the idle timer from unloading.
    var isUsingTranscriptionModels: Bool {
        recordingState != .idle || microphoneDiagnostic.isBusy || finalization.isRunning
    }

    func unloadIdleModels() async {
        await whisperModelManager.unloadIdleModel()
        await serviceRegistry.unloadIdleModels()
    }

    /// Ends the current capture's and job's preparations and releases their residency.
    func cleanupResources() async {
        let capture = self.capture
        let job = self.job
        let owners = [capture?.dictationID, job?.dictationID].compactMap { $0 }
        let recordingPreparation = capture?.preparation
        let pipelinePreparation = job?.preparation
        recordingPreparation?.cancel()
        pipelinePreparation?.cancel()
        await recordingPreparation?.finish()
        await pipelinePreparation?.finish()
        if self.capture?.preparation === recordingPreparation { self.capture?.preparation = nil }
        if self.job?.preparation === pipelinePreparation { self.job?.preparation = nil }
        self.capture?.startID = nil
        if let ended = self.capture, ended.phase == .idle {
            outputQueue.withdraw(ended.dictationID)
            self.capture = nil
        }
        await residency.release(owners)
    }

    /// A job's own finish: its preparation, VAD lease and share of the residency.
    private func releaseResources(of job: DictationJob) async {
        let preparation = job.preparation
        preparation?.cancel()
        await preparation?.finish()
        if job.preparation === preparation { job.preparation = nil }
        await residency.release([job.dictationID])
    }

    private func releaseSharedResources() async {
        logger.notice("cleanupResources: releasing model resources")
        await finishRecorderSession()
        await whisperModelManager.cleanupResources()
        await serviceRegistry.cleanup()
        logger.notice("cleanupResources: completed")
    }

    // MARK: - Notification Handling

    func setupNotifications() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handlePromptChange),
            name: .promptDidChange,
            object: nil
        )
    }

    @objc func handlePromptChange() {
        Task {
            let currentPrompt =
                UserDefaults.standard.string(forKey: "TranscriptionPrompt")
                ?? whisperModelManager.whisperPrompt.transcriptionPrompt
            if let context = whisperModelManager.whisperContext {
                await context.setPrompt(currentPrompt)
            }
        }
    }
}

enum AudioFileMetadata {
    static func duration(for url: URL) async -> TimeInterval {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration) else { return 0 }
        let seconds = CMTimeGetSeconds(duration)
        return seconds.isFinite ? seconds : 0
    }
}
