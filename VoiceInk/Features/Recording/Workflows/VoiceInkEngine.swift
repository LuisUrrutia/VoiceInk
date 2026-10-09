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

    @Published var recordingState: RecordingState = .idle
    @Published var shouldCancelRecording = false
    @Published var partialTranscript: String = ""
    @Published private(set) var recordingError: String?
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
    private var activeRecordingDelivery: RecordingDeliverySession?
    private var activePipelineDelivery: RecordingDeliverySession?
    private var activeRecordingStartID: UUID?
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

    let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "VoiceInkEngine")

    init(
        modelContext: ModelContext,
        whisperModelManager: WhisperModelManager,
        transcriptionModelManager: TranscriptionModelManager,
        enhancementService: AIEnhancementService? = nil,
        recorder: Recorder? = nil,
        captureReadiness: CaptureReadinessController? = nil
    ) {
        self.modelContext = modelContext
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
            modelContext: modelContext
        )
        self.pipeline = TranscriptionPipeline(
            modelContext: modelContext,
            serviceRegistry: serviceRegistry,
            enhancementService: enhancementService
        )

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
        deliverySession: RecordingDeliverySession? = nil
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
            let delivery = activeRecordingDelivery
            activeRecordingDelivery = nil
            activePipelineDelivery = delivery
            let context = recordingContextCapture.take()
            pipelineContextCapture = context
            defer {
                delivery?.cancel()
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
            recordingState = .transcribing
            await recorder.stopRecording()
            recordClosedAudioTiming(preparation?.timing)

            if let recordedFile = fileBeingStopped {
                if !shouldCancelRecording {
                    let transcription = makeRecordingTranscription(
                        for: recordedFile,
                        text: "",
                        duration: 0,
                        transcriptionStatus: .pending
                    )
                    modelContext.insert(transcription)
                    try? modelContext.save()
                    NotificationCenter.default.post(name: .transcriptionCreated, object: transcription)

                    if let error = recorder.recordingError {
                        recordingError = String(localized: "Recording failed. Check the microphone and try again.")
                        transcription.text = error.localizedDescription
                        transcription.transcriptionStatus = TranscriptionStatus.failed.rawValue
                        try? modelContext.save()
                        NotificationManager.shared.showNotification(
                            title: error.localizedDescription, type: .error
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
                        contextStore: context?.store,
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
            partialTranscript = ""
            activeRecordingUseCase = recordingUseCase
            clearActiveRecordingContext()

            if !recordingUseCase.isAssistantFollowUp {
                assistantSession.reset()
            }

            guard await passesRecordingPreflight(), !microphoneDiagnostic.isBusy,
                recordingState == .idle, !Task.isCancelled
            else { return }

            let preparation = RecordingTranscriptionPreparation(timing: capturedDelivery.timing)
            let startID = preparation.recordingID
            self.activeRecordingPreparation = preparation
            self.activeRecordingStartID = startID
            self.activeRecordingDelivery = capturedDelivery
            let activeModeTask = ActiveWindowService.shared.beginApplyingConfiguration(modeId: modeId) {
                [weak self] in
                guard let self else { return false }
                return !preparation.isCancelled
                    && (self.activeRecordingPreparation === preparation || self.activePipelinePreparation === preparation)
            }
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
                try await self.recorder.startRecording(toOutputFile: permanentURL)

                guard self.activeRecordingStartID == startID,
                    self.recorderUIManager?.isRecorderPanelVisible ?? false,
                    !self.shouldCancelRecording
                else {
                    preparation.cancel()
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
                self.startRecordingContextCapture(recordingID: startID)
                preparation.timing.mark(.contextStarted)

                let registry = self.serviceRegistry
                let models = self.transcriptionModelManager
                let whisper = self.whisperModelManager
                preparation.start(
                    resolveConfiguration: {
                        ModeRuntimeResolver.transcriptionConfiguration(transcriptionModelManager: models)
                    },
                    retireAutoLearn: {
                        if AutoLearnSettings.isEnabled {
                            await AutoLearnService.shared.recordingDidStart()
                        }
                    },
                    prepareModel: { configuration in
                        try await registry.prepareForRecording(configuration, whisperModelManager: whisper)
                    },
                    prepareSession: { [weak self] configuration in
                        guard registry.shouldUseRealtimeTranscription(for: configuration) else {
                            _ = realtimeAudioGate.reset()
                            return nil
                        }
                        let session = registry.createSession(
                            for: configuration,
                            onPartialTranscript: { [weak self] partial in
                                Task { @MainActor in
                                    guard let self, self.activeRecordingStartID == startID,
                                        self.recordingState == .recording
                                    else { return }
                                    self.partialTranscript = partial
                                }
                            }
                        )
                        do {
                            let callback = try await session.prepare(configuration: configuration)
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
                    }
                )

                let setup = try await preparation.setup()
                guard self.activeRecordingPreparation === preparation,
                    self.recordingState == .recording, !preparation.isCancelled
                else { return }

                guard let setup else {
                    let resolution = ModeRuntimeResolver.transcriptionModelResolution(transcriptionModelManager: models)
                    let failure = self.recordingModelFailure(for: resolution)
                    self.recordingError = failure.title
                    NotificationManager.shared.showNotification(
                        title: failure.title, type: .error, duration: 7.0,
                        actionButton: (failure.actionLabel, failure.action)
                    )
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
                guard self.activeRecordingStartID == startID,
                    let finalizationID = self.recordingFinalization.begin()
                else { return }
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
                        actionButton: (failure.actionLabel, failure.action)
                    )
                } else {
                    NotificationManager.shared.showNotification(
                        title: String(localized: "Recording failed to start"), type: .error)
                }
                await self.recorderUIManager?.dismissRecorderPanel()
            }
        }
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
    private func passesRecordingPreflight() async -> Bool {
        captureReadiness.refreshSnapshot()
        if let issue = captureReadiness.snapshot.issues(for: .microphoneTest).first {
            await failRecordingPreflight(
                title: issue.message,
                actionLabel: String(localized: "Audio Settings"),
                action: AudioSetupNavigator.openAudioSettings
            )
            return false
        }
        if !ModeManager.shared.hasEnabledConfiguration {
            await failRecordingPreflight(
                title: String(localized: "No mode configured"),
                actionLabel: String(localized: "Manage Modes"),
                action: ModeSetupNavigator.openModesSettings
            )
            return false
        }

        return true
    }

    @MainActor
    private func failRecordingPreflight(
        title: String,
        actionLabel: String,
        action: @escaping () -> Void
    ) async {
        logger.error("❌ Recording preflight failed: \(title, privacy: .public)")
        recordingState = .idle
        recordingError = title
        NotificationManager.shared.showNotification(
            title: title,
            type: .error,
            duration: 7.0,
            actionButton: (actionLabel, action)
        )
        await recorderUIManager?.dismissRecorderPanel()
    }

    // MARK: - Recording Context

    private func startRecordingContextCapture(recordingID: UUID) {
        recordingContextCapture.start(recordingID: recordingID)
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
        contextStore: RecordingContextSnapshotStore?,
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
            }
            try? modelContext.save()
            await finishPipeline(transcription, preparation: preparation)
            return
        }

        await pipeline.run(
            transcription: transcription,
            audioURL: audioURL,
            transcriptionConfiguration: transcriptionConfiguration,
            formattingConfiguration: {
                ModeRuntimeResolver.transcriptionFormattingConfiguration()
            },
            session: session,
            triggerWordModeSelection: { [weak self] text in
                self?.selectTriggerWordModeIfNeeded(for: text)
            },
            enhancementConfiguration: { [weak self] in
                guard let self,
                    let enhancementService = self.enhancementService,
                    let aiService = enhancementService.getAIService()
                else {
                    return nil
                }
                return ModeRuntimeResolver.currentEnhancementConfiguration(
                    enhancementService: enhancementService,
                    aiService: aiService
                )
            },
            recordingContextSnapshot: {
                await MainActor.run {
                    contextStore?.snapshot
                }
            },
            outputConfiguration: {
                ModeRuntimeResolver.outputConfiguration()
            },
            sendAfterPaste: sendAfterPaste,
            deliverySession: deliverySession,
            onStateChange: { [weak self] state in
                guard let self, self.activePipelineTranscriptionID == transcriptionID else { return }
                self.recordingState = state
            },
            shouldCancel: { [weak self] in
                guard let self else { return false }
                return self.canceledPipelineTranscriptionIDs.contains(transcriptionID)
                    || (self.activePipelineTranscriptionID == transcriptionID && self.shouldCancelRecording)
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
        let transcriptionID = transcription.id
        await recordingFinalization.waitUntilFinished()
        let didFinishActivePipeline = activePipelineTranscriptionID == transcriptionID
        if didFinishActivePipeline {
            if transcription.transcriptionStatus == TranscriptionStatus.failed.rawValue {
                recordingError = String(localized: "Transcription failed. Check the model or provider in Models.")
            }
            guard let finalizationID = recordingFinalization.begin() else { return }
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
            let outcome: RecordingTimingTrace.Outcome =
                transcription.transcriptionStatus == TranscriptionStatus.canceled.rawValue ? .canceled
                : transcription.transcriptionStatus == TranscriptionStatus.failed.rawValue ? .failed : .completed
            preparation?.timing.mark(.idle, outcome: outcome)
        }
    }

    private func selectTriggerWordModeIfNeeded(for text: String) -> String? {
        guard let (triggeredMode, processedText) = ModeManager.shared.getConfigurationForTriggerWord(text) else {
            return nil
        }

        ModeManager.shared.setActiveConfiguration(triggeredMode)
        return processedText
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
        let timing = (activeRecordingPreparation ?? activePipelinePreparation)?.timing
        await recorder.stopRecording()
        recordClosedAudioTiming(timing)
        await saveCanceledRecording(at: fileBeingCancelled)
        recordedFile = nil
        partialTranscript = ""
        recordingState = .idle
        await cleanupResources()
    }

    private func saveCanceledRecording(at recordedFile: URL?) async {
        guard let recordedFile,
            FileManager.default.fileExists(atPath: recordedFile.path)
        else { return }

        let duration = await AudioFileMetadata.duration(for: recordedFile)
        let transcription = makeRecordingTranscription(
            for: recordedFile,
            text: Transcription.canceledTranscriptionText,
            duration: duration,
            transcriptionStatus: .canceled
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
        transcriptionStatus: TranscriptionStatus
    ) -> Transcription {
        let modeMetadata = currentModeMetadata()

        return Transcription(
            text: text,
            duration: duration,
            audioFileURL: audioURL.absoluteString,
            transcriptionModelName: ModeRuntimeResolver.transcriptionConfiguration(
                transcriptionModelManager: transcriptionModelManager
            )?.model.displayName,
            modeName: modeMetadata.name,
            modeEmoji: modeMetadata.emoji,
            transcriptionStatus: transcriptionStatus
        )
    }

    private func currentModeMetadata() -> (name: String?, emoji: String?) {
        guard let mode = ModeManager.shared.currentEffectiveConfiguration,
            mode.isEnabled
        else {
            return (nil, nil)
        }

        return (mode.name, mode.icon.value)
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
        await preparationTask?.value

        enhancementService?.clearCapturedContexts()
        await enhancementService?
            .getAIService()?
            .voiceInkRefineService
            .unloadPreparedModelIfNeeded()
    }

    private func recordClosedAudioTiming(_ timing: RecordingTimingTrace?) {
        if let firstAudio = recorder.firstAudioTimestampNanoseconds {
            timing?.mark(.firstAudio, at: firstAudio)
        }
        timing?.mark(.wavClosed, outcome: recorder.recordingError == nil ? .completed : .failed)
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
