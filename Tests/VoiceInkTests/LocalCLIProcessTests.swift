import Darwin
import Foundation
import XCTest
@testable import VoiceInk

final class LocalCLIProcessTests: XCTestCase {
    func testLargeSimultaneousOutputAndInputAreComplete() async throws {
        let input = Data(repeating: 105, count: 1_000_000)
        let command = fixture("""
            for (1..128) { print STDOUT 'o' x 8192; print STDERR 'e' x 8192; }
            local $/; my $input = <STDIN>; print STDOUT $input;
            """)

        let result = try await run(command, input: input)

        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.stdout, Data(repeating: 111, count: 128 * 8192) + input)
        XCTAssertEqual(result.stderr, Data(repeating: 101, count: 128 * 8192))
    }

    func testEarlyExitWhileWritingLargeInputDoesNotCrashOrWait() async throws {
        let result = try await run(fixture("print 'early'; exit 7;"), input: Data(repeating: 120, count: 1_000_000))

        XCTAssertEqual(result.status, 7)
        XCTAssertEqual(result.stdout, Data("early".utf8))
    }

    func testIgnoredLargeInputStillTimesOut() async throws {
        let start = ContinuousClock.now

        do {
            _ = try await run(fixture("$SIG{TERM} = 'IGNORE'; sleep 8;"), input: Data(repeating: 120, count: 1_000_000), timeout: 0.2)
            XCTFail("Ignored input must remain inside the timeout")
        } catch let error as LocalCLIError {
            guard case .timeout(let seconds) = error else { return XCTFail("Unexpected error: \(error)") }
            XCTAssertEqual(seconds, 0.2)
        }

        XCTAssertLessThan(start.duration(to: .now), .seconds(3))
    }

    func testCancellationStopsIgnoredInputAndAllowsNextCall() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let started = directory.appendingPathComponent("started")
        let task = Task {
            try await run(
                fixture("open my $file, '>', $ENV{MARKER} or die; close $file; $SIG{TERM} = 'IGNORE'; sleep 8;"),
                input: Data(repeating: 120, count: 1_000_000), environment: ["MARKER": started.path]
            )
        }
        try await waitForFile(started)
        let start = ContinuousClock.now

        task.cancel()
        await assertCanceled(task)
        let result = try await run("printf 'next'")

        XCTAssertEqual(result.stdout, Data("next".utf8))
        XCTAssertLessThan(start.duration(to: .now), .seconds(3))
    }

    func testCancellationBeforeStartupDoesNotLaunch() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = directory.appendingPathComponent("started")
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await run(": > " + quote(marker.path))
        }

        await assertCanceled(task)

        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testCancellationDuringEnvironmentPreparationDoesNotLaunch() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let preparing = directory.appendingPathComponent("preparing")
        let launched = directory.appendingPathComponent("launched")
        let release = DispatchSemaphore(value: 0)
        let task = Task {
            try await LocalCLIProcessRunner.run(command: ": > " + quote(launched.path), standardInput: nil, timeout: 3) {
                FileManager.default.createFile(atPath: preparing.path, contents: Data())
                _ = release.wait(timeout: .now() + 2)
                return ProcessInfo.processInfo.environment
            }
        }
        try await waitForFile(preparing)

        task.cancel()
        release.signal()
        await assertCanceled(task)

        XCTAssertFalse(FileManager.default.fileExists(atPath: launched.path))
    }

    func testTimeoutIncludesEnvironmentPreparation() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = directory.appendingPathComponent("launched")

        do {
            _ = try await LocalCLIProcessRunner.run(command: ": > " + quote(marker.path), standardInput: nil, timeout: 0.01) {
                usleep(30_000)
                return ProcessInfo.processInfo.environment
            }
            XCTFail("Preparation must not reset the deadline")
        } catch let error as LocalCLIError {
            guard case .timeout = error else { return XCTFail("Unexpected error: \(error)") }
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testTimeoutKillsResistantDescendantsAndPreservesUnrelatedProcess() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let pids = directory.appendingPathComponent("pids")
        let unrelated = Process()
        unrelated.executableURL = URL(fileURLWithPath: "/bin/sleep")
        unrelated.arguments = ["8"]
        try unrelated.run()
        defer { unrelated.terminate(); unrelated.waitUntilExit() }
        let command = fixture("""
            $SIG{TERM} = 'IGNORE';
            open my $file, '>>', $ENV{MARKER} or die; print $file "$$\\n"; close $file;
            if (fork() == 0) {
                alarm 8;
                open my $file, '>>', $ENV{MARKER} or die; print $file "$$\\n"; close $file;
                if (fork() == 0) {
                    alarm 8;
                    open my $file, '>>', $ENV{MARKER} or die; print $file "$$\\n"; close $file;
                }
            }
            sleep 8;
            """)

        do {
            _ = try await run(command, timeout: 0.5, environment: ["MARKER": pids.path])
            XCTFail("Resistant descendants must time out")
        } catch let error as LocalCLIError {
            guard case .timeout = error else { return XCTFail("Unexpected error: \(error)") }
        }

        let recordedPIDs = try readPIDs(pids)
        XCTAssertEqual(recordedPIDs.count, 3)
        try await assertProcessesGone(recordedPIDs)
        XCTAssertTrue(unrelated.isRunning)
    }

    func testExitedLeaderWithInheritedPipesCannotHideDescendant() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let pids = directory.appendingPathComponent("pids")
        let command = fixture("""
            if (fork() == 0) {
                alarm 8; $SIG{TERM} = 'IGNORE';
                open my $file, '>', $ENV{MARKER} or die; print $file "$$\\n"; close $file;
                sleep 8; exit;
            }
            print 'leader exited'; exit;
            """)

        do {
            _ = try await run(command, timeout: 0.3, environment: ["MARKER": pids.path])
            XCTFail("A child holding output open must remain inside the deadline")
        } catch let error as LocalCLIError {
            guard case .timeout = error else { return XCTFail("Unexpected error: \(error)") }
        }

        try await assertProcessesGone(readPIDs(pids))
    }

    func testSuccessRetiresDescendantsThatClosedOutput() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let pids = directory.appendingPathComponent("pids")
        let command = fixture("""
            if (fork() == 0) {
                alarm 8;
                open my $file, '>', $ENV{MARKER} or die; print $file "$$\\n"; close $file;
                close STDIN; close STDOUT; close STDERR; sleep 8; exit;
            }
            while (!-e $ENV{MARKER}) { select undef, undef, undef, 0.01; }
            print 'done'; exit;
            """)

        let result = try await run(command, environment: ["MARKER": pids.path])

        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.stdout, Data("done".utf8))
        try await assertProcessesGone(readPIDs(pids))
    }

    func testConcurrentCallsKeepInputAndOutputSeparate() async throws {
        let outputs = try await withThrowingTaskGroup(of: Data.self) { group in
            for index in 0..<8 {
                group.addTask {
                    let result = try await self.run("/bin/cat", input: Data("call-\(index)".utf8))
                    XCTAssertEqual(result.status, 0)
                    return result.stdout
                }
            }
            var outputs = Set<Data>()
            for try await output in group { outputs.insert(output) }
            return outputs
        }

        XCTAssertEqual(outputs, Set((0..<8).map { Data("call-\($0)".utf8) }))
    }

    func testRepeatedLaunchCancelExitRacesCompleteOnce() async throws {
        for index in 0..<20 {
            let task = Task { try await run(fixture("print 'done';")) }
            if index.isMultiple(of: 2) { task.cancel() }

            if index.isMultiple(of: 2) {
                await assertCanceled(task)
            } else {
                let result = try await task.value
                XCTAssertEqual(result.status, 0)
                XCTAssertEqual(result.stdout, Data("done".utf8))
            }
        }
    }

    func testLaunchFailureHasExistingErrorType() async {
        do {
            _ = try await LocalCLIProcessRunner.run(
                command: "printf result", standardInput: nil, timeout: 1, executable: "/voiceink-nonexistent-shell"
            ) { ProcessInfo.processInfo.environment }
            XCTFail("A missing executable must fail to launch")
        } catch let error as LocalCLIError {
            guard case .executionFailed = error else { return XCTFail("Unexpected error: \(error)") }
        } catch { XCTFail("Unexpected error: \(error)") }
    }

    func testCancellationAndTimeoutRaceRetiresEveryInvocation() async throws {
        for _ in 0..<8 {
            let task = Task { try await run(fixture("sleep 8;"), timeout: 0.03) }
            try await Task.sleep(for: .milliseconds(30))

            task.cancel()

            do { _ = try await task.value; XCTFail("The invocation must not succeed") }
            catch is CancellationError {}
            catch let error as LocalCLIError {
                guard case .timeout = error else { return XCTFail("Unexpected error: \(error)") }
            }
        }
    }

    func testServicePreservesLiteralPromptEnvironmentAndTrimsOnlyEdges() async throws {
        let system = "system ' \\ \" $() 字"
        let user = "user\nsecond line"
        let full = LocalCLIService.makeFullPrompt(systemPrompt: system, userPrompt: user)
        let result = try await LocalCLIService.executeCommand(
            commandTemplate: "printf '  %s\\n%s\\n%s\\n%s  ' \"$VOICEINK_SYSTEM_PROMPT\" \"$VOICEINK_USER_PROMPT\" \"$VOICEINK_FULL_PROMPT\" \"$VOICEINK_TEST_INHERITED\"",
            systemPrompt: system, userPrompt: user, fullPrompt: full, timeout: 3,
            inheritedEnvironment: ProcessInfo.processInfo.environment.merging(["VOICEINK_TEST_INHERITED": "inherited"]) { _, new in new }
        )

        XCTAssertEqual(result, "\(system)\n\(user)\n\(full)\ninherited")
    }

    func testServiceSendsFullPromptAsLiteralStdin() async throws {
        let full = LocalCLIService.makeFullPrompt(systemPrompt: "literal $()", userPrompt: "字\ntext")

        let result = try await service("/bin/cat", fullPrompt: full)

        XCTAssertEqual(result, full)
    }

    func testBuiltinArgumentTemplatesReceiveNoStdin() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try "codex() { /bin/cat; printf 'argument:%s' \"${@[-1]}\"; }\nclaude() { /bin/cat; printf 'argument:%s' \"${@[-1]}\"; }\n"
            .write(to: directory.appendingPathComponent(".zshenv"), atomically: true, encoding: .utf8)
        let environment = ProcessInfo.processInfo.environment.merging(["ZDOTDIR": directory.path]) { _, new in new }

        for template in [LocalCLITemplate.codex, .claude] {
            let result = try await LocalCLIService.executeCommand(
                commandTemplate: template.commandTemplate, systemPrompt: "system", userPrompt: "user",
                fullPrompt: "synthetic full prompt", timeout: 3, inheritedEnvironment: environment
            )

            XCTAssertEqual(result, "argument:synthetic full prompt")
        }
    }

    func testServiceEmptyCommandOutputAndExitErrorsRemainDistinct() async {
        for (command, expected) in [(" ", "configuration"), ("printf ' \\n'", "empty"), ("voiceink_nonexistent_test_command", "missing"), ("printf ' failure \\n' >&2; exit 7", "nonzero")] {
            do {
                _ = try await service(command)
                XCTFail("\(expected) must fail")
            } catch let error as LocalCLIError {
                switch (expected, error) {
                case ("configuration", .commandNotConfigured), ("empty", .emptyOutput), ("missing", .commandNotFound): break
                case ("nonzero", .nonZeroExit(let status, let stderr)):
                    XCTAssertEqual(status, 7)
                    XCTAssertEqual(stderr, "failure")
                default: XCTFail("Unexpected error: \(error)")
                }
            } catch { XCTFail("Unexpected error: \(error)") }
        }
    }

    private func run(
        _ command: String, input: Data? = nil, timeout: TimeInterval = 3, environment: [String: String] = [:]
    ) async throws -> LocalCLIProcessRunner.Result {
        try await LocalCLIProcessRunner.run(command: command, standardInput: input, timeout: timeout) {
            ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        }
    }

    private func service(_ command: String, fullPrompt: String = "synthetic prompt") async throws -> String {
        try await LocalCLIService.executeCommand(
            commandTemplate: command, systemPrompt: "system", userPrompt: "user", fullPrompt: fullPrompt, timeout: 3
        )
    }

    private func fixture(_ program: String) -> String {
        "exec /usr/bin/perl -e " + quote("alarm 8; $| = 1; " + program)
    }

    private func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func makeDirectory() throws -> URL {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let directory = root.appendingPathComponent(".tmp/local-cli-process-tests/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func waitForFile(_ file: URL) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !FileManager.default.fileExists(atPath: file.path), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    private func readPIDs(_ file: URL) throws -> [pid_t] {
        try String(contentsOf: file, encoding: .utf8).split(whereSeparator: \.isNewline).map { try XCTUnwrap(Int32($0)) }
    }

    private func assertProcessesGone(_ pids: [pid_t]) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while pids.contains(where: { kill($0, 0) == 0 }), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        for pid in pids {
            XCTAssertEqual(kill(pid, 0), -1, "Process \(pid) is still alive")
            XCTAssertEqual(errno, ESRCH)
        }
    }

    private func assertCanceled(_ task: Task<LocalCLIProcessRunner.Result, Error>) async {
        do { _ = try await task.value; XCTFail("Canceled execution must fail") }
        catch { XCTAssertTrue(error is CancellationError, "Unexpected error: \(error)") }
    }
}
