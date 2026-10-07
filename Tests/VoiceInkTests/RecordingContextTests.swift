import XCTest
@testable import VoiceInk

@MainActor
final class RecordingContextTests: XCTestCase {
    func testContextCaptureStartsSynchronously() throws {
        var capturedStore: RecordingContextSnapshotStore?
        let capture = RecordingContextCapture { store in
            capturedStore = store
            store.updateClipboardText("  At recording start  ")
            return []
        }
        let recordingID = UUID()

        capture.start(recordingID: recordingID)

        let store = try XCTUnwrap(capturedStore)
        XCTAssertEqual(store.snapshot.clipboardText, "At recording start")
        XCTAssertEqual(capture.take()?.recordingID, recordingID)
    }

    func testCancellationClearsOnlyMatchingRecording() {
        let task = Task<Void, Never> {}
        let capture = RecordingContextCapture { _ in [task] }
        let recordingID = UUID()
        capture.start(recordingID: recordingID)

        capture.clear(recordingID: recordingID)

        XCTAssertTrue(task.isCancelled)
        XCTAssertNil(capture.take())
    }

    func testStaleStartupCleanupPreservesNewRecordingContext() throws {
        var tasks: [Task<Void, Never>] = []
        let capture = RecordingContextCapture { _ in
            let task = Task<Void, Never> {}
            tasks.append(task)
            return [task]
        }
        let oldID = UUID()
        let newID = UUID()
        capture.start(recordingID: oldID)
        capture.start(recordingID: newID)

        capture.clear(recordingID: oldID)

        let session = try XCTUnwrap(capture.take())
        defer { session.cancel() }
        XCTAssertEqual(session.recordingID, newID)
        XCTAssertTrue(tasks[0].isCancelled)
        XCTAssertFalse(tasks[1].isCancelled)
    }

    func testStoppedRecordingRetainsPendingOCRForTranscription() async throws {
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        var task: Task<Void, Never>?
        let capture = RecordingContextCapture { store in
            let pendingOCR = Task { @MainActor in
                for await _ in stream {
                    guard !Task.isCancelled else { return }
                    store.updateScreenText("Window Content:\nCaptured during dictation")
                }
            }
            task = pendingOCR
            return [pendingOCR]
        }
        let recordingID = UUID()
        capture.start(recordingID: recordingID)

        let session = try XCTUnwrap(capture.take())
        defer { session.cancel() }
        capture.clear(recordingID: recordingID)
        continuation.yield(())
        continuation.finish()
        await task?.value

        XCTAssertEqual(session.store.snapshot.screenText, "Window Content:\nCaptured during dictation")
        XCTAssertFalse(try XCTUnwrap(task).isCancelled)
        XCTAssertNil(capture.take())
    }

    func testDetachedPipelineCleanupDoesNotCancelNextRecording() throws {
        var tasks: [Task<Void, Never>] = []
        let capture = RecordingContextCapture { _ in
            let task = Task<Void, Never> {}
            tasks.append(task)
            return [task]
        }
        capture.start(recordingID: UUID())
        let pipelineSession = try XCTUnwrap(capture.take())
        let newID = UUID()
        capture.start(recordingID: newID)

        pipelineSession.cancel()

        XCTAssertTrue(tasks[0].isCancelled)
        XCTAssertFalse(tasks[1].isCancelled)
        capture.clear()
        XCTAssertTrue(tasks[1].isCancelled)
    }

    func testCanceledDetachedSessionDoesNotPublishLateOCR() async throws {
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        var task: Task<Void, Never>?
        let capture = RecordingContextCapture { store in
            let pendingOCR = Task { @MainActor in
                for await _ in stream {
                    guard !Task.isCancelled else { return }
                    store.updateScreenText("Late OCR")
                }
            }
            task = pendingOCR
            return [pendingOCR]
        }
        capture.start(recordingID: UUID())
        let session = try XCTUnwrap(capture.take())

        session.cancel()
        continuation.yield(())
        continuation.finish()
        await task?.value

        XCTAssertTrue(try XCTUnwrap(task).isCancelled)
        XCTAssertNil(session.store.snapshot.screenText)
    }

    func testSnapshotNormalizesEachContextSource() {
        let store = RecordingContextSnapshotStore()

        store.updateClipboardText(" \n ")
        store.updateSelectedText(" Selected text \n")
        store.updateScreenText(" Window text \n")

        XCTAssertNil(store.snapshot.clipboardText)
        XCTAssertEqual(store.snapshot.selectedText, "Selected text")
        XCTAssertEqual(store.snapshot.screenText, "Window text")
    }
}
