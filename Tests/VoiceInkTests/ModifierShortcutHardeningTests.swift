import AppKit
import Carbon.HIToolbox
import CoreGraphics
import XCTest
import os

@testable import VoiceInk

/// Modifier-only shortcut chords, hidden global hot keys and the chord breaker, adapted from Hex.
@MainActor
final class ModifierShortcutHardeningTests: XCTestCase {
    private static let option = Shortcut.modifierOnly(keyCode: UInt16(kVK_Option), modifierFlags: [.option])
    private static let digitOne = UInt16(kVK_ANSI_1)

    // MARK: Discard at any time

    func testHeldModifierOnlyShortcutPlusAnyKeyInterruptsLongAfterThePress() async throws {
        let harness = MonitorHarness(shortcut: Self.option)
        let pressedAt = harness.now - 4

        harness.modifier(down: true, at: pressedAt)
        harness.session(.keyDown, key: Self.digitOne, flags: [.option], at: pressedAt + 2)
        await harness.drain()

        assertTimes(harness.events.interruptions, [pressedAt])
        harness.modifier(down: false, at: pressedAt + 3)
        await harness.drain()
        assertTimes(harness.events.downs, [pressedAt])
        XCTAssertEqual(harness.events.ups.count, 1)
    }

    func testOnlyAHeldModifierShortcutExtendsTheInterruptionWindow() async throws {
        let modifier = MonitorHarness(shortcut: Self.option)
        let pressedAt = modifier.now - 4
        modifier.modifier(down: true, at: pressedAt)
        // A key without the modifier after a missed release is not a chord.
        modifier.session(.keyDown, key: Self.digitOne, flags: [], at: pressedAt + 2)
        await modifier.drain()
        XCTAssertEqual(modifier.events.interruptions, [])

        let keyed = MonitorHarness(shortcut: .key(keyCode: UInt16(kVK_ANSI_K), modifierFlags: [.function]))
        keyed.session(.keyDown, key: UInt16(kVK_ANSI_K), flags: [.function], at: pressedAt)
        keyed.session(.keyDown, key: Self.digitOne, flags: [.function], at: pressedAt + 2)
        await keyed.drain()
        XCTAssertEqual(keyed.events.interruptions, [], "Keyed shortcuts keep the one-second window")

        let early = MonitorHarness(shortcut: Self.option)
        early.modifier(down: true, at: pressedAt)
        early.session(.keyDown, key: Self.digitOne, flags: [], at: pressedAt + 0.5)
        await early.drain()
        assertTimes(early.events.interruptions, [pressedAt])
    }

    func testVoiceInksOwnPostedKeysAreNotChords() async throws {
        let harness = MonitorHarness(shortcut: Self.option)
        let pressedAt = harness.now - 4
        harness.modifier(down: true, at: pressedAt)

        harness.session(.keyDown, key: UInt16(kVK_ANSI_V), flags: [.option, .command], at: pressedAt + 0.2, sourcePID: getpid())
        await harness.drain()

        XCTAssertEqual(harness.events.interruptions, [])
    }

    // MARK: Keys consumed by other apps' global hot keys

    func testKeyConsumedBeforeTheSessionInterruptsThroughTheHIDTap() async throws {
        let harness = MonitorHarness(shortcut: Self.option)
        let pressedAt = harness.now - 4
        harness.modifier(down: true, at: pressedAt)

        harness.physical(key: Self.digitOne, flags: [.option], at: pressedAt + 2)
        harness.session(.keyDown, key: Self.digitOne, flags: [.option], at: pressedAt + 2)
        await harness.drain()

        assertTimes(harness.events.interruptions, [pressedAt], "The session copy of the same key adds nothing")
    }

