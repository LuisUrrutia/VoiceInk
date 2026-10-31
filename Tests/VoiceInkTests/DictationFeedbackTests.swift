import XCTest
@testable import VoiceInk

@MainActor
final class DictationFeedbackTests: XCTestCase {
    // MARK: - Done and error policy

    func testDoneFollowsOnlyPastesAtLeastTwoSecondsAfterTheStopTone() {
        var stopped = DictationFeedback()
        XCTAssertEqual(stopped.recordingStopped(at: 10), .stop)
        XCTAssertNil(stopped.recordingStopped(at: 10.5))

        var fast = stopped
        XCTAssertNil(fast.pasteFinished(.commandPosted, at: 11.99))
        var slow = stopped
        XCTAssertEqual(slow.pasteFinished(.commandPosted, at: 12), .done)
        var withoutStop = DictationFeedback()
        XCTAssertNil(withoutStop.pasteFinished(.commandPosted, at: 100))
    }

    func testFailedPastesPlayOneErrorAndCancelledPastesStaySilent() {
        var stopped = DictationFeedback()
        _ = stopped.recordingStopped(at: 0)
        for failure: CursorPaster.PasteResult in [.commandNotPosted, .commandPartiallyPosted, .targetUnavailable] {
            var feedback = stopped
            XCTAssertEqual(feedback.pasteFinished(failure, at: 5), .error)
            XCTAssertNil(feedback.failed())
            XCTAssertNil(feedback.pasteFinished(.commandPosted, at: 6))
        }
        var cancelled = stopped
        XCTAssertNil(cancelled.pasteFinished(.cancelled, at: 5))

        var pastedBeforeStopTone = DictationFeedback()
        XCTAssertNil(pastedBeforeStopTone.pasteFinished(.commandPosted, at: 1))
        XCTAssertEqual(pastedBeforeStopTone.recordingStopped(at: 2), .stop)
        XCTAssertNil(pastedBeforeStopTone.failed())
    }

    func testCanceledOrSupersededSessionsPlayNothing() {
        let fixture = SessionFixture()
        fixture.session.recordingStopped()
        fixture.now = 3
        fixture.session.cancel()

        fixture.session.pasteFinished(.commandPosted)
        fixture.session.dictationFailed()

        XCTAssertEqual(fixture.tones, [.stop])
        let canceledBeforeStop = SessionFixture()
        canceledBeforeStop.session.cancel()
        canceledBeforeStop.session.recordingStopped()
        XCTAssertEqual(canceledBeforeStop.tones, [])

        let canceledThenCompleted = SessionFixture()
        canceledThenCompleted.session.cancel()
        canceledThenCompleted.session.completePipeline()
        canceledThenCompleted.session.recordingStopped()
        XCTAssertEqual(canceledThenCompleted.tones, [])
    }

    func testStopToneDelayedPastPipelineCompletionStillPlays() {
        let fixture = SessionFixture()

        fixture.session.pasteFinished(.commandPosted)
        fixture.session.completePipeline()
        fixture.session.recordingStopped()

        XCTAssertTrue(fixture.session.isCancelled)
        XCTAssertEqual(fixture.tones, [.stop])
    }

    // MARK: - Delivery outcomes

    func testDeliveryPlaysDoneOnlyForSlowPostedPastes() async {
        for (pasteTime, expected) in [(1.5, [DictationFeedback.Tone.stop]), (2.5, [.stop, .done])] {
            let fixture = SessionFixture()
            fixture.session.recordingStopped()
            var pastedText: String?

            await deliver(.paste, text: "hello", session: fixture.session) { text in
                pastedText = text
                fixture.now = pasteTime
                return .commandPosted
            }

            XCTAssertEqual(pastedText?.hasPrefix("hello"), true)
            XCTAssertEqual(fixture.tones, expected)
        }
    }

