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
        XCTAssertTrue(fixture.delays.contains(0.02))
    }

    func testPasteTimingMarksOnlyAfterFocusSettleAndSuccessfulPosting() async {
        let fixture = Fixture()
        fixture.frontmost = Fixture.remote
        let timing = RecordingTimingTrace()
        fixture.onWait = { delay in
            if delay == 0.02 {
                XCTAssertEqual(timing.snapshot.first { $0.phase == .destinationReady }?.outcome, .completed)
                XCTAssertNil(timing.snapshot.first { $0.phase == .clipboardSettled })
                XCTAssertNil(timing.snapshot.first { $0.phase == .pasteCommandPosted })
            }
        }
        fixture.onPost = {
            XCTAssertEqual(timing.snapshot.first { $0.phase == .clipboardSettled }?.outcome, .completed)
            XCTAssertNil(timing.snapshot.first { $0.phase == .pasteCommandPosted })
        }

        let result = await fixture.paste(destination: .originalApplication(Fixture.local), timing: timing)

        XCTAssertEqual(result.result, .commandPosted)
        XCTAssertEqual(result.target, Fixture.local)
        XCTAssertEqual(timing.snapshot.map(\.phase), [.requestReceived, .destinationReady, .clipboardSettled, .pasteCommandPosted])
        XCTAssertTrue(timing.snapshot.allSatisfy { $0.outcome == .completed })
    }

    func testPasteTimingPreservesReachedPhasesWhenTargetOrPostingFails() async {
        for missingTarget in [true, false] {
            let fixture = Fixture()
            fixture.running = !missingTarget
            fixture.postSucceeds = false
            let timing = RecordingTimingTrace()

            let result = await fixture.paste(destination: .originalApplication(Fixture.local), timing: timing)

            XCTAssertEqual(result.result, missingTarget ? .targetUnavailable : .commandNotPosted)
            for phase in [RecordingTimingTrace.Phase.destinationReady, .clipboardSettled] {
                XCTAssertEqual(timing.snapshot.first { $0.phase == phase }?.outcome, missingTarget ? .failed : .completed)
            }
            XCTAssertEqual(timing.snapshot.first { $0.phase == .pasteCommandPosted }?.outcome, .failed)
            XCTAssertTrue(fixture.learnedProcesses.isEmpty)
            XCTAssertTrue(fixture.sentKeys.isEmpty)
        }
    }

    func testDeliveryWithoutPasteMarksSkippedOrCanceledWithoutPosting() async {
        for cancel in [false, true] {
            let session = RecordingDeliverySession(destination: .currentApplication)
            if cancel { session.cancel() }
            let request = TranscriptionDelivery.Request(
                transcription: Transcription(text: "fixture", duration: 1, transcriptionStatus: .completed),
                text: nil, output: OutputRuntimeConfiguration(
                    mode: nil, outputMode: .paste, autoSendKey: .none, customCommand: nil
                ),
                responseConfig: nil, responseError: nil, isAssistantFollowUp: false, sendAfterPaste: false,
                deliverySession: session
            )
            var dismissed = false

            await TranscriptionDelivery().deliver(request, actions: .init(
                setState: { _ in XCTFail("No paste should start") }, dismiss: { dismissed = true },
                sendFollowUp: { _, _ in XCTFail("No follow-up") }, showResponse: { _, _ in XCTFail("No response") },
                failResponse: { _ in XCTFail("No response failure") }
            ))

            XCTAssertEqual(dismissed, !cancel)
            for phase in [RecordingTimingTrace.Phase.destinationReady, .clipboardSettled, .pasteCommandPosted] {
                XCTAssertEqual(session.timing.snapshot.first { $0.phase == phase }?.outcome, cancel ? .canceled : .skipped)
            }
        }
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

    func testLocalEventAndAppleScriptPastesKeepSeparateSettleBudgets() {
        let events = PastePolicy.resolve(for: Fixture.local, preferredMethod: .standard)
        let script = PastePolicy.resolve(for: Fixture.local, preferredMethod: .appleScript)

        XCTAssertEqual(events.method, .standard)
        XCTAssertEqual(events.settleDelay, 0.02)
        XCTAssertFalse(events.usesRemoteClipboard)
        XCTAssertEqual(script.method, .appleScript)
        XCTAssertEqual(script.settleDelay, 0.05)
        XCTAssertFalse(script.usesRemoteClipboard)
    }

    func testScreenSharingPushSuccessAndFailureHaveSeparateSettleBudgets() async {
        for failure in [false, true] {
            let fixture = Fixture()
            fixture.frontmost = Fixture.remote
            fixture.pushFails = failure
            let timing = RecordingTimingTrace()

            let result = await fixture.paste(command: "configured", timing: timing)

            XCTAssertEqual(result.result, .commandPosted)
            XCTAssertEqual(fixture.pushedTexts, ["transcript"])
            XCTAssertEqual(fixture.methods, [.appleScript])
            XCTAssertTrue(fixture.delays.contains(failure ? 0.8 : 0.2))
            XCTAssertEqual(fixture.failures.isEmpty, !failure)
            XCTAssertTrue(timing.snapshot.allSatisfy { $0.outcome == .completed })
        }
    }

    func testFocusChangeOrCancellationDuringSettleCannotPasteOrSend() async {
        for cancel in [false, true] {
            let fixture = Fixture()
            let recording = RecordingDeliverySession(destination: .originalApplication(Fixture.local))
            fixture.onWait = { delay in
                if delay == 0.02 {
                    if cancel { recording.cancel() }
                    else { fixture.frontmost = Fixture.remote }
                }
            }

            let result = await fixture.paste(destination: recording.destination, sendKey: .enter, timing: recording.timing) {
                recording.isCancelled
            }

            XCTAssertFalse(result.result.didPostPasteCommand)
            XCTAssertTrue(fixture.methods.isEmpty)
            XCTAssertTrue(fixture.sentKeys.isEmpty)
            XCTAssertEqual(recording.timing.snapshot.first { $0.phase == .destinationReady }?.outcome, .completed)
            for phase in [RecordingTimingTrace.Phase.clipboardSettled, .pasteCommandPosted] {
                XCTAssertEqual(recording.timing.snapshot.first { $0.phase == phase }?.outcome, cancel ? .canceled : .failed)
            }
        }
    }

    func testExternalClipboardChangeDuringSettlePreventsPasteAndAutoSend() async throws {
        let fixture = Fixture()
        let timing = RecordingTimingTrace()
        fixture.onWait = { delay in
            if delay == 0.02 { ClipboardManager.setClipboard("external", on: fixture.board) }
        }

        let result = await fixture.paste(restore: true, sendKey: .enter, timing: timing)
        try await Task.sleep(for: .seconds(0.4))

        XCTAssertEqual(result.result, .cancelled)
        XCTAssertEqual(fixture.board.string(forType: .string), "external")
        XCTAssertTrue(fixture.methods.isEmpty)
        XCTAssertTrue(fixture.learnedProcesses.isEmpty)
        XCTAssertTrue(fixture.sentKeys.isEmpty)
        XCTAssertEqual(timing.snapshot.first { $0.phase == .destinationReady }?.outcome, .completed)
        XCTAssertEqual(timing.snapshot.first { $0.phase == .clipboardSettled }?.outcome, .canceled)
        XCTAssertEqual(timing.snapshot.first { $0.phase == .pasteCommandPosted }?.outcome, .canceled)
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
        let oldTiming = RecordingTimingTrace()
        let newTiming = RecordingTimingTrace()
        let entered = expectation(description: "old paste waiting")
        var release: CheckedContinuation<Void, Never>?
        fixture.onAsyncWait = { delay in
            if delay == 0.02 && fixture.board.string(forType: .string) == "old" {
                entered.fulfill()
                await withCheckedContinuation { release = $0 }
            }
        }
        let old = Task { await fixture.paste(text: "old", timing: oldTiming) }
        await fulfillment(of: [entered], timeout: 2)

        let newer = await fixture.paste(text: "new", timing: newTiming)
        release?.resume()
        let older = await old.value

        XCTAssertEqual(newer.result, .commandPosted)
        XCTAssertEqual(older.result, .cancelled)
        XCTAssertEqual(fixture.postedTexts, ["new"])
        XCTAssertEqual(fixture.board.string(forType: .string), "new")
        XCTAssertEqual(oldTiming.snapshot.first { $0.phase == .pasteCommandPosted }?.outcome, .canceled)
        XCTAssertEqual(newTiming.snapshot.first { $0.phase == .pasteCommandPosted }?.outcome, .completed)
        XCTAssertNotEqual(oldTiming.recordingID, newTiming.recordingID)
        XCTAssertEqual(oldTiming.snapshot.count, 4)
        XCTAssertEqual(newTiming.snapshot.count, 4)
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

    func testChromiumPasteRaceTypesForClipboardPreferencesWithoutTouchingClipboard() async {
        for method in [PasteMethod.standard, .appleScript] {
            let fixture = Fixture()
            fixture.frontmost = Fixture.remote
            fixture.board.setString("original", forType: .string)
            let timing = RecordingTimingTrace()

            let result = await fixture.paste(
                destination: .originalApplication(Fixture.chromium), restore: true, method: method,
                sendKey: .enter, timing: timing
            )

            XCTAssertEqual(result.result, .commandPosted)
            XCTAssertEqual(result.target, Fixture.chromium)
            XCTAssertEqual(fixture.activations, [Fixture.chromium])
            XCTAssertEqual(fixture.methods, [.directTyping])
            XCTAssertEqual(fixture.typedTexts, ["transcript"])
            XCTAssertTrue(fixture.postedTexts.isEmpty)
            XCTAssertTrue(fixture.delays.contains(0.02))
            XCTAssertEqual(fixture.board.string(forType: .string), "original")
            XCTAssertEqual(fixture.learnedTexts, ["transcript"])
            XCTAssertEqual(fixture.learnedProcesses, [Fixture.chromium.processID])
            XCTAssertEqual(fixture.cancelledGenerations, [42])
            XCTAssertEqual(fixture.sentKeys, [.enter])
            XCTAssertEqual(timing.snapshot.map(\.phase), [.requestReceived, .destinationReady, .clipboardSettled, .pasteCommandPosted])
            XCTAssertTrue(timing.snapshot.allSatisfy { $0.outcome == .completed })
        }
    }

    func testChromiumPasteRaceKeepsTypingPreferencesAndOtherDestinationsPaste() {
        let directTyping = PastePolicy.resolve(for: Fixture.chromium, preferredMethod: .directTyping, losesSyntheticPaste: true)
        let remoteTyping = PastePolicy.resolve(for: Fixture.chromium, preferredMethod: .remoteTyping, losesSyntheticPaste: true)
        let screenSharing = PastePolicy.resolve(for: Fixture.remote, preferredMethod: .standard, losesSyntheticPaste: true)
        let unaffected = PastePolicy.resolve(for: Fixture.chromium, preferredMethod: .standard)

        XCTAssertEqual(directTyping, PastePolicy(method: .directTyping, settleDelay: 0.02, usesRemoteClipboard: false))
        XCTAssertEqual(remoteTyping, PastePolicy(method: .remoteTyping, settleDelay: 0.2, usesRemoteClipboard: false))
        XCTAssertEqual(screenSharing.method, .appleScript)
        XCTAssertEqual(unaffected, PastePolicy(method: .standard, settleDelay: 0.02, usesRemoteClipboard: false))
    }

    func testManualPasteIntoCurrentChromiumApplicationTypes() async {
        let fixture = Fixture()
        fixture.frontmost = Fixture.chromium
        fixture.board.setString("original", forType: .string)

        let result = await fixture.paste(text: "line one\nline two")

        XCTAssertEqual(result.result, .commandPosted)
        XCTAssertTrue(fixture.activations.isEmpty)
        XCTAssertEqual(fixture.methods, [.directTyping])
        XCTAssertEqual(fixture.typedTexts, ["line one\nline two"])
        XCTAssertEqual(fixture.board.string(forType: .string), "original")
    }

    func testChromiumTypingFailureLeavesTextOnClipboardWithoutAutoLearnOrSend() async {
        for typed in [CursorPaster.PasteResult.commandNotPosted, .commandPartiallyPosted] {
            let fixture = Fixture()
            fixture.frontmost = Fixture.chromium
            fixture.board.setString("original", forType: .string)
            fixture.typeResult = typed
            let timing = RecordingTimingTrace()

            let result = await fixture.paste(sendKey: .enter, timing: timing)

            XCTAssertEqual(result.result, typed)
            XCTAssertEqual(fixture.board.string(forType: .string), "transcript")
            XCTAssertEqual(fixture.failures.count, 1)
            XCTAssertTrue(fixture.learnedProcesses.isEmpty)
            XCTAssertTrue(fixture.sentKeys.isEmpty)
            XCTAssertEqual(timing.snapshot.first { $0.phase == .pasteCommandPosted }?.outcome, .failed)
        }
    }

    func testChromiumTypingStopsForCancellationFocusChangeOrNewerSession() async {
        for interruption in ["cancel", "focus", "newer"] {
            let fixture = Fixture()
            fixture.board.setString("original", forType: .string)
            let recording = RecordingDeliverySession(destination: .originalApplication(Fixture.chromium))
            fixture.frontmost = Fixture.chromium
            var interrupted = false
            fixture.onType = {
                guard !interrupted else { return }
                interrupted = true
                switch interruption {
                case "cancel": recording.cancel()
                case "focus": fixture.frontmost = Fixture.local
                default: _ = await fixture.paste(text: "newer", destination: .originalApplication(Fixture.local))
                }
            }

            let result = await fixture.paste(
                destination: recording.destination, sendKey: .enter, timing: recording.timing
            ) { recording.isCancelled }

            XCTAssertFalse(result.result.didPostPasteCommand, interruption)
            XCTAssertFalse(fixture.typedTexts.contains("transcript"), interruption)
            XCTAssertFalse(fixture.sentKeys.contains(.enter), interruption)
            XCTAssertFalse(fixture.learnedProcesses.contains(Fixture.chromium.processID), interruption)
            let clipboard = fixture.board.string(forType: .string)
            switch interruption {
            case "cancel": XCTAssertEqual(clipboard, "original")
            case "focus": XCTAssertEqual(clipboard, "transcript")
            default: XCTAssertEqual(clipboard, "newer")
            }
        }
    }

    func testChromiumCheckFollowsFocusChangesBeforeDelivery() async {
        for intoChromium in [false, true] {
            for method in [PasteMethod.standard, .appleScript] {
                for restore in [false, true] {
                    let fixture = Fixture()
                    fixture.frontmost = Fixture.remote
                    let entered = expectation(description: "old remote push started")
                    let effectiveTarget = intoChromium ? Fixture.chromium : Fixture.local
                    fixture.onPush = { _ in
                        entered.fulfill()
                        do { try await Task.sleep(for: .seconds(30)) }
                        catch {
                            fixture.frontmost = effectiveTarget
                            throw error
                        }
                    }
                    let old = Task { await fixture.paste(text: "old", command: "configured") }
                    await fulfillment(of: [entered], timeout: 2)
                    fixture.frontmost = intoChromium ? Fixture.local : Fixture.chromium
                    let clipboardText = fixture.board.string(forType: .string)
                    let clipboardChangeCount = fixture.board.changeCount

                    let result = await fixture.paste(restore: restore, method: method)
                    let older = await old.value

                    XCTAssertEqual(older.result, .cancelled)
                    XCTAssertEqual(result.result, .commandPosted)
                    XCTAssertEqual(result.target, effectiveTarget)
                    XCTAssertEqual(fixture.methods, [intoChromium ? .directTyping : method])
                    if intoChromium {
                        XCTAssertEqual(fixture.typedTexts, ["transcript"])
                        XCTAssertTrue(fixture.postedTexts.isEmpty)
                        XCTAssertEqual(fixture.board.string(forType: .string), clipboardText)
                        XCTAssertEqual(fixture.board.changeCount, clipboardChangeCount)
                    } else {
                        XCTAssertEqual(fixture.postedTexts, ["transcript"])
                        XCTAssertTrue(fixture.typedTexts.isEmpty)
                    }
                }
            }
        }
    }

    func testSupersededRemotePushPreservesOriginalClipboardForNewPasteRestoration() async throws {
        let fixture = Fixture()
        let data = Data([1, 2, 3])
        fixture.board.setData(data, forType: .pdf)
        fixture.board.setString("original", forType: .string)
        fixture.frontmost = Fixture.remote
        let entered = expectation(description: "old remote push started")
        fixture.onPush = { _ in
            entered.fulfill()
            try await Task.sleep(for: .seconds(30))
        }
        let old = Task { await fixture.paste(text: "old", restore: true, command: "configured") }
        await fulfillment(of: [entered], timeout: 2)

        let result = await fixture.paste(destination: .originalApplication(Fixture.local), restore: true)
        let older = await old.value
        try await Task.sleep(for: .seconds(0.4))

        XCTAssertEqual(older.result, .cancelled)
        XCTAssertEqual(result.result, .commandPosted)
        XCTAssertEqual(fixture.postedTexts, ["transcript"])
        XCTAssertEqual(fixture.board.string(forType: .string), "original")
        XCTAssertEqual(fixture.board.data(forType: .pdf), data)
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
        static let chromium = PasteApplication(processID: 300, bundleIdentifier: "com.google.Chrome")
        let board = NSPasteboard(name: NSPasteboard.Name("DictationDeliveryTests.\(UUID())"))
        var frontmost: PasteApplication? = local
        var running = true
        var activationAllowed = true
        var activationChangesFocus = true
        var pushFails = false
        var postSucceeds = true
        var typeResult = CursorPaster.PasteResult.commandPosted
        var typedTexts: [String] = []
        var onType: (() async -> Void)?
        var activations: [PasteApplication] = []
        var methods: [PasteMethod] = []
        var pushedTexts: [String] = []
        var postedTexts: [String] = []
        var delays: [TimeInterval] = []
        var learnedProcesses: [pid_t] = []
        var learnedTexts: [String] = []
        var cancelledGenerations: [UInt64] = []
        var sentKeys: [FinishAndSendKey] = []
        var failures: [String] = []
        var onPush: ((String) async throws -> Void)?
        var onWait: ((TimeInterval) -> Void)?
        var onAsyncWait: ((TimeInterval) async -> Void)?
        var onPost: (() -> Void)?
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
                self.onPost?()
                self.methods.append(method)
                self.postedTexts.append(self.board.string(forType: .string) ?? "")
                return self.postSucceeds
            },
            typeText: { method, text, _, canPost in
                await self.onType?()
                guard canPost() else { return (.commandNotPosted, nil) }
                self.methods.append(method)
                self.typedTexts.append(text)
                return (self.typeResult, nil)
            },
            losesSyntheticPaste: { $0 == Self.chromium },
            autoLearn: { text, process, _ in
                self.learnedTexts.append(text)
                self.learnedProcesses.append(process)
                return 42
            },
            cancelAutoLearn: { self.cancelledGenerations.append($0) },
            send: { key, _ in self.sentKeys.append(key) },
            reportFailure: { self.failures.append($0) }
        ))

        func paste(
            text: String = "transcript", destination: PasteDestination = .currentApplication,
            restore: Bool = false, method: PasteMethod = .standard, command: String? = nil,
            sendKey: FinishAndSendKey = .none, timing: RecordingTimingTrace? = nil,
            shouldCancel: @escaping () -> Bool = { false }
        ) async -> CursorPaster.PasteOutcome {
            await session.paste(
                text, destination: destination, restoreClipboard: restore, restoreDelay: 0.25,
                preferredMethod: method, remotePushCommand: command, sendKey: sendKey, timing: timing,
                shouldCancel: shouldCancel
            )
        }
    }
}