    func testHIDEvidenceIgnoresEscapeOwnShortcutsSyntheticKeysAndEarlierPresses() async throws {
        let paste = Shortcut.key(keyCode: UInt16(kVK_ANSI_V), modifierFlags: [.option, .function])
        let harness = MonitorHarness(shortcut: Self.option, extraShortcuts: [.pasteLastTranscription: paste])
        let pressedAt = harness.now - 4
        harness.modifier(down: true, at: pressedAt)

        harness.physical(key: UInt16(kVK_Escape), flags: [.option], at: pressedAt + 1.5)
        harness.physical(key: UInt16(kVK_ANSI_V), flags: [.option, .function], at: pressedAt + 1.6)
        harness.physical(key: Self.digitOne, flags: [.option], at: pressedAt + 1.7, marked: true)
        harness.physical(key: Self.digitOne, flags: [.option], at: pressedAt + 1.8, sourcePID: getpid())
        harness.physical(key: Self.digitOne, flags: [.option], at: pressedAt - 0.1)
        await harness.drain()

        XCTAssertEqual(harness.events.interruptions, [])
    }

    func testHIDEvidenceThatOvertakesItsPressPreventsTheCapture() async throws {
        for standalone in [false, true] {
            let harness = MonitorHarness(shortcut: Self.option, standalone: standalone)
            let pressedAt = harness.now - 2
            harness.physical(key: Self.digitOne, flags: [.option], at: pressedAt + 0.05)

            harness.modifier(down: true, at: pressedAt)
            harness.modifier(down: false, at: pressedAt + 0.6)
            await harness.drain()

            XCTAssertEqual(harness.events.downs, [], "standalone=\(standalone)")
            XCTAssertEqual(harness.events.ups, [], "standalone=\(standalone)")
        }

        let harness = MonitorHarness(shortcut: Self.option)
        let pressedAt = harness.now - 2
        harness.physical(key: Self.digitOne, flags: [], at: pressedAt - 0.05)
        harness.modifier(down: true, at: pressedAt)
        await harness.drain()
        assertTimes(harness.events.downs, [pressedAt], "A key typed before the press is not its chord")
    }

    func testHiddenChordDuringAStandaloneCandidateNeverTriggersIt() async throws {
        let harness = MonitorHarness(shortcut: Self.option, standalone: true)
        let pressedAt = harness.now - 3

        harness.modifier(down: true, at: pressedAt)
        harness.physical(key: Self.digitOne, flags: [.option], at: pressedAt + 1)
        harness.modifier(down: false, at: pressedAt + 1.2)
        harness.modifier(down: true, at: pressedAt + 2)
        harness.modifier(down: false, at: pressedAt + 2.1)
        await harness.drain()

        assertTimes(harness.events.downs, [pressedAt + 2])
        assertTimes(harness.events.ups, [pressedAt + 2.1])
    }

    func testMissingHIDTapLeavesShortcutsWorking() async throws {
        let harness = MonitorHarness(shortcut: Self.option, physicalTapAvailable: false)
        let pressedAt = harness.now - 3

        harness.modifier(down: true, at: pressedAt)
        harness.session(.keyDown, key: Self.digitOne, flags: [.option], at: pressedAt + 2)
        await harness.drain()

        XCTAssertTrue(harness.monitor.isMonitoring(.primaryRecording))
        assertTimes(harness.events.downs, [pressedAt])
        assertTimes(harness.events.interruptions, [pressedAt])
        XCTAssertTrue(harness.monitor.diagnosticSummary.contains("physicalTap=none physicalTapIssue=unavailable"))
    }

    // MARK: Chord breaker

    func testHeldPushToTalkPressBreaksTheChordOnceAfterTheHoldThreshold() async throws {
        let harness = MonitorHarness(shortcut: Self.option, chordBreakerDelay: 0.3)
        let pressedAt = harness.now

        harness.modifier(down: true, at: pressedAt)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(harness.breakers.count, 0)
        try await Task.sleep(for: .milliseconds(350))
        harness.modifier(down: false, at: harness.now)
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(harness.breakers.flags, [CGEventFlags.maskAlternate])
    }