    func testDeliveryPlaysErrorForFailedPastesButNotForCancelledOrSupersededOnes() async {
        for result: CursorPaster.PasteResult in [.commandNotPosted, .commandPartiallyPosted, .targetUnavailable, .cancelled] {
            let fixture = SessionFixture()
            fixture.session.recordingStopped()

            await deliver(.paste, text: "hello", session: fixture.session) { _ in result }

            XCTAssertEqual(fixture.tones, result == .cancelled ? [.stop] : [.stop, .error], "\(result)")
        }
        let superseded = SessionFixture()
        superseded.session.recordingStopped()
        await deliver(.paste, text: "hello", session: superseded.session) { _ in
            superseded.now = 5
            superseded.session.cancel()
            return .commandPosted
        }
        XCTAssertEqual(superseded.tones, [.stop])
    }

    func testEmptyTranscriptIsAFailedDictationWithoutPasting() async {
        let fixture = SessionFixture()
        fixture.session.recordingStopped()
        var dismissed = false

        await deliver(.paste, text: " \n ", session: fixture.session, dismiss: { dismissed = true }) { _ in
            XCTFail("An empty transcript must not be pasted")
            return .commandPosted
        }

        XCTAssertTrue(dismissed)
        XCTAssertEqual(fixture.tones, [.stop, .error])
    }

    func testFailedTranscriptionRespondAndCustomCommandFailuresPlayErrorButCancellationDoesNot() async {
        let failed = SessionFixture()
        await deliver(.paste, text: nil, status: .failed, session: failed.session) { _ in .commandPosted }
        XCTAssertEqual(failed.tones, [.error])

        let canceled = SessionFixture()
        await deliver(.paste, text: nil, status: .canceled, session: canceled.session) { _ in .commandPosted }
        XCTAssertEqual(canceled.tones, [])

        let response = SessionFixture()
        var responseFailure: String?
        await deliver(.respond, text: "hello", responseError: "timeout", session: response.session,
            failResponse: { responseFailure = $0 }) { _ in .commandPosted }
        XCTAssertNotNil(responseFailure)
        XCTAssertEqual(response.tones, [.error])

        let command = SessionFixture()
        await deliver(.customCommand, text: "hello", session: command.session) { _ in .commandPosted }
        XCTAssertEqual(command.tones, [.error])
    }

    func testEmptyAssistantFollowUpIsAFailedDictation() async {
        let fixture = SessionFixture()
        fixture.session.recordingStopped()

        await deliver(.paste, text: " ", isAssistantFollowUp: true, session: fixture.session) { _ in
            XCTFail("A follow-up is not pasted")
            return .commandPosted
        }

        XCTAssertEqual(fixture.tones, [.stop, .error])
    }

    // MARK: - Helpers

    @MainActor private final class SessionFixture {
        var now: TimeInterval = 0
        var tones: [DictationFeedback.Tone] = []
        lazy var session = RecordingDeliverySession(
            destination: .currentApplication,
            playFeedback: { self.tones.append($0) },
            now: { self.now }
        )
    }

    private func deliver(
        _ outputMode: ModeOutputMode,
        text: String?,
        status: TranscriptionStatus = .completed,
        responseError: String? = nil,
        isAssistantFollowUp: Bool = false,
        session: RecordingDeliverySession,
        dismiss: @escaping () async -> Void = {},
        failResponse: @escaping (String) async -> Void = { _ in },
        paste: @escaping @MainActor (String) -> CursorPaster.PasteResult
    ) async {
        let request = TranscriptionDelivery.Request(
            transcription: Transcription(text: text ?? "", duration: 1, transcriptionStatus: status),
            text: text,
            output: OutputRuntimeConfiguration(mode: nil, outputMode: outputMode, autoSendKey: .none, customCommand: nil),
            responseConfig: nil, responseError: responseError, isAssistantFollowUp: isAssistantFollowUp, sendAfterPaste: false,
            deliverySession: session
        )
        let delivery = TranscriptionDelivery { text, _, _ in
            Task { @MainActor in
                CursorPaster.PasteOutcome(result: paste(text), autoLearnGeneration: nil, target: nil)
            }
        }
        await delivery.deliver(request, actions: .init(
            setState: { _ in }, dismiss: dismiss,
            sendFollowUp: { _, _ in XCTFail("No follow-up") }, showResponse: { _, _ in XCTFail("No response") },
            failResponse: failResponse
        ))
    }
}
