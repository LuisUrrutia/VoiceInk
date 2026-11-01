import AppKit
import XCTest

@testable import VoiceInk

@MainActor
final class DictationOutputQueueTests: XCTestCase {
    private static let editor = PasteApplication(processID: 4242, bundleIdentifier: "com.example.editor")
    private static let other = PasteApplication(processID: 4343, bundleIdentifier: "com.example.other")

    // Hex: parallel_processing_results_are_released_in_submission_order
    func testResultsAreReleasedInSubmissionOrder() async throws {
        let queue = DictationOutputQueue(capacity: 4)
        let sequences = (0..<3).map { _ in queue.assignSequence() }
        let log = DeliveryLog()

        let second = submit(sequences[1], to: queue, log: log)
        try await settle()
        XCTAssertEqual(log.delivered, [])

        let first = submit(sequences[0], to: queue, log: log)
        try await waitUntil { log.delivered.count == 2 }
        XCTAssertEqual(log.delivered, [sequences[0], sequences[1]])

        let third = submit(sequences[2], to: queue, log: log)
        try await waitUntil { log.delivered.count == 3 }
        XCTAssertEqual(log.delivered, sequences)
        let results = [await first.value, await second.value, await third.value]
        XCTAssertEqual(results, [true, true, true])
        XCTAssertEqual(queue.waitingCount, 0)
    }

    func testOutOfOrderCompletionsDeliverInSubmissionOrder() async throws {
        let queue = DictationOutputQueue(capacity: 4)
        let sequences = (0..<3).map { _ in queue.assignSequence() }
        let log = DeliveryLog()

        let tasks = [2, 0, 1].map { submit(sequences[$0], to: queue, log: log) }
        try await waitUntil { log.delivered.count == 3 }

        XCTAssertEqual(log.delivered, sequences)
        for task in tasks { _ = await task.value }
    }

    // Hex: ordered_waiting_outputs_remain_bounded_after_channel_drain
    func testAdmissionStaysBoundedWhileOutputsWaitAndFreesOnJobRemoval() async throws {
        let capacity = 4
        let queue = DictationOutputQueue(capacity: capacity)
        let dictations = (0..<capacity).map { _ in UUID() }
        for dictation in dictations { XCTAssertTrue(queue.admit(dictation)) }
        let sequences = dictations.map { _ in queue.assignSequence() }
        let log = DeliveryLog()

        let waiting = sequences.dropFirst().map { submit($0, to: queue, log: log) }
        try await settle()

        XCTAssertFalse(queue.admit(UUID()))
        XCTAssertTrue(queue.admit(dictations[1]), "An admitted dictation keeps its slot")
        XCTAssertEqual(queue.admittedCount, capacity)
        XCTAssertEqual(queue.waitingCount, capacity - 1)
        XCTAssertEqual(log.delivered, [])

        queue.withdraw(dictations[0])
        XCTAssertTrue(queue.admit(UUID()))
        XCTAssertFalse(queue.admit(UUID()))

        queue.skip(sequences[0])
        try await waitUntil { log.delivered.count == capacity - 1 }
        XCTAssertEqual(log.delivered, Array(sequences.dropFirst()))
        for task in waiting { _ = await task.value }
    }

    // Hex: cancellation_replaces_waiting_output_and_ignores_late_completion
    func testCancellationReplacesAWaitingOutputAndIgnoresItsLateCompletion() async throws {
        let queue = DictationOutputQueue(capacity: 4)
        let first = queue.assignSequence()
        let second = queue.assignSequence()
        let log = DeliveryLog()

        let replaced = submit(second, to: queue, log: log)
        try await settle()
        queue.skip(second)
        let replacedResult = await replaced.value
        XCTAssertFalse(replacedResult)

        let firstResult = await submit(first, to: queue, log: log).value
        XCTAssertTrue(firstResult)
        let lateResult = await submit(second, to: queue, log: log).value
        XCTAssertFalse(lateResult)
        XCTAssertEqual(log.delivered, [first])
        XCTAssertEqual(queue.waitingCount, 0)
    }

