import AppKit
import XCTest
@testable import VoiceInk

@MainActor
final class DictationDeliveryTests: XCTestCase {
    func testCaptureFreezesOriginalApplicationBeforeModeOrFocusChanges() {
        let defaults = makeDefaults()
        var focused = Fixture.local
        let first = RecordingDeliverySession.capture(defaults: defaults) { focused }
        focused = Fixture.remote
        let second = RecordingDeliverySession.capture(defaults: defaults) { focused }

        first.cancel()

        XCTAssertEqual(first.destination, .originalApplication(Fixture.local))
        XCTAssertEqual(second.destination, .originalApplication(Fixture.remote))
        XCTAssertFalse(second.isCancelled)
        defaults.set(false, forKey: PasteTargetSettings.key)
        XCTAssertEqual(RecordingDeliverySession.capture(defaults: defaults).destination, .currentApplication)
    }

    func testBackupRoundTripAndLegacyMissingFieldsPreservePreferences() throws {
        let defaults = makeDefaults()
        defaults.set(false, forKey: PasteTargetSettings.key)
        defaults.set("existing command", forKey: PasteTargetSettings.remoteClipboardPushCommandKey)
        let legacy = try JSONDecoder().decode(GeneralBackup.self, from: Data("{}".utf8))

        legacy.restorePastePreferences(in: defaults)

        XCTAssertFalse(PasteTargetSettings.isEnabled(in: defaults))
        XCTAssertEqual(defaults.string(forKey: PasteTargetSettings.remoteClipboardPushCommandKey), "existing command")
        let backup = try JSONDecoder().decode(GeneralBackup.self, from: Data(
            #"{"pinPasteTargetToRecordStart":true,"remoteClipboardPushCommand":"configured command"}"#.utf8
        ))
        let restored = try JSONDecoder().decode(GeneralBackup.self, from: JSONEncoder().encode(backup))
        restored.restorePastePreferences(in: defaults)
        XCTAssertTrue(PasteTargetSettings.isEnabled(in: defaults))
        XCTAssertEqual(defaults.string(forKey: PasteTargetSettings.remoteClipboardPushCommandKey), "configured command")
    }

    func testOriginalTargetActivationAndAutoSendUseSuccessfulPasteProcess() async {
        let fixture = Fixture()
        fixture.frontmost = Fixture.remote

        let result = await fixture.paste(destination: .originalApplication(Fixture.local), sendKey: .enter)

        XCTAssertEqual(result.result, .commandPosted)
        XCTAssertEqual(result.target, Fixture.local)
        XCTAssertEqual(fixture.activations, [Fixture.local])
        XCTAssertEqual(fixture.methods, [.standard])
        XCTAssertEqual(fixture.learnedProcesses, [Fixture.local.processID])
        XCTAssertEqual(fixture.cancelledGenerations, [42])
        XCTAssertEqual(fixture.sentKeys, [.enter])
        XCTAssertTrue(fixture.delays.contains(0.05))
    }

    func testTerminatedMissingAndDeniedTargetsRetainClipboardWithoutPostingOrSending() async {
        for destination in [PasteDestination.originalApplication(nil), .originalApplication(Fixture.local)] {
            let fixture = Fixture()
            fixture.frontmost = Fixture.remote
            fixture.running = false
            let result = await fixture.paste(destination: destination, sendKey: .enter)
            XCTAssertEqual(result.result, .targetUnavailable)
            XCTAssertEqual(fixture.board.string(forType: .string), "transcript")
            XCTAssertTrue(fixture.methods.isEmpty)
            XCTAssertTrue(fixture.sentKeys.isEmpty)
            XCTAssertFalse(fixture.failures.isEmpty)
        }
        let fixture = Fixture()
        fixture.frontmost = Fixture.remote
        fixture.activationAllowed = false
        let result = await fixture.paste(destination: .originalApplication(Fixture.local))
        XCTAssertEqual(result.result, .targetUnavailable)
        XCTAssertTrue(fixture.methods.isEmpty)
    }

    func testActivationTimeoutNeverFallsBackToUnrelatedApplication() async {
        let fixture = Fixture()
        fixture.frontmost = Fixture.remote
        fixture.activationChangesFocus = false

        let result = await fixture.paste(destination: .originalApplication(Fixture.local), sendKey: .enter)

        XCTAssertEqual(result.result, .targetUnavailable)
        XCTAssertEqual(fixture.delays.filter { $0 == 0.03 }.count, 20)
        XCTAssertTrue(fixture.methods.isEmpty)
        XCTAssertTrue(fixture.sentKeys.isEmpty)
        XCTAssertEqual(fixture.board.string(forType: .string), "transcript")
    }

