import AppKit
import Carbon
import XCTest
@testable import VoiceInk

@MainActor
final class DictationShortcutTests: XCTestCase {
    func testBareBackslashUsesPhysicalKeyAndStillRejectsShiftOnlyTyping() {
        let bare = Shortcut.key(keyCode: UInt16(kVK_ANSI_Backslash), modifierFlags: [])

        XCTAssertNil(ShortcutValidator.validationError(for: bare, action: .primaryRecording))
        XCTAssertEqual(bare.systemHotKeyModifiers, 0)
        XCTAssertTrue(bare.matchesKeyEvent(keyCode: UInt16(kVK_ANSI_Backslash), modifierFlags: [.capsLock]))
        XCTAssertFalse(bare.matchesKeyEvent(keyCode: UInt16(kVK_ANSI_Slash), modifierFlags: []))
        let shift = Shortcut.key(keyCode: UInt16(kVK_ANSI_Backslash), modifierFlags: [.shift])
        XCTAssertEqual(ShortcutValidator.validationError(for: shift, action: .primaryRecording), .shiftTypingKeyRequiresAdditionalModifier)
        for modifiers: NSEvent.ModifierFlags in [[.control], [.option], [.command], [.control, .shift]] {
            let shortcut = Shortcut.key(keyCode: UInt16(kVK_ANSI_Backslash), modifierFlags: modifiers)
            XCTAssertNil(ShortcutValidator.validationError(for: shortcut, action: .primaryRecording))
        }
    }

    func testOtherPlainTypingKeysAndReservedCombinationsRemainRejected() {
        for key in [kVK_ANSI_A, kVK_ANSI_Slash, kVK_Space, kVK_ANSI_1] {
            let shortcut = Shortcut.key(keyCode: UInt16(key), modifierFlags: [])
            XCTAssertEqual(ShortcutValidator.validationError(for: shortcut, action: .primaryRecording), .plainKeyRequiresModifier)
        }
        XCTAssertNil(ShortcutValidator.validationError(for: .key(keyCode: UInt16(kVK_F19), modifierFlags: []), action: .primaryRecording))
        XCTAssertEqual(ShortcutValidator.validationError(for: .key(keyCode: UInt16(kVK_ANSI_V), modifierFlags: [.command]), action: .primaryRecording), .reservedBySystem)
        XCTAssertNotNil(ShortcutValidator.validationError(for: .key(keyCode: UInt16(kVK_ANSI_1), modifierFlags: [.option]), action: .primaryRecording))
    }

    func testBareBackslashStillChecksStoredConflicts() throws {
        let action = ShortcutAction.secondaryRecording
        let key = action.userDefaultsKey
        let clearedKey = key + "_cleared"
        let defaults = UserDefaults.standard
        let original = defaults.object(forKey: key)
        let cleared = defaults.object(forKey: clearedKey)
        defer {
            if let original { defaults.set(original, forKey: key) } else { defaults.removeObject(forKey: key) }
            if let cleared { defaults.set(cleared, forKey: clearedKey) } else { defaults.removeObject(forKey: clearedKey) }
        }
        let shortcut = Shortcut.key(keyCode: UInt16(kVK_ANSI_Backslash), modifierFlags: [])
        defaults.set(try JSONEncoder().encode(shortcut), forKey: key)
        defaults.removeObject(forKey: clearedKey)

        let error = ShortcutValidator.validationError(for: shortcut, action: .primaryRecording)

        XCTAssertEqual(error, .alreadyUsedBy(action.displayName))
    }

    func testToggleAllowsQuarterSecondRestartAndRejectsDuplicateDowns() async {
        let fixture = HandlerFixture()
        await fixture.down(at: 0, mode: .toggle)
        await fixture.down(at: 0.01, mode: .toggle)
        await fixture.up(at: 0.02, mode: .toggle)
        XCTAssertEqual(fixture.toggles, 1)
        await fixture.down(at: 0.249, mode: .toggle)
        await fixture.up(at: 0.249, mode: .toggle)
        XCTAssertEqual(fixture.toggles, 1)

        await fixture.down(at: 0.25, mode: .toggle)
        await fixture.up(at: 0.26, mode: .toggle)
        await fixture.down(at: 0.5, mode: .toggle)

        XCTAssertEqual(fixture.toggles, 3)
    }

    func testPushToTalkReleaseSurvivesCooldownAndRapidRestart() async {
        let fixture = HandlerFixture()
        await fixture.down(at: 0, mode: .pushToTalk)
        await fixture.down(at: 0.01, mode: .pushToTalk)
        await fixture.up(at: 0.02, mode: .pushToTalk)
        XCTAssertEqual(fixture.toggles, 1)
        XCTAssertEqual(fixture.cancels, 1)
        XCTAssertFalse(fixture.visible)

        await fixture.down(at: 0.25, mode: .pushToTalk)
        await fixture.up(at: 0.6, mode: .pushToTalk)

        XCTAssertEqual(fixture.toggles, 3)
        XCTAssertEqual(fixture.cancels, 1)
    }