    func testPlaceholderUnblocksLaterOutputsAndIgnoresALateCompletion() async throws {
        let queue = DictationOutputQueue(capacity: 4)
        let skipped = queue.assignSequence()
        let next = queue.assignSequence()
        let log = DeliveryLog()

        queue.skip(skipped)
        let nextResult = await submit(next, to: queue, log: log).value
        let lateResult = await submit(skipped, to: queue, log: log).value

        XCTAssertTrue(nextResult)
        XCTAssertFalse(lateResult)
        XCTAssertEqual(log.delivered, [next])
    }

    func testCancelingAWaitingTaskLeavesAPlaceholder() async throws {
        let queue = DictationOutputQueue(capacity: 4)
        let first = queue.assignSequence()
        let second = queue.assignSequence()
        let third = queue.assignSequence()
        let log = DeliveryLog()

        let canceled = submit(second, to: queue, log: log)
        let later = submit(third, to: queue, log: log)
        try await settle()
        canceled.cancel()
        let canceledResult = await canceled.value
        XCTAssertFalse(canceledResult)

        _ = await submit(first, to: queue, log: log).value
        _ = await later.value
        XCTAssertEqual(log.delivered, [first, third])
    }

    func testOneDeliveryRunsAtATimeUntilItsPasteFinishes() async throws {
        let queue = DictationOutputQueue(capacity: 4)
        let first = queue.assignSequence()
        let second = queue.assignSequence()
        let log = DeliveryLog()
        let gate = DeliveryGate()

        let running = submit(first, to: queue, log: log, gate: gate)
        try await waitUntil { log.delivered == [first] }
        let next = submit(second, to: queue, log: log)
        try await settle()
        XCTAssertEqual(log.delivered, [first])
        XCTAssertEqual(log.finished, [])

        queue.skip(first)
        try await settle()
        XCTAssertEqual(log.delivered, [first], "A released delivery ignores a late placeholder")
        gate.release()
        _ = await running.value
        _ = await next.value
        XCTAssertEqual(log.finished, [first, second])
    }

    // MARK: - Delivery release rule

    func testOutputWaitsForTheCaptureWhenItsDestinationIsNotFrontmost() async throws {
        let queue = DictationOutputQueue(capacity: 4)
        var captureActive = true
        queue.isCaptureActive = { captureActive }
        queue.frontmost = { Self.other }
        let sequence = queue.assignSequence()
        let log = DeliveryLog()

        let held = submit(sequence, to: queue, log: log, destination: .originalApplication(Self.editor))
        try await settle()
        queue.releaseHeldOutputs()
        try await settle()
        XCTAssertEqual(log.delivered, [])

        captureActive = false
        queue.releaseHeldOutputs()
        let result = await held.value
        XCTAssertTrue(result)
        XCTAssertEqual(log.delivered, [sequence])
    }

    func testHeldRecordingShortcutHoldsAFrontmostDestinationUntilTheCaptureStops() async throws {
        let queue = DictationOutputQueue(capacity: 4)
        var captureActive = true
        queue.isCaptureActive = { captureActive }
        queue.isRecordingShortcutHeld = { true }
        queue.frontmost = { Self.editor }
        let sequence = queue.assignSequence()
        let log = DeliveryLog()

        let held = submit(sequence, to: queue, log: log, destination: .originalApplication(Self.editor))
        try await settle()
        XCTAssertEqual(log.delivered, [])

        captureActive = false
        queue.releaseHeldOutputs()
        _ = await held.value
        XCTAssertEqual(log.delivered, [sequence])
    }

