import AVFoundation
import AppKit
import Combine
import Foundation
import SwiftData
import SwiftUI
import os

private final class RealtimeAudioChunkGate: @unchecked Sendable {
    private struct State {
        var bufferedChunks: [Data] = []
        var callback: ((Data) -> Void)?
        var isActive = false
        var droppedChunks = 0
    }

    private let maxBufferedChunks = 2_048
    private let state = OSAllocatedUnfairLock(initialState: State())

    func receive(_ data: Data) {
        let callback = state.withLock { state -> ((Data) -> Void)? in
            guard state.isActive else {
                if state.bufferedChunks.count < maxBufferedChunks {
                    state.bufferedChunks.append(data)
                } else {
                    state.droppedChunks += 1
                }
                return nil
            }
            return state.callback
        }
        callback?(data)
    }

    func activate(_ callback: @escaping (Data) -> Void) -> Int {
        let initialState = state.withLock { state -> (chunks: [Data], droppedChunks: Int) in
            state.callback = callback
            state.isActive = false
            let chunks = state.bufferedChunks
            let droppedChunks = state.droppedChunks
            state.bufferedChunks.removeAll()
            state.droppedChunks = 0
            return (chunks, droppedChunks)
        }
        var chunksToSend = initialState.chunks
        var droppedChunks = initialState.droppedChunks

        while true {
            for chunk in chunksToSend {
                callback(chunk)
            }

            let nextState = state.withLock { state -> (chunks: [Data], droppedChunks: Int, finished: Bool) in
                let droppedChunks = state.droppedChunks
                state.droppedChunks = 0
                guard !state.bufferedChunks.isEmpty else {
                    state.isActive = true
                    return ([], droppedChunks, true)
                }
                let chunks = state.bufferedChunks
                state.bufferedChunks.removeAll()
                return (chunks, droppedChunks, false)
            }
            droppedChunks += nextState.droppedChunks

            if nextState.finished {
                return droppedChunks
            }
            chunksToSend = nextState.chunks
        }
    }

    func reset() -> Int {
        state.withLock { state -> Int in
            let droppedChunks = state.droppedChunks
            state.bufferedChunks.removeAll()
            state.callback = nil
            state.isActive = false
            state.droppedChunks = 0
            return droppedChunks
        }
    }
}

@MainActor
class VoiceInkEngine: NSObject, ObservableObject {
    private enum RecordingUseCase {
        case newSession
        case assistantFollowUp

        var isAssistantFollowUp: Bool {
            self == .assistantFollowUp
        }
    }

    @Published var recordingState: RecordingState = .idle {
        didSet {
            guard oldValue != recordingState else { return }
            ShortcutDiagnostics.notice("recording-state old=\(oldValue) new=\(recordingState) visible=\(recorderUIManager?.isRecorderPanelVisible ?? false) startID=\(activeRecordingStartID?.uuidString ?? "none")")
        }
    }
    @Published var shouldCancelRecording = false
    @Published var partialTranscript: String = ""
    @Published private(set) var recordingError: String?
    @Published private(set) var recordingNotice: String?
    private var recordingNoticeTask: Task<Void, Never>?
    let captureReadiness: CaptureReadinessController
    private var readinessSubscription: AnyCancellable?
    lazy var microphoneDiagnostic = MicrophoneDiagnostic(
        recorder: recorder,
        canStart: { [weak self] in
            guard let self else { return false }
            return self.recordingState == .idle && !self.recordingFinalization.isRunning
        },
        captureIssue: { [weak self] in
            self?.captureReadiness.refreshSnapshot()
            return self?.captureReadiness.snapshot.issues(for: .microphoneTest).first
        }
    )
    var currentSession: TranscriptionSession?
    private var currentSessionTranscriptionConfiguration: TranscriptionRuntimeConfiguration?
    var activeRecordingDelivery: RecordingDeliverySession?
    private var activePipelineDelivery: RecordingDeliverySession?
    private(set) var activeRecordingStartID: UUID?
    var activeRecordingPreparation: RecordingTranscriptionPreparation?
    private var activePipelinePreparation: RecordingTranscriptionPreparation?
    private let recordingFinalization = RecordingFinalization()
    private var activePipelineTranscriptionID: UUID?
    private var canceledPipelineTranscriptionIDs = Set<UUID>()
    private var activeRecordingUseCase: RecordingUseCase = .newSession
    private var activePipelineUseCase: RecordingUseCase = .newSession
    private let recordingContextCapture = RecordingContextCapture()
    private var pipelineContextCapture: RecordingContextCapture.Session?
    private var voiceInkRefinePreparationTask: Task<Void, Never>?