    func testShortPushToTalkTapDiscardsTheRecordingAndRetractsTheStartTone() async {
        let fixture = HandlerFixture()
        await fixture.down(at: 0, mode: .pushToTalk)
        await fixture.up(at: 0.299, mode: .pushToTalk)

        XCTAssertEqual(fixture.toggles, 1)
        XCTAssertEqual(fixture.cancels, 1)
        XCTAssertEqual(fixture.retractions, 1)

        await fixture.down(at: 1, mode: .pushToTalk)
        await fixture.up(at: 1.3, mode: .pushToTalk)

        XCTAssertEqual(fixture.toggles, 3)
        XCTAssertEqual(fixture.cancels, 1)
        XCTAssertEqual(fixture.retractions, 1)
    }

    func testToggleHybridAndDoubleTapTapsKeepTheStartTone() async {
        let toggle = HandlerFixture()
        await toggle.down(at: 0, mode: .toggle)
        await toggle.up(at: 0.05, mode: .toggle)
        let hybrid = HandlerFixture()
        await hybrid.down(at: 0, mode: .hybrid)
        await hybrid.up(at: 0.1, mode: .hybrid)
        let double = HandlerFixture()
        await double.down(at: 0, mode: .doubleTap)
        await double.up(at: 0.05, mode: .doubleTap)
        await double.down(at: 0.1, mode: .doubleTap)
        await double.up(at: 0.15, mode: .doubleTap)

        for fixture in [toggle, hybrid, double] {
            XCTAssertEqual(fixture.toggles, 1)
            XCTAssertTrue(fixture.visible)
            XCTAssertEqual(fixture.cancels, 0)
            XCTAssertEqual(fixture.retractions, 0)
        }
    }

    func testChordDuringAnAccidentalStartRetractsTheStartToneInEveryMode() async {
        for mode in [RecordingShortcutManager.Mode.toggle, .pushToTalk, .hybrid] {
            let fixture = HandlerFixture()
            await fixture.down(at: 0, mode: mode)

            await fixture.handler.handleInterruption(action: .primaryRecording, pressedAt: 0)

            XCTAssertEqual(fixture.cancels, 1, "\(mode)")
            XCTAssertEqual(fixture.retractions, 1, "\(mode)")
        }
        let double = HandlerFixture()
        await double.down(at: 0, mode: .doubleTap)
        await double.handler.handleInterruption(action: .primaryRecording, pressedAt: 0)
        await double.up(at: 0.05, mode: .doubleTap)
        await double.down(at: 0.1, mode: .doubleTap)
        await double.up(at: 0.15, mode: .doubleTap)
        XCTAssertEqual(double.toggles, 0, "A chord clears the pending double tap before any start tone")
        XCTAssertEqual(double.retractions, 0)
    }

    func testHybridHoldThresholdAndDoubleTapTimingRemainUnchanged() async {
        let hybrid = HandlerFixture()
        await hybrid.down(at: 0, mode: .hybrid)
        await hybrid.up(at: 0.5, mode: .hybrid)
        XCTAssertEqual(hybrid.toggles, 2)
        let double = HandlerFixture()
        await double.down(at: 0, mode: .doubleTap)
        await double.up(at: 0.05, mode: .doubleTap)
        await double.down(at: 0.1, mode: .doubleTap)
        await double.down(at: 0.11, mode: .doubleTap)
        await double.up(at: 0.15, mode: .doubleTap)
        XCTAssertEqual(double.toggles, 1)
        await double.down(at: 0.25, mode: .doubleTap)
        await double.up(at: 0.3, mode: .doubleTap)
        await double.down(at: 1.01, mode: .doubleTap)
        await double.up(at: 1.06, mode: .doubleTap)
        XCTAssertEqual(double.toggles, 1)
    }

    func testRecordingGesturesForwardTheirPhysicalPressTimes() async {
        let toggle = HandlerFixture()
        await toggle.down(at: 10, mode: .toggle)
        XCTAssertEqual(toggle.eventTimes, [10])
        let double = HandlerFixture()
        await double.down(at: 10, mode: .doubleTap)
        await double.up(at: 10.05, mode: .doubleTap)
        await double.down(at: 10.1, mode: .doubleTap)
        await double.up(at: 10.2, mode: .doubleTap)
        XCTAssertEqual(double.eventTimes, [10.1])
    }

    @MainActor private final class HandlerFixture {
        var now: TimeInterval = 0
        var visible = false
        var toggles = 0
        var eventTimes: [TimeInterval] = []
        var cancels = 0
        var retractions = 0
        var held = false
        lazy var handler = RecordingShortcutModeHandler(
            canHandleShortcutAction: { true }, isRecorderVisible: { self.visible },
            recordingState: { self.visible ? .recording : .idle },
            isShortcutHeld: { _ in self.held }, finishHeldRecording: {},
            toggleRecorderPanel: { _, eventTime in self.visible.toggle(); self.toggles += 1; self.eventTimes.append(eventTime) },
            cancelRecording: { self.visible = false; self.cancels += 1 },
            retractStartSound: { self.retractions += 1 }, now: { self.now }
        )
        func down(at time: TimeInterval, mode: RecordingShortcutManager.Mode) async {
            now = time
            held = true
            await handler.handleShortcutDown(action: .primaryRecording, eventTime: time, mode: mode)
        }
        func up(at time: TimeInterval, mode: RecordingShortcutManager.Mode) async {
            now = time
            held = false
            await handler.handleShortcutUp(action: .primaryRecording, eventTime: time, mode: mode)
        }
    }
}
