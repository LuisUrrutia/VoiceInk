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

    func testCommandsStartWithDefaultSignalHandlingWhenTheAppIgnoresSIGPIPE() async throws {
        let previous = signal(SIGPIPE, SIG_IGN)
        defer { signal(SIGPIPE, previous) }

        let result = try await CustomCommandDeliveryRunner.run(
            command: "/usr/bin/yes | /usr/bin/head -1 > /dev/null; print -r -- ${pipestatus[1]}", timeout: 5,
            context: .init(transcript: "text")
        )

        XCTAssertEqual(result.stdout, "\(128 + SIGPIPE)\n")
    }

    func testExitStatusKeepsOnlyTheLowByteLikeProcess() async throws {
        let result = try await CustomCommandDeliveryRunner.run(
            command: "exec /usr/bin/perl -e 'exit 256'", timeout: 5, context: .init(transcript: "text")
        )

        XCTAssertEqual(result.status, 0)
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

    func testTerminationReachesChildrenForkedAfterTheDescendantSnapshot() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        // Each TERM forks a child, so every child starts after termination took its descendant snapshot.
        let command = "cd " + shellQuote(directory.path)
            + " && trap '/bin/sleep 30 & print -r -- $! >> children.pid' TERM; : > ready;"
            + " zmodload zsh/zselect; while :; do zselect -t 10; done"
        let run = Task {
            try await CustomCommandDeliveryRunner.run(command: command, timeout: 30, context: .init(transcript: "text"))
        }
        let ready = directory.appendingPathComponent("ready")
        for _ in 0..<1_000 where !FileManager.default.fileExists(atPath: ready.path) {
            try await Task.sleep(for: .milliseconds(10))
        }

        run.cancel()

        do {
            _ = try await run.value
            XCTFail("A canceled push must not finish")
        } catch is CancellationError {
        } catch { XCTFail("Unexpected error: \(error)") }
        let pidText = (try? String(contentsOf: directory.appendingPathComponent("children.pid"), encoding: .utf8)) ?? ""
        let children = pidText.split(whereSeparator: \.isNewline).compactMap { Int32($0) }
        XCTAssertFalse(children.isEmpty, "Termination must signal the shell")
        for child in children {
            XCTAssertEqual(kill(child, 0), -1, "child \(child) survived")
            XCTAssertEqual(errno, ESRCH)
            if kill(child, 0) == 0 { kill(child, SIGKILL) }
        }
    }

    func testTerminationKillsAResistantChildAfterTheShellExitsAndSparesOtherProcesses() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let unrelated = Process()
        unrelated.executableURL = URL(fileURLWithPath: "/bin/sleep")
        unrelated.arguments = ["30"]
        try unrelated.run()
        defer { unrelated.terminate() }
        // The shell exits on TERM; its child ignores TERM, so only the group KILL after the shell's exit stops it.
        let command = "cd " + shellQuote(directory.path)
            + " && (trap '' TERM; : > child-ignores-term; /bin/sleep 30) & print -r -- $! > child.pid;"
            + " zmodload zsh/zselect; until [[ -e child-ignores-term ]]; do zselect -t 1; done; : > ready; wait"
        let run = Task {
            try await CustomCommandDeliveryRunner.run(command: command, timeout: 30, context: .init(transcript: "text"))
        }
        let ready = directory.appendingPathComponent("ready")
        for _ in 0..<1_000 where !FileManager.default.fileExists(atPath: ready.path) {
            try await Task.sleep(for: .milliseconds(10))
        }

        run.cancel()

        do {
            _ = try await run.value
            XCTFail("A canceled push must not finish")
        } catch is CancellationError {
        } catch { XCTFail("Unexpected error: \(error)") }
        let pidText = try String(contentsOf: directory.appendingPathComponent("child.pid"), encoding: .utf8)
        let child = try XCTUnwrap(Int32(pidText.trimmingCharacters(in: .whitespacesAndNewlines)))
        XCTAssertEqual(kill(child, 0), -1, "the TERM-resistant child survived")
        XCTAssertEqual(errno, ESRCH)
        if kill(child, 0) == 0 { kill(child, SIGKILL) }
        XCTAssertTrue(unrelated.isRunning, "a process outside the command's group was signaled")
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
                text: "custom output", output: .init(
                    mode: nil, outputMode: .customCommand, autoSendKey: .none, customCommand: .init(command: command)
                ),
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