    func testCurrentTargetAndManualPasteChoosePolicyAtDeliveryTime() async {
        let fixture = Fixture()
        let recording = RecordingDeliverySession(destination: .currentApplication)
        fixture.frontmost = Fixture.remote

        let result = await fixture.paste(destination: recording.destination)

        XCTAssertEqual(result.target, Fixture.remote)
        XCTAssertTrue(fixture.activations.isEmpty)
        XCTAssertEqual(fixture.methods, [.appleScript])
        XCTAssertTrue(fixture.delays.contains(0.8))
        let manual = Fixture()
        manual.frontmost = Fixture.remote
        let manualResult = await manual.paste()
        XCTAssertEqual(manualResult.target, Fixture.remote)
        XCTAssertTrue(manual.activations.isEmpty)
    }

    func testLocalPasteRetainsAppleScriptPreferenceAndDoesNotPushClipboard() async {
        let fixture = Fixture()

        _ = await fixture.paste(method: .appleScript, command: "configured")

        XCTAssertEqual(fixture.methods, [.appleScript])
        XCTAssertTrue(fixture.pushedTexts.isEmpty)
        XCTAssertTrue(fixture.delays.contains(0.05))
    }

    func testScreenSharingPushSuccessAndFailureHaveSeparateSettleBudgets() async {
        for failure in [false, true] {
            let fixture = Fixture()
            fixture.frontmost = Fixture.remote
            fixture.pushFails = failure

            let result = await fixture.paste(command: "configured")

            XCTAssertEqual(result.result, .commandPosted)
            XCTAssertEqual(fixture.pushedTexts, ["transcript"])
            XCTAssertEqual(fixture.methods, [.appleScript])
            XCTAssertTrue(fixture.delays.contains(failure ? 0.8 : 0.2))
            XCTAssertEqual(fixture.failures.isEmpty, !failure)
        }
    }

    func testFocusChangeOrCancellationDuringSettleCannotPasteOrSend() async {
        for cancel in [false, true] {
            let fixture = Fixture()
            let recording = RecordingDeliverySession(destination: .originalApplication(Fixture.local))
            fixture.onWait = { delay in
                if delay == 0.05 {
                    if cancel { recording.cancel() }
                    else { fixture.frontmost = Fixture.remote }
                }
            }

            let result = await fixture.paste(destination: recording.destination, sendKey: .enter) { recording.isCancelled }

            XCTAssertFalse(result.result.didPostPasteCommand)
            XCTAssertTrue(fixture.methods.isEmpty)
            XCTAssertTrue(fixture.sentKeys.isEmpty)
        }
    }

    func testAutoSendHonorsCancellationAndFocusChangesAfterPostedPaste() async {
        for cancel in [false, true] {
            let fixture = Fixture()
            let recording = RecordingDeliverySession(destination: .currentApplication)
            fixture.onWait = { delay in
                if delay == 0.15 {
                    if cancel { recording.cancel() }
                    else { fixture.frontmost = Fixture.remote }
                }
            }

            let result = await fixture.paste(sendKey: .enter) { recording.isCancelled }

            XCTAssertEqual(result.result, .commandPosted)
            XCTAssertTrue(fixture.sentKeys.isEmpty)
            XCTAssertTrue(fixture.cancelledGenerations.isEmpty)
        }
    }

    func testFailedPostingRetainsTextAndDoesNotStartAutoLearnOrAutoSend() async {
        let fixture = Fixture()
        fixture.postSucceeds = false

        let result = await fixture.paste(sendKey: .enter)

        XCTAssertEqual(result.result, .commandNotPosted)
        XCTAssertTrue(fixture.learnedProcesses.isEmpty)
        XCTAssertTrue(fixture.sentKeys.isEmpty)
        XCTAssertEqual(fixture.board.string(forType: .string), "transcript")
    }

    func testClipboardRestoresOriginalTypesAfterOverlappingCompletedPastes() async throws {
        let fixture = Fixture()
        let data = Data([1, 2, 3])
        fixture.board.clearContents()
        fixture.board.setData(data, forType: .pdf)
        fixture.board.setString("original", forType: .string)

        _ = await fixture.paste(restore: true)
        _ = await fixture.paste(text: "second", restore: true)
        try await Task.sleep(for: .seconds(0.4))

        XCTAssertEqual(fixture.board.string(forType: .string), "original")
        XCTAssertEqual(fixture.board.data(forType: .pdf), data)
    }

    func testExternalSameTextClipboardChangeIsNeverRestoredOver() async throws {
        let fixture = Fixture()
        fixture.board.setString("original", forType: .string)

        _ = await fixture.paste(restore: true)
        ClipboardManager.setClipboard("transcript", on: fixture.board)
        try await Task.sleep(for: .seconds(0.4))

        XCTAssertEqual(fixture.board.string(forType: .string), "transcript")
    }

    func testNewPasteSupersedesOlderPendingPasteWithoutPostingOlderText() async {
        let fixture = Fixture()
        let entered = expectation(description: "old paste waiting")
        var release: CheckedContinuation<Void, Never>?
        fixture.onAsyncWait = { delay in
            if delay == 0.05 && fixture.board.string(forType: .string) == "old" {
                entered.fulfill()
                await withCheckedContinuation { release = $0 }
            }
        }
        let old = Task { await fixture.paste(text: "old") }
        await fulfillment(of: [entered], timeout: 2)

        let newer = await fixture.paste(text: "new")
        release?.resume()
        let older = await old.value

        XCTAssertEqual(newer.result, .commandPosted)
        XCTAssertEqual(older.result, .cancelled)
        XCTAssertEqual(fixture.postedTexts, ["new"])
        XCTAssertEqual(fixture.board.string(forType: .string), "new")
    }