    func testShortTapsChordsExtraModifiersAndTapModesNeverBreakTheChord() async throws {
        let shortTap = MonitorHarness(shortcut: Self.option, chordBreakerDelay: 0.3)
        shortTap.modifier(down: true, at: shortTap.now)
        try await Task.sleep(for: .milliseconds(100))
        shortTap.modifier(down: false, at: shortTap.now)

        let chord = MonitorHarness(shortcut: Self.option, chordBreakerDelay: 0.3)
        chord.modifier(down: true, at: chord.now)
        chord.session(.keyDown, key: Self.digitOne, flags: [.option], at: chord.now)

        let extraModifier = MonitorHarness(
            shortcut: Self.option, chordBreakerDelay: 0.3, physicalFlags: [.maskAlternate, .maskShift]
        )
        extraModifier.modifier(down: true, at: extraModifier.now)

        let doubleTap = MonitorHarness(shortcut: Self.option, standalone: true)
        doubleTap.modifier(down: true, at: doubleTap.now)

        let function = MonitorHarness(
            shortcut: .modifierOnly(keyCode: UInt16(kVK_Function), modifierFlags: [.function]),
            chordBreakerDelay: 0.04, physicalFlags: .maskSecondaryFn
        )
        function.modifier(down: true, at: function.now, key: UInt16(kVK_Function), flags: [.function])

        try await Task.sleep(for: .milliseconds(450))
        for (name, harness) in [("short tap", shortTap), ("chord", chord), ("extra modifier", extraModifier),
                                ("double tap", doubleTap), ("Fn", function)] {
            XCTAssertEqual(harness.breakers.count, 0, name)
        }
    }

    func testToggleCandidateBreaksTheChordAndIgnoresTheBreakerItself() async throws {
        let harness = MonitorHarness(shortcut: Self.option, standalone: true, chordBreakerDelay: 0.04)
        let pressedAt = harness.now

        harness.modifier(down: true, at: pressedAt)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(harness.breakers.count, 1)
        for event in ChordBreaker.makeEvents(flags: .maskAlternate) {
            XCTAssertFalse(harness.deliver(event.type, event), "The breaker passes on to the annotated-session filter")
        }
        harness.physical(ChordBreaker.makeEvents(flags: .maskAlternate)[0])
        harness.modifier(down: false, at: harness.now)
        await harness.drain()

        assertTimes(harness.events.downs, [pressedAt])
        XCTAssertEqual(harness.events.ups.count, 1)
        XCTAssertEqual(harness.events.interruptions, [])
    }

    func testRecordingModesChooseHexsBreakerDelays() {
        XCTAssertEqual(RecordingShortcutManager.Mode.pushToTalk.chordBreakerDelay, 0.3)
        XCTAssertEqual(RecordingShortcutManager.Mode.toggle.chordBreakerDelay, 0.04)
        XCTAssertEqual(RecordingShortcutManager.Mode.hybrid.chordBreakerDelay, 0.04)
        XCTAssertNil(RecordingShortcutManager.Mode.doubleTap.chordBreakerDelay)
    }