    func testOutputReleasesDuringACaptureOnlyToAFrontmostDestinationWithoutAHeldShortcut() {
        let queue = DictationOutputQueue(capacity: 4)
        var captureActive = false
        var frontmost: PasteApplication? = Self.other
        queue.isCaptureActive = { captureActive }
        queue.frontmost = { frontmost }
        let original = PasteDestination.originalApplication(Self.editor)

        XCTAssertTrue(queue.mayRelease(to: original), "Without a capture, delivery never waits")
        captureActive = true
        XCTAssertFalse(queue.mayRelease(to: original))
        XCTAssertTrue(queue.mayRelease(to: .currentApplication))
        frontmost = Self.editor
        XCTAssertTrue(queue.mayRelease(to: original))
        queue.isRecordingShortcutHeld = { true }
        XCTAssertFalse(queue.mayRelease(to: original))
        XCTAssertFalse(queue.mayRelease(to: .currentApplication))
    }

    // MARK: - Commit point

    func testCancelIsRefusedOnlyAfterTheCommitPoint() {
        let canceled = RecordingDeliverySession(destination: .currentApplication, playFeedback: { _ in })
        XCTAssertTrue(canceled.cancelBeforeOutput())
        XCTAssertTrue(canceled.isCancelled)
        XCTAssertFalse(canceled.commitOutput())
        XCTAssertFalse(canceled.hasCommittedOutput)

        let committed = RecordingDeliverySession(destination: .currentApplication, playFeedback: { _ in })
        XCTAssertTrue(committed.commitOutput())
        XCTAssertFalse(committed.cancelBeforeOutput())
        XCTAssertFalse(committed.isCancelled)
        committed.cancel()
        XCTAssertTrue(committed.isCancelled, "Teardown still ends a committed session")
    }

    func testFirstClipboardWriteCommitsAndRefusesALaterCancel() async {
        let fixture = PasteFixture()
        let delivery = RecordingDeliverySession(destination: .currentApplication, playFeedback: { _ in })
        var refusedDuringPaste: Bool?
        fixture.onPost = {
            XCTAssertTrue(delivery.hasCommittedOutput)
            refusedDuringPaste = !delivery.cancelBeforeOutput()
        }

        let outcome = await fixture.paste("first", delivery: delivery)

        XCTAssertEqual(outcome.result, .commandPosted)
        XCTAssertEqual(refusedDuringPaste, true)
        XCTAssertFalse(delivery.isCancelled)
        XCTAssertEqual(fixture.postedTexts, ["first"])
    }

    func testCancelBeforeTheClipboardWriteInsertsNothing() async {
        let fixture = PasteFixture()
        fixture.frontmost = Self.other
        let delivery = RecordingDeliverySession(destination: .originalApplication(Self.editor), playFeedback: { _ in })
        fixture.onActivate = { XCTAssertTrue(delivery.cancelBeforeOutput()) }
        fixture.board.clearContents()
        fixture.board.setString("original", forType: .string)

        let outcome = await fixture.paste("first", delivery: delivery)

        XCTAssertEqual(outcome.result, .cancelled)
        XCTAssertFalse(delivery.hasCommittedOutput)
        XCTAssertEqual(fixture.postedTexts, [])
        XCTAssertEqual(fixture.board.string(forType: .string), "original")
    }

    func testFirstTypedChunkCommitsTheOutput() async {
        let fixture = PasteFixture()
        let delivery = RecordingDeliverySession(destination: .currentApplication, playFeedback: { _ in })
        var committedBeforeTyping: Bool?

        fixture.onType = { committedBeforeTyping = delivery.hasCommittedOutput }
        let outcome = await fixture.paste("typed", delivery: delivery, method: .directTyping)

        XCTAssertEqual(outcome.result, .commandPosted)
        XCTAssertEqual(committedBeforeTyping, false)
        XCTAssertTrue(delivery.hasCommittedOutput)
        XCTAssertEqual(fixture.typedTexts, ["typed"])
    }

    // MARK: - Clipboard chain

