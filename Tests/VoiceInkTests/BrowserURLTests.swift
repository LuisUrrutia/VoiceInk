import Darwin
import Foundation
import XCTest
@testable import VoiceInk

final class BrowserURLTests: XCTestCase {
    func testImmediateExitAndWhitespaceKeepExactURL() async throws {
        let output = try await run("printf '  https://fixture.invalid/path\\n  '")

        XCTAssertEqual(try BrowserURLService.url(from: output), "https://fixture.invalid/path")
    }

    func testDrainsOutputLargerThanPipeCapacityBeforeCompletion() async throws {
        let output = try await run("exec /usr/bin/head -c 262144 /dev/zero")

        XCTAssertEqual(output, Data(repeating: 0, count: 262_144))
    }

    func testEmptyInvalidAndErrorOutputKeepFailureBehavior() {
        for data in [Data(), Data(" \n".utf8)] {
            XCTAssertThrowsError(try BrowserURLService.url(from: data)) {
                guard case BrowserURLError.noActiveTab = $0 else { return XCTFail("Unexpected error") }
            }
        }
        for data in [Data([0xFF]), Data("execution error: denied".utf8)] {
            XCTAssertThrowsError(try BrowserURLService.url(from: data)) {
                guard case BrowserURLError.executionFailed = $0 else { return XCTFail("Unexpected error") }
            }
        }
    }

    func testStandardErrorIsDrainedAndNonzeroExitFails() async {
        await assertFailure(.executionFailed) {
            try await self.run("/usr/bin/head -c 262144 /dev/zero >&2; exit 7")
        }
    }

    func testLaunchFailureResumesWithoutWaitingForTimeout() async {
        await assertFailure(.executionFailed) {
            try await BrowserScriptProcess(
                executableURL: URL(fileURLWithPath: "/nonexistent/voiceink-fixture"), arguments: []
            ).run(timeout: 2)
        }
    }

    func testTimeoutEscalatesWhenProcessIgnoresTermination() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let pidFile = directory.appendingPathComponent("process.pid")
        let script = "echo $$ > '" + pidFile.path + "'; trap '' TERM; while :; do :; done"

        await assertFailure(.executionTimedOut) { try await self.run(script, timeout: 0.1) }

        let pid = try XCTUnwrap(Int32(String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        XCTAssertEqual(kill(pid, 0), -1)
        XCTAssertEqual(errno, ESRCH)
    }

    func testInheritedWriterCannotHoldCompletionOpenForever() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let pidFile = directory.appendingPathComponent("child.pid")
        defer {
            if let text = try? String(contentsOf: pidFile, encoding: .utf8),
                let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                kill(pid, SIGKILL)
            }
        }