    func testSupersededRemotePushStopsBeforeNewPushAndPaste() async {
        let fixture = Fixture()
        fixture.frontmost = Fixture.remote
        let entered = expectation(description: "old remote push started")
        var events: [String] = []
        fixture.onPush = { text in
            if text == "old" {
                entered.fulfill()
                do { try await Task.sleep(for: .seconds(30)) }
                catch {
                    events.append("old stopped")
                    throw error
                }
            } else { events.append("new pushed") }
        }
        let old = Task { await fixture.paste(text: "old", command: "configured") }
        await fulfillment(of: [entered], timeout: 2)

        let newer = await fixture.paste(text: "new", command: "configured")
        let older = await old.value

        XCTAssertEqual(events, ["old stopped", "new pushed"])
        XCTAssertEqual(older.result, .cancelled)
        XCTAssertEqual(newer.result, .commandPosted)
        XCTAssertEqual(fixture.postedTexts, ["new"])
    }

    func testCancellationDuringRemotePushCannotPostFallbackOrSend() async {
        let fixture = Fixture()
        fixture.frontmost = Fixture.remote
        let entered = expectation(description: "remote push started")
        fixture.onPush = { _ in
            entered.fulfill()
            try await Task.sleep(for: .seconds(30))
        }
        let recording = RecordingDeliverySession(destination: .currentApplication)
        let task = Task { await fixture.paste(command: "configured", sendKey: .enter) { recording.isCancelled } }
        recording.own(task)
        await fulfillment(of: [entered], timeout: 2)

        recording.cancel()
        let result = await task.value

        XCTAssertEqual(result.result, .cancelled)
        XCTAssertTrue(fixture.methods.isEmpty)
        XCTAssertTrue(fixture.sentKeys.isEmpty)
    }

    private func makeDefaults() -> UserDefaults {
        let name = "DictationDeliveryTests.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    @MainActor private final class Fixture {
        static let local = PasteApplication(processID: 100, bundleIdentifier: "test.editor")
        static let remote = PasteApplication(processID: 200, bundleIdentifier: "com.apple.ScreenSharing")
        let board = NSPasteboard(name: NSPasteboard.Name("DictationDeliveryTests.\(UUID())"))
        var frontmost: PasteApplication? = local
        var running = true
        var activationAllowed = true
        var activationChangesFocus = true
        var pushFails = false
        var postSucceeds = true
        var activations: [PasteApplication] = []
        var methods: [PasteMethod] = []
        var pushedTexts: [String] = []
        var postedTexts: [String] = []
        var delays: [TimeInterval] = []
        var learnedProcesses: [pid_t] = []
        var cancelledGenerations: [UInt64] = []
        var sentKeys: [FinishAndSendKey] = []
        var failures: [String] = []
        var onPush: ((String) async throws -> Void)?
        var onWait: ((TimeInterval) -> Void)?
        var onAsyncWait: ((TimeInterval) async -> Void)?
        lazy var session = PasteSession(pasteboard: board, environment: .init(
            frontmost: { self.frontmost },
            isRunning: { _ in self.running },
            activate: {
                self.activations.append($0)
                if self.activationAllowed && self.activationChangesFocus { self.frontmost = $0 }
                return self.activationAllowed
            },
            wait: {
                self.delays.append($0)
                self.onWait?($0)
                await self.onAsyncWait?($0)
                if $0 >= 0.25 { try await Task.sleep(for: .seconds(0.25)) }
                try Task.checkCancellation()
            },
            pushClipboard: { _, text in
                self.pushedTexts.append(text)
                try await self.onPush?(text)
                if self.pushFails { throw CustomCommandDeliveryError.timeout(seconds: 3) }
            },
            postPaste: { method, canPost in
                guard canPost() else { return false }
                self.methods.append(method)
                self.postedTexts.append(self.board.string(forType: .string) ?? "")
                return self.postSucceeds
            },
            autoLearn: { _, process, _ in self.learnedProcesses.append(process); return 42 },
            cancelAutoLearn: { self.cancelledGenerations.append($0) },
            send: { key, _ in self.sentKeys.append(key) },
            reportFailure: { self.failures.append($0) }
        ))

        func paste(
            text: String = "transcript", destination: PasteDestination = .currentApplication,
            restore: Bool = false, method: PasteMethod = .standard, command: String? = nil,
            sendKey: FinishAndSendKey = .none, shouldCancel: @escaping () -> Bool = { false }
        ) async -> CursorPaster.PasteOutcome {
            await session.paste(
                text, destination: destination, restoreClipboard: restore, restoreDelay: 0.25,
                preferredMethod: method, remotePushCommand: command, sendKey: sendKey, shouldCancel: shouldCancel
            )
        }
    }
}
