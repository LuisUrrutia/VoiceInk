import Darwin
import Foundation
import XCTest
@testable import VoiceInk

final class RemoteClipboardProcessTests: XCTestCase {
    func testTranscriptIsLiteralStandardInputAndNotAnEnvironmentVariable() async throws {
        let transcript = "á字\n$(exit 17) `exit 18` '\" \\ end"

        let result = try await CustomCommandDeliveryRunner.run(
            command: "test -z \"${VOICEINK_TRANSCRIPT+x}\" && /bin/cat", timeout: 3,
            context: .init(transcript: transcript, includesTranscriptEnvironment: false)
        )

        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.stdout, transcript)
    }

    func testNonzeroCommandIsAReportedFailure() async {
        do {
            _ = try await CustomCommandDeliveryRunner.run(
                command: "exit 7", timeout: 3, context: .init(transcript: "text")
            )
            XCTFail("Nonzero commands must fail")
        } catch let error as CustomCommandDeliveryError {
            guard case .nonZeroExit(let status, _) = error else { return XCTFail("Unexpected error: \(error)") }
            XCTAssertEqual(status, 7)
        } catch { XCTFail("Unexpected error: \(error)") }
    }

    func testTimeoutTerminatesACommandAndItsChild() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let pidFile = directory.appendingPathComponent("child.pid")
        let quotedPath = shellQuote(pidFile.path)
        let start = ContinuousClock.now
        do {
            _ = try await CustomCommandDeliveryRunner.run(
                command: "/bin/sleep 30 & print -r -- $! > " + quotedPath + "; wait", timeout: 0.2, context: .init(transcript: "text")
            )
            XCTFail("A stalled push must time out")
        } catch let error as CustomCommandDeliveryError {
            guard case .timeout = error else { return XCTFail("Unexpected error: \(error)") }
            XCTAssertLessThan(start.duration(to: .now), .seconds(6))
        } catch { XCTFail("Unexpected error: \(error)") }
        guard let pidText = try? String(contentsOf: pidFile, encoding: .utf8),
            let pid = Int32(pidText.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return XCTFail("The child process did not start") }
        XCTAssertEqual(kill(pid, 0), -1)
        XCTAssertEqual(errno, ESRCH)
    }

    @MainActor func testCustomDeliveryWaitsForCommandBeforeNormalSessionRetirement() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("delivered.txt")
        let command = "/bin/sleep 0.1; /bin/cat > " + shellQuote(output.path)
        let session = RecordingDeliverySession(destination: .currentApplication)

        await deliver(command: command, session: session)
        session.cancel()

        XCTAssertEqual(try String(contentsOf: output, encoding: .utf8), "custom output")
    }

    @MainActor func testCustomDeliveryCancellationStopsCommandBeforeItsEffects() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let started = directory.appendingPathComponent("started")
        let output = directory.appendingPathComponent("delivered.txt")
        let command = ": > " + shellQuote(started.path) + "; /bin/sleep 30; /bin/cat > " + shellQuote(output.path)
        let session = RecordingDeliverySession(destination: .currentApplication)
        let task = Task { await deliver(command: command, session: session) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !FileManager.default.fileExists(atPath: started.path), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: started.path))
        let start = ContinuousClock.now

        session.cancel()
        await task.value

        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        XCTAssertLessThan(start.duration(to: .now), .seconds(6))
    }

    @MainActor private func deliver(command: String, session: RecordingDeliverySession) async {
        await TranscriptionDelivery().deliver(
            .init(
                transcription: Transcription(text: "custom output", duration: 1, transcriptionStatus: .completed),
                text: "custom output", output: .init(mode: nil, outputMode: .customCommand, customCommand: .init(command: command)),
                responseConfig: nil, responseError: nil, isAssistantFollowUp: false, sendAfterPaste: false,
                deliverySession: session
            ),
            actions: .init(
                setState: { _ in }, dismiss: {}, sendFollowUp: { _, _ in }, showResponse: { _, _ in }, failResponse: { _ in }
            )
        )
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func makeDirectory() throws -> URL {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let directory = root.appendingPathComponent(".tmp/dictation-delivery-tests/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    func testCancellationStopsBlockedStdinWithoutWaitingForTimeout() async throws {
        let task = Task {
            try await CustomCommandDeliveryRunner.run(
                command: "/bin/sleep 30", timeout: 30,
                context: .init(transcript: String(repeating: "x", count: 1_000_000), includesTranscriptEnvironment: false)
            )
        }
        try await Task.sleep(for: .seconds(0.2))
        let start = ContinuousClock.now

        task.cancel()

        do { _ = try await task.value; XCTFail("A canceled push must fail") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertLessThan(start.duration(to: .now), .seconds(6))
    }
}