    func testClipboardRestoresTheOriginalAcrossTwoQueuedOutputs() async throws {
        let fixture = PasteFixture()
        let data = Data([1, 2, 3])
        fixture.board.clearContents()
        fixture.board.setData(data, forType: .pdf)
        fixture.board.setString("original", forType: .string)
        let queue = DictationOutputQueue(capacity: 2)
        let first = queue.assignSequence()
        let second = queue.assignSequence()
        let deliveries = [
            RecordingDeliverySession(destination: .currentApplication, playFeedback: { _ in }),
            RecordingDeliverySession(destination: .currentApplication, playFeedback: { _ in }),
        ]

        let later = Task { @MainActor in
            await queue.deliver(sequence: second, destination: .currentApplication) {
                _ = await fixture.paste("second", delivery: deliveries[1], restore: true)
            }
        }
        try await settle()
        let earlier = await queue.deliver(sequence: first, destination: .currentApplication) {
            _ = await fixture.paste("first", delivery: deliveries[0], restore: true)
        }
        let laterResult = await later.value
        XCTAssertTrue(earlier)
        XCTAssertTrue(laterResult)
        XCTAssertEqual(fixture.postedTexts, ["first", "second"])

        try await waitUntil(timeout: .seconds(3)) { fixture.board.string(forType: .string) == "original" }
        XCTAssertEqual(fixture.board.data(forType: .pdf), data)
    }

    // MARK: - Helpers

    private func submit(
        _ sequence: UInt64, to queue: DictationOutputQueue, log: DeliveryLog, gate: DeliveryGate? = nil,
        destination: PasteDestination? = nil
    ) -> Task<Bool, Never> {
        Task { @MainActor in
            await queue.deliver(sequence: sequence, destination: destination) {
                log.delivered.append(sequence)
                await gate?.wait()
                log.finished.append(sequence)
            }
        }
    }

    private func settle() async throws {
        try await Task.sleep(for: .milliseconds(20))
    }

    private func waitUntil(timeout: Duration = .seconds(3), _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else { return XCTFail("Condition not reached") }
            try await Task.sleep(for: .milliseconds(1))
        }
    }
}

@MainActor
private final class DeliveryLog {
    var delivered: [UInt64] = []
    var finished: [UInt64] = []
}

@MainActor
private final class DeliveryGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isReleased = false

    func wait() async {
        if !isReleased { await withCheckedContinuation { continuation = $0 } }
    }

    func release() {
        isReleased = true
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
private final class PasteFixture {
    let board = NSPasteboard(name: NSPasteboard.Name("DictationOutputQueueTests-\(UUID().uuidString)"))
    var frontmost: PasteApplication? = PasteApplication(processID: 4242, bundleIdentifier: "com.example.editor")
    var postedTexts: [String] = []
    var typedTexts: [String] = []
    var onPost: (() -> Void)?
    var onType: (() -> Void)?
    var onActivate: (() -> Void)?

    lazy var session = PasteSession(pasteboard: board, environment: .init(
        frontmost: { self.frontmost },
        isRunning: { _ in true },
        activate: {
            self.onActivate?()
            self.frontmost = $0
            return true
        },
        wait: { delay in
            if delay >= 0.25 { try await Task.sleep(for: .seconds(0.25)) }
            try Task.checkCancellation()
        },
        pushClipboard: { _, _ in },
        postPaste: { _, canPost in
            guard canPost() else { return false }
            self.onPost?()
            self.postedTexts.append(self.board.string(forType: .string) ?? "")
            return true
        },
        typeText: { _, text, _, canPost in
            self.onType?()
            guard canPost() else { return (.commandNotPosted, nil) }
            self.typedTexts.append(text)
            return (.commandPosted, nil)
        },
        autoLearn: { _, _, _ in nil },
        cancelAutoLearn: { _ in },
        send: { _, _ in },
        reportFailure: { _ in }
    ))

    func paste(
        _ text: String, delivery: RecordingDeliverySession, restore: Bool = false, method: PasteMethod = .standard
    ) async -> CursorPaster.PasteOutcome {
        await session.paste(
            text, destination: delivery.destination, restoreClipboard: restore, restoreDelay: 0.25,
            preferredMethod: method, remotePushCommand: nil, timing: delivery.timing,
            shouldCancel: { delivery.isCancelled }, commitOutput: { delivery.commitOutput() }
        )
    }
}