        await assertFailure(.executionTimedOut) {
            try await self.run("/bin/sleep 30 & echo $! > '" + pidFile.path + "'; printf fixture; exit 0", timeout: 0.1)
        }
    }

    func testCancellationDuringExecutionStopsOwnedProcess() async throws {
        let task = Task { try await run("exec /bin/sleep 30", timeout: 30) }
        try await Task.sleep(for: .milliseconds(50))

        task.cancel()

        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    func testAlreadyCanceledTaskDoesNotLaunch() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = directory.appendingPathComponent("launched")
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await run("touch '" + marker.path + "'")
        }

        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testOutputLimitFailsWithoutUnboundedAccumulation() async {
        await assertFailure(.executionFailed) {
            try await self.run("exec /usr/bin/head -c 2097152 /dev/zero")
        }
    }

    private func run(_ command: String, timeout: TimeInterval = 2) async throws -> Data {
        try await BrowserScriptProcess(
            executableURL: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", command]
        ).run(timeout: timeout)
    }

    private func assertFailure(_ expected: BrowserURLError, operation: () async throws -> Data) async {
        do { _ = try await operation(); XCTFail("Expected failure") }
        catch let error as BrowserURLError { XCTAssertEqual(String(describing: error), String(describing: expected)) }
        catch { XCTFail("Unexpected error: \(error)") }
    }

    private func makeDirectory() throws -> URL {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let directory = root.appendingPathComponent(".tmp/browser-url-tests/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

@MainActor
final class BrowserModeResolutionTests: XCTestCase {
    func testNoRulesAndDisabledRulesSkipURLLookup() async {
        let fixture = Fixture()
        let disabled = ModeConfig(name: "Disabled", urlConfigs: [.init(url: "fixture.invalid")], isAIEnhancementEnabled: false, isEnabled: false)
        for configurations in [[fixture.fallback], [fixture.fallback, disabled]] {
            fixture.configurations = configurations

            await fixture.service.beginApplyingConfiguration().value

            XCTAssertEqual(fixture.lookups, 0)
            XCTAssertEqual(fixture.applied.last?.id, fixture.fallback.id)
        }
    }

    func testExplicitModeAndNonBrowserSkipURLLookup() async {
        let fixture = Fixture()
        fixture.configurations.append(fixture.website)

        await fixture.service.beginApplyingConfiguration(modeId: fixture.website.id).value
        fixture.application = .init(bundleIdentifier: "fixture.editor")
        await fixture.service.beginApplyingConfiguration().value

        XCTAssertEqual(fixture.lookups, 0)
        XCTAssertEqual(fixture.applied.map(\.id), [fixture.website.id, fixture.fallback.id])
    }

    func testEverySupportedBrowserUsesItsScriptAndURLMode() async {
        for browser in BrowserType.allCases {
            let fixture = Fixture()
            fixture.application = .init(bundleIdentifier: browser.bundleIdentifier)
            fixture.configurations.append(fixture.website)

            await fixture.service.beginApplyingConfiguration().value

            XCTAssertEqual(fixture.lookups, 1)
            XCTAssertEqual(fixture.browser?.scriptName, browser.scriptName)
            XCTAssertEqual(fixture.applied.map(\.id), [fixture.fallback.id, fixture.website.id])
        }
    }

    func testGroupedURLRulesRetainMatchingSemantics() async {
        let fixture = Fixture()
        var grouped = fixture.website
        grouped.urlConfigs = nil
        grouped.triggerGroups = [.init(name: "Group", urlConfigs: [.init(url: " HTTPS://WWW.FIXTURE.INVALID ")])]
        fixture.configurations.append(grouped)

        await fixture.service.beginApplyingConfiguration().value

        XCTAssertEqual(fixture.lookups, 1)
        XCTAssertEqual(fixture.applied.last?.id, grouped.id)
    }

    func testBlankURLRulesKeepExistingNonmatchingSemanticsWithoutLookup() async {
        let fixture = Fixture()
        var blank = fixture.website
        blank.urlConfigs = [.init(url: ""), .init(url: " \n"), .init(url: "https://www.")]
        fixture.configurations.append(blank)
        let manager = ModeManager.shared
        let original = manager.configurations
        defer { manager.configurations = original }
        manager.configurations = fixture.configurations

        XCTAssertNil(manager.getConfigurationForURL(fixture.result))
        await fixture.service.beginApplyingConfiguration().value

        XCTAssertEqual(fixture.lookups, 0)
        XCTAssertEqual(fixture.applied.last?.id, fixture.fallback.id)
    }

    func testURLFailureAndNoMatchKeepAppFallback() async {
        let fixture = Fixture()
        var appMode = fixture.fallback
        appMode.isDefault = false
        appMode.appConfigs = [.init(bundleIdentifier: BrowserType.safari.bundleIdentifier, appName: "Safari")]
        fixture.configurations = [appMode, fixture.fallback, fixture.website]
        fixture.result = "https://different.invalid"

        await fixture.service.beginApplyingConfiguration().value
        fixture.error = BrowserURLError.noActiveTab
        await fixture.service.beginApplyingConfiguration().value

        XCTAssertEqual(fixture.applied.map(\.id), [appMode.id, appMode.id])
    }

    func testChangedRuleTextWithSameIDRejectsPendingResult() async {
        let fixture = Fixture()
        fixture.configurations.append(fixture.website)
        let task = await fixture.startPending()

        fixture.configurations[1].urlConfigs?[0].url = "different.invalid"
        fixture.complete()
        await task.value

        XCTAssertEqual(fixture.applied.map(\.id), [fixture.fallback.id])
    }

    func testDisabledModeRejectsPendingResult() async {
        let fixture = Fixture()
        fixture.configurations.append(fixture.website)
        let task = await fixture.startPending()

        fixture.configurations[1].isEnabled = false
        fixture.complete()
        await task.value

        XCTAssertEqual(fixture.applied.map(\.id), [fixture.fallback.id])
    }

    func testNewApplicationSelectionSupersedesPendingBrowserResult() async {
        let fixture = Fixture()
        fixture.configurations.append(fixture.website)
        let task = await fixture.startPending()

        fixture.application = .init(bundleIdentifier: "fixture.editor")
        await fixture.service.beginApplyingConfiguration().value
        fixture.complete()
        await task.value

        XCTAssertEqual(fixture.applied.map(\.id), [fixture.fallback.id, fixture.fallback.id])
    }

    func testFocusChangeKeepsOriginalBrowserAndLatestModelSettings() async {
        let fixture = Fixture()
        fixture.configurations.append(fixture.website)
        let task = await fixture.startPending()

        fixture.application = .init(bundleIdentifier: "fixture.recorder")
        fixture.configurations[1].selectedTranscriptionModelName = "final-model"
        fixture.complete()
        await task.value

        XCTAssertEqual(fixture.applied.last?.id, fixture.website.id)
        XCTAssertEqual(fixture.applied.last?.selectedTranscriptionModelName, "final-model")
    }

    func testCancellationAndRetiredRecordingRejectPendingResults() async {
        for cancelTask in [true, false] {
            let fixture = Fixture()
            fixture.configurations.append(fixture.website)
            let task = await fixture.startPending()

            if cancelTask { task.cancel() } else { fixture.ownsRecording = false }
            fixture.complete()
            await task.value

            XCTAssertEqual(fixture.applied.map(\.id), [fixture.fallback.id])
        }
    }

    func testStoppedRecordingCanRetainOwnershipWhileURLIsPending() async {
        let fixture = Fixture()
        fixture.configurations.append(fixture.website)
        let task = await fixture.startPending()

        fixture.pipelineOwnsRecording = true
        fixture.ownsRecording = false
        fixture.complete()
        await task.value

        XCTAssertEqual(fixture.applied.last?.id, fixture.website.id)
    }

    @MainActor
    private final class Fixture {
        let fallback = ModeConfig(name: "Default", isAIEnhancementEnabled: false, isDefault: true)
        let website = ModeConfig(name: "Website", urlConfigs: [.init(url: "fixture.invalid")], isAIEnhancementEnabled: false)
        var configurations: [ModeConfig] = []
        var application: ActiveWindowService.Application? = .init(bundleIdentifier: BrowserType.safari.bundleIdentifier)
        var applied: [ModeConfig] = []
        var lookups = 0
        var browser: BrowserType?
        var result = "https://fixture.invalid/path"
        var error: Error?
        var ownsRecording = true
        var pipelineOwnsRecording = false
        var deferLookup = false
        var completion: CheckedContinuation<String, Error>?
        let started = XCTestExpectation(description: "URL lookup started")

        lazy var service = ActiveWindowService(
            frontmostApplication: { [weak self] in self?.application },
            configurations: { [weak self] in self?.configurations ?? [] },
            apply: { [weak self] in self?.applied.append($0) }, currentURL: { [weak self] browser in
                guard let self else { throw CancellationError() }
                self.lookups += 1
                self.browser = browser
                if let error = self.error { throw error }
                if self.deferLookup {
                    return try await withCheckedThrowingContinuation {
                        self.completion = $0
                        self.started.fulfill()
                    }
                }
                return self.result
            }
        )

        init() { configurations = [fallback] }

        func startPending() async -> Task<Void, Never> {
            deferLookup = true
            let task = service.beginApplyingConfiguration { self.ownsRecording || self.pipelineOwnsRecording }
            _ = await XCTWaiter.fulfillment(of: [started], timeout: 2)
            return task
        }

        func complete() {
            completion?.resume(returning: result)
            completion = nil
        }
    }
}