    let recorder: Recorder
    var recordedFile: URL? = nil
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
            enhancementService: enhancementService
        )
        self.speechDetector = speechDetector ?? serviceRegistry.fluidAudioTranscriptionService
        self.isNoSpeechGateEnabled = isNoSpeechGateEnabled
        self.startSoundPlayback = startSoundPlayback

        super.init()

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
        modeId: UUID? = nil, isAssistantFollowUp: Bool = false, sendAfterPaste: Bool = false,
        deliverySession: RecordingDeliverySession? = nil, releaseTail: RecordingReleaseTail? = nil,
        preRollPressNanoseconds: UInt64? = nil
    ) async {
        let capturedDelivery = deliverySession ?? RecordingDeliverySession.capture()
        await recordingFinalization.waitUntilFinished()
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
            guard let finalizationID = recordingFinalization.begin() else { return }
            defer { recordingFinalization.finish(finalizationID) }
            let fileBeingStopped = recordedFile
            let preparation = activeRecordingPreparation
            activeRecordingPreparation = nil
            activePipelinePreparation = preparation
            preparation?.timing.mark(.stopReceived)
            preparation?.freezeModeSelection()
            let delivery = activeRecordingDelivery
            activeRecordingDelivery = nil
            activePipelineDelivery = delivery
            let context = recordingContextCapture.take()
            pipelineContextCapture = context
            defer {
                delivery?.completePipeline()
                if activePipelineDelivery === delivery { activePipelineDelivery = nil }
                context?.cancel()
                if pipelineContextCapture === context {
                    pipelineContextCapture = nil
                }
                if activePipelinePreparation === preparation { activePipelinePreparation = nil }
            }
            activePipelineUseCase = activeRecordingUseCase
            activeRecordingUseCase = .newSession
            activeRecordingStartID = nil
            partialTranscript = ""
            // The release is the user-visible boundary; the tail stays invisible capture.
            recordingState = .transcribing
            // Canceled and failed recordings play no stop tone.
            let playStopTone: @MainActor () -> Void = { [weak self] in
                guard let self, !self.shouldCancelRecording, self.recorder.recordingError == nil else { return }
                delivery?.recordingStopped()
            }
            if let releaseTail {
                preparation?.timing.mark(.shortcutReleased, at: releaseTail.releasedAtNanoseconds)
                let outcome = await recorder.stopRecording(
                    after: releaseTail,
                    playReleaseTone: playStopTone,
                    shouldEndTailEarly: { [weak self] in self?.shouldCancelRecording ?? true }
                )
                recordReleaseTailTiming(outcome, timing: preparation?.timing)
            } else {
                await recorder.stopRecording(playStopTone: playStopTone)
            }
            recordClosedAudioTiming(preparation?.timing)
            preparation?.startSoundPlayback = startSoundPlayback()

            if let recordedFile = fileBeingStopped {
                if !shouldCancelRecording {
                    let transcription = makeRecordingTranscription(
                        for: recordedFile,
                        text: "",
                        duration: 0,
                        transcriptionStatus: .pending,
                        modeSnapshot: modeSnapshot(for: preparation)
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
                        self.recordedFile = nil
                        recordingState = .idle
                        await cleanupResources()
                        return
                    }

                    recordingFinalization.finish(finalizationID)
                    await runPipeline(
                        on: transcription,
                        audioURL: recordedFile,
                        context: context,
                        deliverySession: delivery,
                        preparation: preparation,
                        sendAfterPaste: sendAfterPaste
                    )
                } else {
                    await finishActiveRecorderCancellation()
                }
            } else {
                cancelCurrentSession()
                if !shouldCancelRecording {
                    logger.error("❌ No recorded file found after stopping recording")
                }
                recordingState = .idle
                await cleanupResources()
            }
        } else {
            guard recordingState == .idle else { return }
            capturedDelivery.timing.mark(.engineStart)
            let pressNanoseconds = preRollPressNanoseconds ?? capturedDelivery.timing.originNanoseconds
            recorder.holdPreRoll(forPressAt: pressNanoseconds)
            let canContinueAssistantSession = isAssistantFollowUp && assistantSession.canSendFollowUp
            let recordingUseCase: RecordingUseCase = canContinueAssistantSession ? .assistantFollowUp : .newSession

            activePipelineDelivery?.cancel()
            let previousPreparation = activePipelinePreparation
            previousPreparation?.cancel()
            await previousPreparation?.finish()
            guard recordingState == .idle, !Task.isCancelled else { return }
            if activePipelinePreparation === previousPreparation { activePipelinePreparation = nil }
            activePipelineDelivery = nil
            activeRecordingDelivery?.cancel()
            activeRecordingDelivery = nil
            activePipelineTranscriptionID = nil
            clearPipelineRecordingContext()
            shouldCancelRecording = false
            recordingError = nil
            clearRecordingNotice()
            partialTranscript = ""
            activeRecordingUseCase = recordingUseCase
            clearActiveRecordingContext()

            if !recordingUseCase.isAssistantFollowUp {
                assistantSession.reset()
            }

            guard await passesRecordingPreflight(delivery: capturedDelivery), !microphoneDiagnostic.isBusy,
                recordingState == .idle, !Task.isCancelled
            else { return }

            let preparation = RecordingTranscriptionPreparation(timing: capturedDelivery.timing)
            let startID = preparation.recordingID
            self.activeRecordingPreparation = preparation
            self.activeRecordingStartID = startID
            self.activeRecordingDelivery = capturedDelivery
            capturedDelivery.preventIdleSleep(idleSleepPrevention.begin())
            capturedDelivery.holdModelUse(serviceRegistry.beginModelUse())
            let modeManager = ModeManager.shared
            let activeModeTask = ActiveWindowService.shared.beginApplyingConfiguration(modeId: modeId) {
                [weak self] in
                guard let self else { return false }
                return !preparation.isCancelled
                    && (self.activeRecordingPreparation === preparation || self.activePipelinePreparation === preparation)
            }
            // The lookup's own immediate apply is this recording's fallback, not a user selection.
            let initialModeID = modeManager.currentEffectiveConfiguration?.id
            let initialSelectionGeneration = modeManager.selectionGeneration
            preparation.ownModeResolution(activeModeTask)
            preparation.timing.mark(.modeResolutionStarted)

            do {
                let fileName = "\(UUID().uuidString).wav"
                let permanentURL = self.recordingsDirectory.appendingPathComponent(fileName)
                self.recordedFile = permanentURL

                let realtimeAudioGate = RealtimeAudioChunkGate()
                self.recorder.onAudioChunk = realtimeAudioGate.receive

                self.recordingState = .starting

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
                        guard let finalizationID = self.recordingFinalization.begin() else { return }
                        defer { self.recordingFinalization.finish(finalizationID) }
                        await self.recorder.stopRecording()
                        if self.shouldCancelRecording {
                            await self.finishActiveRecorderCancellation()
                        } else {
                            self.recordedFile = nil
                            self.recordingState = .idle
                            self.activeRecordingStartID = nil
                            await self.cleanupResources()
                        }
                    }
                    return
                }

                self.recordingState = .recording
                preparation.timing.mark(.audioStarted)
                let contextStore = self.startRecordingContextCapture(recordingID: startID)
                preparation.timing.mark(.contextStarted)

                let registry = self.serviceRegistry
                let models = self.transcriptionModelManager
                let whisper = self.whisperModelManager
                let enhancementService = self.enhancementService
                preparation.start(
                    resolveModeSnapshot: { modeID in
                        DictationModeSnapshot.resolve(
                            modeID: modeID ?? initialModeID, enhancementService: enhancementService
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
                    prepareModel: { configuration in
                        try await registry.prepareForRecording(
                            configuration, recordingID: startID, whisperModelManager: whisper
                        )
                    },
                    prepareSession: { [weak self] configuration in
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
                    guard let finalizationID = self.recordingFinalization.begin() else { return }
                    defer { self.recordingFinalization.finish(finalizationID) }
                    await self.recorder.stopRecording()
                    self.recordClosedAudioTiming(preparation.timing)
                    if self.shouldCancelRecording {
                        await self.finishActiveRecorderCancellation()
                    } else {
                        try? FileManager.default.removeItem(at: permanentURL)
                        self.recordedFile = nil
                        self.recordingState = .idle
                        self.clearActiveRecordingContext(recordingID: startID)
                        await self.cleanupResources()
                    }
                    await self.recorderUIManager?.dismissRecorderPanel()
                    return
                }

                self.currentSession = setup.session
                self.currentSessionTranscriptionConfiguration = setup.configuration
                if setup.session == nil { self.recorder.onAudioChunk = nil }
                self.scheduleVoiceInkRefinePreparation(for: startID)

            } catch {
                preparation.cancel()
                guard self.activeRecordingStartID == startID else { return }
                // Ending the delivery silences it, so a start failure plays its error tone first.
                if !self.shouldCancelRecording { capturedDelivery.dictationFailed() }
                self.endFailedRecordingDelivery(capturedDelivery)
                guard let finalizationID = self.recordingFinalization.begin() else { return }
                defer { self.recordingFinalization.finish(finalizationID) }
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
                if let recordedFile = self.recordedFile {
                    try? FileManager.default.removeItem(at: recordedFile)
                }
                self.recordingState = .idle
                self.recordingError = audioFailure?.title ?? String(localized: "Recording failed to start")
                self.recordedFile = nil
                self.activeRecordingStartID = nil
                self.clearActiveRecordingContext(recordingID: startID)
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

    /// Only for starts that never reached Stop; Stop transfers the delivery to the pipeline.
    private func endFailedRecordingDelivery(_ delivery: RecordingDeliverySession) {
        delivery.cancel()
        if activeRecordingDelivery === delivery { activeRecordingDelivery = nil }
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
    private func passesRecordingPreflight(delivery: RecordingDeliverySession) async -> Bool {
        captureReadiness.refreshSnapshot()
        if let issue = captureReadiness.snapshot.issues(for: .microphoneTest).first {
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

    // MARK: - Recording Context

    private func startRecordingContextCapture(recordingID: UUID) -> RecordingContextSnapshotStore {
        recordingContextCapture.start(
            recordingID: recordingID,
            savedVocabulary: CustomVocabularyService.shared.loadSavedVocabulary(from: modelContext)
        )
    }

    private func clearActiveRecordingContext(recordingID: UUID? = nil) {
        recordingContextCapture.clear(recordingID: recordingID)
    }

    private func clearPipelineRecordingContext() {
        pipelineContextCapture?.cancel()
        pipelineContextCapture = nil
    }

    // MARK: - Pipeline Dispatch

    private func runPipeline(
        on transcription: Transcription,
        audioURL: URL,
        context: RecordingContextCapture.Session?,
        deliverySession: RecordingDeliverySession?,
        preparation: RecordingTranscriptionPreparation?,
        sendAfterPaste: Bool
    ) async {
        let transcriptionID = transcription.id
        activePipelineTranscriptionID = transcriptionID
        var resolvedConfiguration = currentSessionTranscriptionConfiguration
        var session = currentSession
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
            if preparation?.isCancelled == true || shouldCancelRecording {
                let duration = await AudioFileMetadata.duration(for: audioURL)
                transcription.markAsCanceledTranscription(duration: duration > 0 ? duration : nil)
            } else {
                recordingError = String(localized: "Transcription failed. Select a model for this mode.")
                transcription.text = String(localized: "Transcription Failed: No model selected")
                transcription.transcriptionStatus = TranscriptionStatus.failed.rawValue
                deliverySession?.dictationFailed()
            }
            try? modelContext.save()
            await finishPipeline(transcription, preparation: preparation)
            return
        }

        if await discardsRecordingWithoutSpeech(
            transcription, audioURL: audioURL, session: session, preparation: preparation
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
            triggerWordModeSelection: { [enhancementService] text in
                DictationModeSnapshot.triggerWordSelection(in: text, enhancementService: enhancementService)
            },
            vocabularyPreparation: vocabularyPreparation,
            recordingContextSnapshot: {
                context?.store.snapshot
            },
            cancelContextCapture: {
                context?.cancelCapture()
            },
            sendAfterPaste: sendAfterPaste,
            deliverySession: deliverySession,
            preparation: preparation,
            onStateChange: { [weak self] state in
                guard let self, self.activePipelineTranscriptionID == transcriptionID else { return }
                self.recordingState = state
            },
            shouldCancel: { [weak self] in
                self?.isPipelineCancellationRequested(transcriptionID) ?? false
            },
            onCancel: { [weak self, session] in
                guard let self else { return }
                self.cancelPipelineSession(transcriptionID: transcriptionID, session: session)
            },
            onDismiss: { [weak self] in
                guard let self, self.activePipelineTranscriptionID == transcriptionID else { return }
                await self.recorderUIManager?.dismissRecorderPanel()
            },
            assistant: TranscriptionPipeline.AssistantHooks(
                isFollowUp: activePipelineUseCase.isAssistantFollowUp,
                sendFollowUp: { [weak self] text, transcription in
                    guard let self, self.activePipelineTranscriptionID == transcriptionID else { return }
                    await self.sendAssistantFollowUp(text, transcription: transcription)
                },
                startResponse: { [weak self] transcript, configuration in
                    guard let self, self.activePipelineTranscriptionID == transcriptionID else { return }
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
                    guard let self, self.activePipelineTranscriptionID == transcriptionID else { return }
                    await self.completeAssistantResponse(response, systemPrompt: systemPrompt)
                },
                failResponse: { [weak self] message in
                    guard let self, self.activePipelineTranscriptionID == transcriptionID else { return }
                    self.assistantSession.fail(message)
                }
            )
        )

        await finishPipeline(transcription, preparation: preparation)
    }

    private func finishPipeline(
        _ transcription: Transcription, preparation: RecordingTranscriptionPreparation?
    ) async {
        let outcome: RecordingTimingTrace.Outcome =
            transcription.transcriptionStatus == TranscriptionStatus.canceled.rawValue ? .canceled
            : transcription.transcriptionStatus == TranscriptionStatus.failed.rawValue ? .failed : .completed
        await finishPipeline(transcriptionID: transcription.id, outcome: outcome, preparation: preparation)
    }

    @discardableResult
    private func finishPipeline(
        transcriptionID: UUID, outcome: RecordingTimingTrace.Outcome,
        preparation: RecordingTranscriptionPreparation?
    ) async -> Bool {
        await recordingFinalization.waitUntilFinished()
        let didFinishActivePipeline = activePipelineTranscriptionID == transcriptionID
        if didFinishActivePipeline {
            if outcome == .failed {
                recordingError = String(localized: "Transcription failed. Check the model or provider in Models.")
            }
            guard let finalizationID = recordingFinalization.begin() else { return false }
            defer { recordingFinalization.finish(finalizationID) }
            await cleanupResources()
            activePipelineTranscriptionID = nil
            currentSession = nil
            currentSessionTranscriptionConfiguration = nil
            recordedFile = nil
            shouldCancelRecording = false
            activePipelineUseCase = .newSession
        }
        canceledPipelineTranscriptionIDs.remove(transcriptionID)

        if didFinishActivePipeline
            && (recordingState == .transcribing || recordingState == .enhancing || recordingState == .busy)
        {
            recordingState = .idle
        }
        if didFinishActivePipeline {
            preparation?.timing.mark(.idle, outcome: outcome)
        }
        return didFinishActivePipeline
    }

    // MARK: - No-Speech Gate

    /// Discards a live recording without speech before transcription; returns false to continue the pipeline.
    private func discardsRecordingWithoutSpeech(
        _ transcription: Transcription, audioURL: URL, session: TranscriptionSession?,
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
        guard !isPipelineCancellationRequested(transcriptionID) else {
            timing?.mark(.speechGate, outcome: .canceled)
            return false
        }
        timing?.mark(.speechGate, outcome: .discarded)

        // A streaming session must not finalize or deliver its transcript.
        session?.cancel()
        let isAssistantFollowUp = activePipelineUseCase.isAssistantFollowUp
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
            transcriptionID: transcriptionID, outcome: .discarded, preparation: preparation
        )
        if didFinish, recordingState == .idle, activeRecordingStartID == nil {
            showNoSpeechNotice(dismissesRecorder: !isAssistantFollowUp)
        }
        return true
    }

    private func isPipelineCancellationRequested(_ transcriptionID: UUID) -> Bool {
        canceledPipelineTranscriptionIDs.contains(transcriptionID)
            || (activePipelineTranscriptionID == transcriptionID && shouldCancelRecording)
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
    private func modeSnapshot(for preparation: RecordingTranscriptionPreparation?) -> DictationModeSnapshot {
        preparation?.currentModeSnapshot
            ?? DictationModeSnapshot.resolve(modeID: nil, enhancementService: enhancementService)
    }

    // MARK: - Cancellation

    func cancelRecording() async {
        let timing = (activeRecordingPreparation ?? activePipelinePreparation)?.timing
        timing?.mark(.cancelReceived)
        defer {
            if recordingState == .idle, !recordingFinalization.isRunning {
                timing?.mark(.idle, outcome: .canceled)
            }
        }
        recordingError = nil
        if microphoneDiagnostic.isBusy {
            await microphoneDiagnostic.cancel()
            return
        }
        if recordingFinalization.isRunning {
            requestRecordingCancellation()
            await recordingFinalization.waitUntilFinished()
            return
        }
        let shouldFinishSessionImmediately: Bool
        switch recordingState {
        case .starting, .recording:
            guard let finalizationID = recordingFinalization.begin() else { return }
            defer { recordingFinalization.finish(finalizationID) }
            requestRecordingCancellation()
            await finishActiveRecorderCancellation()
            shouldFinishSessionImmediately = false
        case .transcribing, .enhancing:
            guard let finalizationID = recordingFinalization.begin() else { return }
            defer { recordingFinalization.finish(finalizationID) }
            requestRecordingCancellation()
            await activePipelinePreparation?.finish()
            partialTranscript = ""
            recordingState = .idle
            shouldFinishSessionImmediately = false
        case .idle, .busy:
            partialTranscript = ""
            shouldCancelRecording = false
            recordingState = .idle
            shouldFinishSessionImmediately = true
        }

        if shouldFinishSessionImmediately {
            guard let finalizationID = recordingFinalization.begin() else { return }
            defer { recordingFinalization.finish(finalizationID) }
            await finishRecorderSession()
        }
    }

    func resetRecordingSession() async {
        await microphoneDiagnostic.cancel()
        recordingError = nil
        await recordingFinalization.waitUntilFinished()
        guard let finalizationID = recordingFinalization.begin() else { return }
        defer { recordingFinalization.finish(finalizationID) }
        activeRecordingPreparation?.cancel()
        activePipelinePreparation?.cancel()
        cancelCurrentSession()
        activeRecordingDelivery?.cancel()
        activeRecordingDelivery = nil
        activePipelineDelivery?.cancel()
        activePipelineDelivery = nil
        activeRecordingStartID = nil
        activePipelineTranscriptionID = nil
        canceledPipelineTranscriptionIDs.removeAll()
        shouldCancelRecording = false
        partialTranscript = ""
        assistantSession.reset()
        activeRecordingUseCase = .newSession
        activePipelineUseCase = .newSession
        clearActiveRecordingContext()
        clearPipelineRecordingContext()
        await recorder.stopRecording()
        recordedFile = nil
        recordingState = .idle
        await cleanupResources()
    }

    private func requestRecordingCancellation() {
        activeRecordingPreparation?.cancel()
        activePipelinePreparation?.cancel()
        activeRecordingDelivery?.cancel()
        activePipelineDelivery?.cancel()
        shouldCancelRecording = true

        if recordingState == .transcribing || recordingState == .enhancing {
            if let activePipelineTranscriptionID {
                canceledPipelineTranscriptionIDs.insert(activePipelineTranscriptionID)
            }
            clearPipelineRecordingContext()
        }

        cancelCurrentSession()
    }

    private func finishActiveRecorderCancellation() async {
        let fileBeingCancelled = recordedFile
        activeRecordingDelivery?.cancel()
        activeRecordingDelivery = nil
        activeRecordingStartID = nil
        clearActiveRecordingContext()
        let preparation = activeRecordingPreparation ?? activePipelinePreparation
        preparation?.freezeModeSelection()
        await recorder.stopRecording()
        recordClosedAudioTiming(preparation?.timing)
        await saveCanceledRecording(at: fileBeingCancelled, modeSnapshot: modeSnapshot(for: preparation))
        recordedFile = nil
        partialTranscript = ""
        recordingState = .idle
        await cleanupResources()
    }

    private func saveCanceledRecording(at recordedFile: URL?, modeSnapshot: DictationModeSnapshot) async {
        guard let recordedFile,
            FileManager.default.fileExists(atPath: recordedFile.path)
        else { return }

        let duration = await AudioFileMetadata.duration(for: recordedFile)
        let transcription = makeRecordingTranscription(
            for: recordedFile,
            text: Transcription.canceledTranscriptionText,
            duration: duration,
            transcriptionStatus: .canceled,
            modeSnapshot: modeSnapshot
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
        modeSnapshot: DictationModeSnapshot
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
            transcriptionStatus: transcriptionStatus
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

    private func cancelPipelineSession(transcriptionID: UUID, session: TranscriptionSession?) {
        session?.cancel()

        guard activePipelineTranscriptionID == transcriptionID else {
            logger.notice("Skipping stale pipeline cleanup")
            return
        }

        currentSession = nil
        currentSessionTranscriptionConfiguration = nil
    }

    private func cancelCurrentSession() {
        currentSession?.cancel()
        currentSession = nil
        currentSessionTranscriptionConfiguration = nil
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

    /// Capture and finalization that hold no model lease still keep the idle timer from unloading.
    var isUsingTranscriptionModels: Bool {
        recordingState != .idle || microphoneDiagnostic.isBusy || recordingFinalization.isRunning
    }

    func unloadIdleModels() async {
        await whisperModelManager.unloadIdleModel()
        await serviceRegistry.unloadIdleModels()
    }

    func cleanupResources() async {
        let recordingPreparation = activeRecordingPreparation
        let pipelinePreparation = activePipelinePreparation
        recordingPreparation?.cancel()
        pipelinePreparation?.cancel()
        await recordingPreparation?.finish()
        await pipelinePreparation?.finish()
        if activeRecordingPreparation === recordingPreparation { activeRecordingPreparation = nil }
        if activePipelinePreparation === pipelinePreparation { activePipelinePreparation = nil }
        logger.notice("cleanupResources: releasing model resources")
        activeRecordingStartID = nil
        activeRecordingUseCase = .newSession
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
