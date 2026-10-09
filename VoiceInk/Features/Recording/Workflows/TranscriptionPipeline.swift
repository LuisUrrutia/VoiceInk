import Foundation
import SwiftData
import os

/// Handles the full post-recording pipeline:
/// transcribe → filter → format → word-replace → AI enhance → deliver → save
@MainActor
class TranscriptionPipeline {
    struct AssistantHooks {
        let isFollowUp: Bool
        let sendFollowUp: (String, Transcription) async -> Void
        let startResponse: (String, EnhancementRuntimeConfiguration) async -> Void
        let showResponse: (String, String?) async -> Void
        let failResponse: (String) async -> Void

        static let inactive = AssistantHooks(
            isFollowUp: false,
            sendFollowUp: { _, _ in },
            startResponse: { _, _ in },
            showResponse: { _, _ in },
            failResponse: { _ in }
        )
    }

    private let modelContext: ModelContext
    private let serviceRegistry: TranscriptionServiceRegistry
    private let enhancementService: AIEnhancementService?
    private let delivery = TranscriptionDelivery()
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "TranscriptionPipeline")

    init(
        modelContext: ModelContext,
        serviceRegistry: TranscriptionServiceRegistry,
        enhancementService: AIEnhancementService?
    ) {
        self.modelContext = modelContext
        self.serviceRegistry = serviceRegistry
        self.enhancementService = enhancementService
    }

    /// Run the full pipeline for a given transcription record.
    /// - Parameters:
    ///   - transcription: The pending Transcription SwiftData object to populate and save.
    ///   - audioURL: The recorded audio file.
    ///   - transcriptionConfiguration: Mode-resolved transcription engine settings for this phase.
    ///   - session: An active streaming session if one was prepared, otherwise nil.
    ///   - onStateChange: Called when the pipeline moves to a new recording state (e.g. `.enhancing`).
    ///   - shouldCancel: Returns true if the user requested cancellation.
    ///   - onCancel: Called when cancellation is detected to cancel active session state.
    ///   - onDismiss: Called when delivery should close the recorder panel.
    func run(
        transcription: Transcription,
        audioURL: URL,
        transcriptionConfiguration: TranscriptionRuntimeConfiguration,
        formattingConfiguration resolveFormattingConfiguration: @escaping () -> TranscriptionFormattingConfiguration,
        session: TranscriptionSession?,
        triggerWordModeSelection: @escaping (String) -> String? = { _ in nil },
        enhancementConfiguration: @escaping () -> EnhancementRuntimeConfiguration?,
        recordingContextSnapshot: @escaping () async -> RecordingContextSnapshot? = { nil },
        outputConfiguration: @escaping () -> OutputRuntimeConfiguration,
        sendAfterPaste: Bool = false,
        deliverySession: RecordingDeliverySession? = nil,
        preparation: RecordingTranscriptionPreparation? = nil,
        onStateChange: @escaping (RecordingState) -> Void,
        shouldCancel: () -> Bool,
        onCancel: @escaping () async -> Void,
        onDismiss: @escaping () async -> Void,
        assistant: AssistantHooks = .inactive
    ) async {
        let model = transcriptionConfiguration.model
        var finalText: String?
        var responseError: String?
        var outputForDelivery: OutputRuntimeConfiguration?
        var responseConfig: EnhancementRuntimeConfiguration?

        func finishCanceledTranscription() async {
            await onCancel()

            let canceledDuration: TimeInterval?
            if transcription.duration > 0 {
                canceledDuration = nil
            } else {
                let duration = await AudioFileMetadata.duration(for: audioURL)
                canceledDuration = duration > 0 ? duration : nil
            }

            transcription.markAsCanceledTranscription(
                duration: canceledDuration,
                modelName: transcription.transcriptionModelName ?? model.displayName
            )

            do {
                try modelContext.save()
            } catch {
                logger.error("Failed to save canceled transcription: \(error, privacy: .public)")
            }
        }

        if shouldCancel() {
            await finishCanceledTranscription()
            return
        }

        do {
            deliverySession?.timing.mark(.asrStarted)
            let transcriptionStart = Date()
            var text: String
            let transcribe: @MainActor () async throws -> String = { [serviceRegistry] in
                if let session { return try await session.transcribe(audioURL: audioURL) }
                return try await serviceRegistry.transcribe(
                    audioURL: audioURL, model: model, context: transcriptionConfiguration.requestContext
                )
            }
            if let preparation {
                text = try await preparation.performTranscription(transcribe)
            } else {
                text = try await transcribe()
            }
            text = TranscriptionOutputFilter.filter(text)
            deliverySession?.timing.mark(.asrFinished)
            let transcriptionDuration = Date().timeIntervalSince(transcriptionStart)

            if shouldCancel() {
                await finishCanceledTranscription()
                return
            }

            text = text.trimmingCharacters(in: .whitespacesAndNewlines)

            if !assistant.isFollowUp,
                let processedText = triggerWordModeSelection(text)
            {
                text = processedText
            }

            let formattingConfiguration = resolveFormattingConfiguration()
            let resolvedEnhancementConfiguration = enhancementConfiguration()
            let resolvedOutputConfiguration = outputConfiguration()
            let modeMetadata = metadata(
                for: formattingConfiguration.mode ?? resolvedEnhancementConfiguration?.mode
                    ?? resolvedOutputConfiguration.mode ?? transcriptionConfiguration.mode
            )

            if formattingConfiguration.isTextFormattingEnabled {
                text = ParagraphFormatter.format(text)
            }

            text = WordReplacementService.shared.applyReplacements(to: text, using: modelContext)
            let cleanedText = text

            let actualDuration = await AudioFileMetadata.duration(for: audioURL)

            transcription.text = cleanedText
            transcription.duration = actualDuration
            transcription.transcriptionModelName = model.displayName
            transcription.transcriptionDuration = transcriptionDuration
            transcription.modeName = modeMetadata.name
            transcription.modeEmoji = modeMetadata.emoji
            finalText = cleanedText

            if !assistant.isFollowUp {
                let shouldRespondInRecorder =
                    resolvedOutputConfiguration.outputMode == .respond
                    && resolvedEnhancementConfiguration?.isEnabled == true
                    && resolvedEnhancementConfiguration.map { configuration in
                        enhancementService?.isConfigured(for: configuration) == true
                    } == true
                outputForDelivery = resolvedOutputConfiguration
                responseConfig = shouldRespondInRecorder ? resolvedEnhancementConfiguration : nil

                let isSkipShortEnhancementEnabled = UserDefaults.standard.bool(forKey: "SkipShortEnhancement")
                let savedThreshold = UserDefaults.standard.integer(forKey: "ShortEnhancementWordThreshold")
                let shortEnhancementWordThreshold = savedThreshold > 0 ? savedThreshold : 3
                let shouldSkipEnhancement =
                    !shouldRespondInRecorder && isSkipShortEnhancementEnabled
                    && WordCounter.count(in: text) <= shortEnhancementWordThreshold

                if let enhancementService,
                    let resolvedEnhancementConfiguration,
                    resolvedEnhancementConfiguration.isEnabled,
                    enhancementService.isConfigured(for: resolvedEnhancementConfiguration),
                    !shouldSkipEnhancement
                {
                    if shouldCancel() {
                        await finishCanceledTranscription()
                        return
                    }

                    onStateChange(.enhancing)
                    let textForAI = text
                    if shouldRespondInRecorder {
                        await assistant.startResponse(textForAI, resolvedEnhancementConfiguration)
                    }

                    do {
                        deliverySession?.timing.mark(.enhancementStarted)
                        let contextSnapshot = await recordingContextSnapshot()
                        transcription.aiEnhancementModelName =
                            resolvedEnhancementConfiguration.modelName
                            ?? resolvedEnhancementConfiguration.provider?.defaultModel
                        transcription.promptName = resolvedEnhancementConfiguration.prompt?.title
                        let enhancementResult = try await Self.performEnhancement(deliverySession: deliverySession) {
                            try await enhancementService.enhance(
                                textForAI,
                                configuration: resolvedEnhancementConfiguration,
                                contextSnapshot: contextSnapshot
                            )
                        }
                        transcription.enhancedText = enhancementResult.text
                        transcription.promptName =
                            enhancementResult.promptName ?? resolvedEnhancementConfiguration.prompt?.title
                        transcription.enhancementDuration = enhancementResult.duration
                        transcription.aiRequestSystemMessage = enhancementResult.systemMessage
                        transcription.aiRequestUserMessage = enhancementResult.userMessage
                        finalText = enhancementResult.text
                        deliverySession?.timing.mark(.enhancementFinished)
                    } catch {
                        let wasCanceled = shouldCancel() || Task.isCancelled || error is CancellationError
                            || deliverySession?.isCancelled == true
                        deliverySession?.timing.mark(.enhancementFinished, outcome: wasCanceled ? .canceled : .failed)
                        if wasCanceled {
                            await finishCanceledTranscription()
                            return
                        }
                        let errorDescription = EnhancementFailureFormatter.description(for: error)
                        let failureMessage = EnhancementFailureFormatter.message(description: errorDescription)
                        transcription.enhancedText = failureMessage
                        responseError = errorDescription
                        await MainActor.run {
                            NotificationManager.shared.showNotification(
                                title: failureMessage,
                                type: .warning
                            )
                        }
                        if shouldCancel() {
                            await finishCanceledTranscription()
                            return
                        }
                    }
                }
            }

            transcription.transcriptionStatus = TranscriptionStatus.completed.rawValue
        } catch {
            let wasCanceled = shouldCancel() || Task.isCancelled || error is CancellationError
                || deliverySession?.isCancelled == true || preparation?.isCancelled == true
            deliverySession?.timing.mark(.asrFinished, outcome: wasCanceled ? .canceled : .failed)
            if wasCanceled {
                await finishCanceledTranscription()
                return
            }
            let errorDescription = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription

            if let nativeAppleError = error as? NativeAppleTranscriptionService.ServiceError,
                nativeAppleError.shouldShowNotification
            {
                await MainActor.run {
                    NotificationManager.shared.showNotification(
                        title: errorDescription,
                        type: .error,
                        duration: 5.0
                    )
                }
            }

            transcription.text = String(format: String(localized: "Transcription Failed: %@"), errorDescription)
            transcription.transcriptionStatus = TranscriptionStatus.failed.rawValue
        }

        func saveTranscriptionAndPostCompletion() {
            var didInsertSessionMetric = false

            if transcription.transcriptionStatus == TranscriptionStatus.completed.rawValue {
                do {
                    didInsertSessionMetric = try SessionMetricRecorder.recordRecorderSession(
                        transcription: transcription,
                        model: model,
                        in: modelContext
                    )
                } catch {
                    logger.error("Failed to record session metric: \(error, privacy: .public)")
                }
            }

            do {
                try modelContext.save()
                if didInsertSessionMetric {
                    NotificationCenter.default.post(name: .sessionMetricsDidChange, object: nil)
                }
                NotificationCenter.default.post(name: .transcriptionCompleted, object: transcription)
            } catch {
                logger.error("Failed to save transcription: \(error, privacy: .public)")
            }
        }

        if shouldCancel() {
            await finishCanceledTranscription()
            return
        }

        deliverySession?.timing.mark(.deliveryStarted)
        await delivery.deliver(
            TranscriptionDelivery.Request(
                transcription: transcription,
                text: finalText,
                output: outputForDelivery ?? outputConfiguration(),
                responseConfig: responseConfig,
                responseError: responseError,
                isAssistantFollowUp: assistant.isFollowUp,
                sendAfterPaste: sendAfterPaste,
                deliverySession: deliverySession
            ),
            actions: TranscriptionDelivery.Actions(
                setState: onStateChange,
                dismiss: onDismiss,
                sendFollowUp: assistant.sendFollowUp,
                showResponse: assistant.showResponse,
                failResponse: assistant.failResponse
            )
        )
        deliverySession?.timing.mark(.deliveryFinished, outcome: shouldCancel() ? .canceled : .completed)

        saveTranscriptionAndPostCompletion()
    }

    static func performEnhancement<Result>(
        deliverySession: RecordingDeliverySession?,
        operation: @escaping @MainActor () async throws -> Result
    ) async throws -> Result {
        let task = Task {
            try Task.checkCancellation()
            return try await operation()
        }
        deliverySession?.own(task)
        let result = try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await task.value
        } onCancel: {
            task.cancel()
        }
        try Task.checkCancellation()
        guard deliverySession?.isCancelled != true else { throw CancellationError() }
        return result
    }

    private func metadata(for mode: ModeConfig?) -> (name: String?, emoji: String?) {
        guard let mode, mode.isEnabled else {
            return (nil, nil)
        }

        return (mode.name, mode.icon.value)
    }
}