    func testChordBreakerIsOneMarkedPressOfTheUnassignedKey() throws {
        let events = ChordBreaker.makeEvents(flags: [.maskAlternate, .maskCommand])

        XCTAssertEqual(events.map(\.type), [.keyDown, .keyUp])
        for event in events {
            XCTAssertEqual(event.getIntegerValueField(.keyboardEventKeycode), 0x44)
            XCTAssertEqual(event.flags, [.maskAlternate, .maskCommand])
            XCTAssertTrue(ChordBreaker.isChordBreaker(type: event.type, event: event))
        }
        let unmarked = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 0x44, keyDown: true))
        XCTAssertFalse(ChordBreaker.isChordBreaker(type: .keyDown, event: unmarked))
        let markedOtherKey = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_ANSI_A), keyDown: true))
        markedOtherKey.setIntegerValueField(.eventSourceUserData, value: ChordBreaker.eventMarker)
        XCTAssertFalse(ChordBreaker.isChordBreaker(type: .keyDown, event: markedOtherKey))
        XCTAssertFalse(ChordBreaker.isChordBreaker(type: .flagsChanged, event: events[0]))
    }

    func testHIDTimestampsReadAsMachTicksOrNanosecondsAndFallBackToArrival() {
        let nanosecondsPerTick = 125.0 / 3
        let now: TimeInterval = 1_000

        XCTAssertEqual(PhysicalKeyEventTime.seconds(rawTimestamp: UInt64(999.5 * 1e9 / nanosecondsPerTick), now: now,
                                                    nanosecondsPerMachTick: nanosecondsPerTick), 999.5, accuracy: 1e-6)
        XCTAssertEqual(PhysicalKeyEventTime.seconds(rawTimestamp: UInt64(999.5 * 1e9), now: now,
                                                    nanosecondsPerMachTick: nanosecondsPerTick), 999.5, accuracy: 1e-6)
        XCTAssertEqual(PhysicalKeyEventTime.seconds(rawTimestamp: UInt64(900 * 1e9), now: now,
                                                    nanosecondsPerMachTick: nanosecondsPerTick), now)
    }

    /// Event timestamps carry whole nanoseconds.
    private func assertTimes(_ actual: [TimeInterval], _ expected: [TimeInterval], _ message: String = "",
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.count, expected.count, message, file: file, line: line)
        for (actual, expected) in zip(actual, expected) {
            XCTAssertEqual(actual, expected, accuracy: 1e-6, message, file: file, line: line)
        }
    }

    // MARK: Recording mode handling

    func testLongHeldChordCancelsOnlyCapturesItsPressStarted() async {
        for mode in [RecordingShortcutManager.Mode.pushToTalk, .hybrid] {
            let fixture = HandlerFixture()
            await fixture.down(at: 0, mode: mode)
            fixture.now = 5

            await fixture.handler.handleInterruption(action: .primaryRecording, pressedAt: 0)
            await fixture.up(at: 6, mode: mode)

            XCTAssertEqual(fixture.cancels, 1, "\(mode)")
            XCTAssertEqual(fixture.toggles, 1, "\(mode): no stop after the discard")
        }

        let alreadyRecording = HandlerFixture()
        alreadyRecording.visible = true
        await alreadyRecording.down(at: 0, mode: .pushToTalk)
        await alreadyRecording.handler.handleInterruption(action: .primaryRecording, pressedAt: 0)
        XCTAssertEqual(alreadyRecording.cancels, 0, "A press that did not start the capture keeps it")

        let transcribing = HandlerFixture()
        await transcribing.down(at: 0, mode: .pushToTalk)
        transcribing.state = .transcribing
        await transcribing.handler.handleInterruption(action: .primaryRecording, pressedAt: 0)
        XCTAssertEqual(transcribing.cancels, 0, "A capture stopped by other means keeps its transcription")
    }

    @MainActor private final class HandlerFixture {
        var now: TimeInterval = 0
        var visible = false
        var state: RecordingState?
        var toggles = 0
        var cancels = 0
        var held = false
        lazy var handler = RecordingShortcutModeHandler(
            canHandleShortcutAction: { self.state != .transcribing },
            isRecorderVisible: { self.visible },
            recordingState: { self.state ?? (self.visible ? .recording : .idle) },
            isShortcutHeld: { _ in self.held }, finishHeldRecording: {},
            toggleRecorderPanel: { _, _ in self.visible.toggle(); self.toggles += 1 },
            cancelRecording: { self.visible = false; self.cancels += 1 },
            now: { self.now }
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

@MainActor
private final class MonitorHarness {
    final class Events {
        var downs: [TimeInterval] = []
        var ups: [TimeInterval] = []
        var interruptions: [TimeInterval] = []
    }

    final class Breakers: Sendable {
        private let posted = OSAllocatedUnfairLock<[CGEventFlags]>(initialState: [])
        var flags: [CGEventFlags] { posted.withLock { $0 } }
        var count: Int { flags.count }
        func record(_ flags: CGEventFlags) { posted.withLock { $0.append(flags) } }
    }

    let sessionTap = FakeTap()
    let physicalTap = FakeTap()
    let events = Events()
    let breakers = Breakers()
    let monitor: ShortcutMonitor

    var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    init(
        shortcut: Shortcut,
        extraShortcuts: [ShortcutAction: Shortcut] = [:],
        standalone: Bool = false,
        chordBreakerDelay: TimeInterval? = nil,
        physicalFlags: CGEventFlags = .maskAlternate,
        physicalTapAvailable: Bool = true
    ) {
        let sessionTap = sessionTap
        let physicalTap = physicalTap
        let breakers = breakers
        monitor = ShortcutMonitor(
            makeEventTap: { _, handler in sessionTap.handler = handler; return sessionTap },
            allowsInput: { true }, allowsDispatch: { true }, isSecureEventInputEnabled: { false },
            makePhysicalKeyTap: { handler in
                guard physicalTapAvailable else { throw ShortcutEventTapError.creationFailed }
                physicalTap.handler = handler
                return physicalTap
            },
            physicalModifierFlags: { physicalFlags },
            postChordBreaker: { breakers.record($0); return true }
        )
        let events = events
        var shortcuts = extraShortcuts
        shortcuts[.primaryRecording] = shortcut
        monitor.start(
            shortcuts: shortcuts,
            interruptibleActions: [.primaryRecording],
            standaloneModifierActions: standalone ? [.primaryRecording] : [],
            chordBreakerDelays: chordBreakerDelay.map { [.primaryRecording: $0] } ?? [:],
            onShortcutDown: { action, time in if action == .primaryRecording { events.downs.append(time) } },
            onShortcutUp: { action, time in if action == .primaryRecording { events.ups.append(time) } },
            onShortcutInterrupted: { _, pressedAt in events.interruptions.append(pressedAt) }
        )
    }

    isolated deinit {
        monitor.stop()
    }

    func modifier(down: Bool, at time: TimeInterval, key: UInt16 = UInt16(kVK_Option), flags: NSEvent.ModifierFlags = [.option]) {
        session(.flagsChanged, key: key, flags: down ? flags : [], at: time)
    }

    func session(_ type: CGEventType, key: UInt16, flags: NSEvent.ModifierFlags, at time: TimeInterval, sourcePID: Int32 = 0) {
        let event = Self.event(key: key, down: type != .keyUp, flags: flags, at: time, sourcePID: sourcePID)
        _ = deliver(type, event)
    }

    func physical(key: UInt16, flags: NSEvent.ModifierFlags, at time: TimeInterval, sourcePID: Int32 = 0, marked: Bool = false) {
        let event = Self.event(key: key, down: true, flags: flags, at: time, sourcePID: sourcePID)
        if marked { event.setIntegerValueField(.eventSourceUserData, value: ChordBreaker.eventMarker) }
        physical(event)
    }

    func physical(_ event: CGEvent) {
        let physicalTap = physicalTap
        ShortcutEventTapThread.shared.performAndWait { _ = physicalTap.handler?(.keyDown, event) }
    }

    func deliver(_ type: CGEventType, _ event: CGEvent) -> Bool {
        let sessionTap = sessionTap
        return ShortcutEventTapThread.shared.performAndWait { sessionTap.handler?(type, event) ?? false }
    }

    /// Lets queued main-actor dispatches run.
    func drain() async {
        for _ in 0..<3 {
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { Task { @MainActor in continuation.resume() } }
            }
        }
    }

    private static func event(key: UInt16, down: Bool, flags: NSEvent.ModifierFlags, at time: TimeInterval, sourcePID: Int32) -> CGEvent {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: down)!
        event.flags = CGEventFlags(rawValue: UInt64(flags.rawValue))
        event.timestamp = UInt64((time * 1_000_000_000).rounded())
        // Hardware events carry no source process.
        event.setIntegerValueField(.eventSourceUnixProcessID, value: Int64(sourcePID))
        return event
    }
}

private final class FakeTap: ShortcutEventTap, @unchecked Sendable {
    var handler: (@Sendable (CGEventType, CGEvent) -> Bool)?
    var isValid = true
    var isEnabled = true
    func enable() { isEnabled = true }
    func stop() { isEnabled = false; isValid = false }
}
