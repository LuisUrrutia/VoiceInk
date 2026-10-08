import Foundation
import os

@MainActor
final class TranscriptionDelivery {
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "TranscriptionDelivery")

    struct Request {
        let transcription: Transcription
        let text: String?
        let output: OutputRuntimeConfiguration
        let responseConfig: EnhancementRuntimeConfiguration?
        let responseError: String?
        let isAssistantFollowUp: Bool
        let sendAfterPaste: Bool
        var deliverySession: RecordingDeliverySession? = nil
    }

    struct Actions {
        let setState: (RecordingState) -> Void
        let dismiss: () async -> Void
        let sendFollowUp: (String, Transcription) async -> Void
        let showResponse: (String, String?) async -> Void
        let failResponse: (String) async -> Void
    }

    func deliver(_ request: Request, actions: Actions) async {
        guard !Task.isCancelled, request.deliverySession?.isCancelled != true else { return }
        guard request.transcription.transcriptionStatus == TranscriptionStatus.completed.rawValue else {
            await actions.dismiss()
            return
        }

        if request.isAssistantFollowUp {
            await deliverFollowUp(request, actions: actions)
            return
        }

        if request.output.outputMode == .respond,
            request.responseConfig != nil || request.responseError != nil
        {
            await deliverResponse(request, actions: actions)
            return
        }

        if request.output.outputMode == .customCommand {
            await deliverCustomCommand(request, actions: actions)
            return
        }

        if let text = request.text {
            await paste(text, sendAfterPaste: request.sendAfterPaste, session: request.deliverySession, actions: actions)
        } else {
            await actions.dismiss()
        }
    }

    private func deliverFollowUp(_ item: Request, actions: Actions) async {
        SoundManager.shared.playStopSound()

        guard let text = item.text?.trimmingCharacters(in: .whitespacesAndNewlines),
            !text.isEmpty
        else {
            return
        }

        actions.setState(.enhancing)
        await actions.sendFollowUp(text, item.transcription)
    }

    private func deliverResponse(_ item: Request, actions: Actions) async {
        SoundManager.shared.playStopSound()

        if let responseError = item.responseError {
            await actions.failResponse("Enhancement failed: \(responseError)")
        } else if let text = item.text,
            item.responseConfig != nil
        {
            await actions.showResponse(text, item.transcription.aiRequestSystemMessage)
        } else {
            await actions.failResponse("No response was generated.")
        }
    }

    private func deliverCustomCommand(_ item: Request, actions: Actions) async {
        guard let text = item.text else {
            notifyCustomCommandFailure(CustomCommandDeliveryError.noTextToDeliver)
            SoundManager.shared.playStopSound()
            await actions.dismiss()
            return
        }

        guard let customCommand = item.output.customCommand,
            let command = customCommand.trimmedCommand
        else {
            notifyCustomCommandFailure(CustomCommandDeliveryError.commandNotConfigured)
            SoundManager.shared.playStopSound()
            await actions.dismiss()
            return
        }

        let finishAndSendKey: FinishAndSendKey = item.sendAfterPaste ? FinishAndSendSettings.selectedKey : .none
        SoundManager.shared.playStopSound()
        await actions.dismiss()

        let target = PasteApplication.frontmost
        let task = Task {
            await runCustomCommand(
                command: command, commandText: text, finishAndSendKey: finishAndSendKey,
                target: target, session: item.deliverySession
            )
        }
        item.deliverySession?.own(task)
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func runCustomCommand(
        command: String, commandText: String, finishAndSendKey: FinishAndSendKey,
        target: PasteApplication?, session: RecordingDeliverySession?
    ) async {
        guard !Task.isCancelled, session?.isCancelled != true else { return }
        let startTime = Date()
        logger.notice("Custom command started")

        do {
            let result = try await CustomCommandDeliveryRunner.run(
                command: command,
                timeout: 10,
                context: CustomCommandDeliveryContext(transcript: commandText)
            )

            let duration = Date().timeIntervalSince(startTime)
            let stdoutBytes = result.stdout.utf8.count
            let stderrBytes = result.stderr.utf8.count

            if !result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                logger.notice(
                    "Custom command stdout bytes=\(stdoutBytes, privacy: .public): \(result.stdout, privacy: .public)")
            }

            if !result.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                logger.notice(
                    "Custom command succeeded with stderr duration=\(Self.formattedDuration(duration), privacy: .public)s stdoutBytes=\(stdoutBytes, privacy: .public) stderrBytes=\(stderrBytes, privacy: .public): \(result.stderr, privacy: .public)"
                )
            } else {
                logger.notice(
                    "Custom command succeeded duration=\(Self.formattedDuration(duration), privacy: .public)s stdoutBytes=\(stdoutBytes, privacy: .public) stderrBytes=\(stderrBytes, privacy: .public)"
                )
            }

            if finishAndSendKey.isEnabled {
                // Let the target app finish pasting before sending.
                try await Task.sleep(nanoseconds: 150_000_000)
                guard !Task.isCancelled, session?.isCancelled != true,
                    let target, target == PasteApplication.frontmost, target.runningApplication != nil
                else { return }
                CursorPaster.performSendKey(finishAndSendKey)
            }
        } catch is CancellationError {
            return
        } catch {
            notifyCustomCommandFailure(error, duration: Date().timeIntervalSince(startTime))
        }
    }

    private func notifyCustomCommandFailure(_ error: Error, duration: TimeInterval? = nil) {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        if let duration {
            logger.error(
                "Custom command failed duration=\(Self.formattedDuration(duration), privacy: .public)s: \(message, privacy: .public)"
            )
        } else {
            logger.error("Custom command failed: \(message, privacy: .public)")
        }
    }

    private static func formattedDuration(_ duration: TimeInterval) -> String {
        String(format: "%.3f", duration)
    }

    private func paste(
        _ text: String, sendAfterPaste: Bool, session: RecordingDeliverySession?, actions: Actions
    ) async {
        let appendSpace = UserDefaults.standard.bool(forKey: "AppendTrailingSpace")
        let pastedText = text + (appendSpace ? " " : "")
        SoundManager.shared.playStopSound()
        await actions.dismiss()
        guard !Task.isCancelled, session?.isCancelled != true else { return }

        let finishAndSendKey: FinishAndSendKey = sendAfterPaste ? FinishAndSendSettings.selectedKey : .none
        let pasteTask = CursorPaster.startPasteAtCursor(pastedText, deliverySession: session, sendKey: finishAndSendKey)
        _ = await withTaskCancellationHandler {
            await pasteTask.value
        } onCancel: {
            pasteTask.cancel()
        }
    }
}
