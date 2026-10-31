import AppKit
import CoreAudio
import CoreGraphics
import Carbon.HIToolbox
import XCTest
import os

@testable import VoiceInk

@MainActor
final class MicrophoneBoundaryTests: XCTestCase {
    func testRecordingShortcutHoldsAudioBeforeMainThreadDispatch() async throws {
        try await checkDelayedDispatch(action: .primaryRecording)
    }

    func testModeShortcutHoldsAudioBeforeMainThreadDispatch() async throws {
        try await checkDelayedDispatch(action: .mode(UUID()))
    }

    func testStandaloneModifierHoldsAudioBeforeItsRelease() async throws {
        try await checkDelayedDispatch(action: .primaryRecording, gesture: .modifier)
    }

    func testSystemHotKeyHoldsAudioOnTheTapBeforeCarbonDispatch() async throws {
        try await checkDelayedDispatch(action: .primaryRecording, gesture: .systemKey)
    }

    private enum Gesture { case mouse, modifier, systemKey }

    func testSecureInputPausesPreRollEvenWhenTheTapIsEnabled() {
        let tap = BoundaryTap()
        var secureInput = false
        let monitor = ShortcutMonitor(
            makeEventTap: { _, handler in tap.handler = handler; return tap },
            isSecureEventInputEnabled: { secureInput }
        )
        monitor.start(shortcuts: [.primaryRecording: .rightCommand],
                      onShortcutDown: { _, _ in }, onShortcutUp: { _, _ in })
        defer { monitor.stop() }
        XCTAssertEqual(monitor.earlyCaptureAvailability(for: [.primaryRecording]), true)

        secureInput = true

        XCTAssertTrue(monitor.isMonitoring(.primaryRecording))
        XCTAssertEqual(monitor.earlyCaptureAvailability(for: [.primaryRecording]), false)
        secureInput = false
        XCTAssertEqual(monitor.earlyCaptureAvailability(for: [.primaryRecording]), true)
    }

    private func checkDelayedDispatch(action: ShortcutAction, gesture: Gesture = .mouse) async throws {
        let tap = BoundaryTap()
        let hardware = BoundaryHardware()
        let press = RecordingPreRollPress()
        press.bind(hardware)
        hardware.append(frames: 0..<1_000)
        let delivered = expectation(description: "Shortcut delivered")
        var receivedTime: TimeInterval?
        let monitor = ShortcutMonitor(
            makeEventTap: { _, handler in tap.handler = handler; return tap },
            allowsInput: { true }, allowsDispatch: { true }, isSecureEventInputEnabled: { false }
        )
        let shortcut: Shortcut
        switch gesture {
        case .mouse: shortcut = .mouseButton(buttonNumber: 3)
        case .modifier: shortcut = .rightCommand
        case .systemKey: shortcut = .key(keyCode: UInt16(kVK_F20), modifierFlags: [.control, .option, .command])
        }
        monitor.start(
            shortcuts: [action: shortcut], standaloneModifierActions: gesture == .modifier ? [action] : [],
            onShortcutDown: { _, eventTime in receivedTime = eventTime; delivered.fulfill() },
            onShortcutUp: { _, _ in },
            onPressCaptured: { _, eventTime in press.hold(at: eventTime) }
        )
        XCTAssertEqual(monitor.earlyCaptureAvailability(for: [action]), true)
        defer { monitor.stop() }
        let event: CGEvent
        let type: CGEventType
        switch gesture {
        case .mouse:
            event = try XCTUnwrap(CGEvent(mouseEventSource: nil, mouseType: .otherMouseDown,
                                         mouseCursorPosition: .zero, mouseButton: .center))
            event.setIntegerValueField(.mouseEventButtonNumber, value: 3)
            type = .otherMouseDown
        case .modifier, .systemKey:
            event = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: shortcut.keyCode, keyDown: true))
            event.flags = CGEventFlags(rawValue: UInt64(shortcut.modifierFlags.rawValue))
            type = gesture == .modifier ? .flagsChanged : .keyDown
        }
        event.timestamp = 11_000_000_000

        ShortcutEventTapThread.shared.performAndWait { _ = tap.handler?(type, event) }
        XCTAssertNil(receivedTime)
        hardware.append(frames: 1_000..<1_300)
        if gesture == .modifier {
            event.flags = []
            event.timestamp = 11_300_000_000
            ShortcutEventTapThread.shared.performAndWait { _ = tap.handler?(.flagsChanged, event) }
        } else if gesture == .systemKey {
            monitor.handleSystemHotKey(action: action, isDown: true, eventTime: 11)
        }
        await fulfillment(of: [delivered], timeout: 2)

        XCTAssertEqual(receivedTime, 11)
        XCTAssertEqual(hardware.take(), (550..<1_300).map(Float.init))
    }

    func testFirstHardwareAudioKeepsCallbackTimeAcrossSoftwareAttachment() {
        let timestamp = RecordingFirstAudioTimestamp()
        timestamp.capture(at: 90)
        XCTAssertNil(timestamp.nanoseconds)
        timestamp.arm(at: 100)

        timestamp.capture(at: 99)
        XCTAssertNil(timestamp.nanoseconds)
        timestamp.capture(at: 105)
        let trace = RecordingTimingTrace(originNanoseconds: 100, requestReceivedNanoseconds: 150)
        trace.mark(.firstAudio, at: timestamp.nanoseconds)
        trace.mark(.audioStarted, at: 200)
        timestamp.capture(at: 210)
        timestamp.disarm()
        timestamp.capture(at: 220)

        XCTAssertEqual(timestamp.nanoseconds, 105)
        XCTAssertEqual(trace.snapshot.first { $0.phase == .shortcutPressed }?.elapsedNanoseconds, 0)
        XCTAssertEqual(trace.snapshot.first { $0.phase == .requestReceived }?.elapsedNanoseconds, 50)
        XCTAssertEqual(trace.snapshot.first { $0.phase == .firstAudio }?.elapsedNanoseconds, 5)
        XCTAssertEqual(trace.snapshot.first { $0.phase == .audioStarted }?.elapsedNanoseconds, 100)
        timestamp.arm(at: 300)
        timestamp.capture(at: 305)
        XCTAssertEqual(timestamp.nanoseconds, 305)
    }
}

private final class BoundaryTap: ShortcutEventTap, @unchecked Sendable {
    var handler: (@Sendable (CGEventType, CGEvent) -> Bool)?
    var isValid = true
    var isEnabled = true
    func enable() { isEnabled = true }
    func stop() { isEnabled = false; isValid = false }
}

private final class BoundaryHardware: RecordingHardware, @unchecked Sendable {
    private struct State {
        var buffer = PreRollBuffer(sampleRate: 1_000, channelCount: 1)
        var press: UInt64?
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    var onAudioChunk: ((Data) -> Void)?
    let averagePower: Float = -160
    let peakPower: Float = -160

    func append(frames: Range<Int>) {
        state.withLock { state in
            for start in stride(from: frames.lowerBound, to: frames.upperBound, by: 10) {
                Array(start..<start + 10).map(Float.init).withUnsafeBufferPointer {
                    state.buffer.append($0, endNanoseconds: 10_000_000_000 + UInt64(start + 10) * 1_000_000,
                                        pendingPressNanoseconds: state.press)
                }
            }
        }
    }

    func take() -> [Float] {
        state.withLock { state in
            guard let press = state.press else { return [] }
            return state.buffer.take(pressNanoseconds: press)
        }
    }

    func holdPreRoll(forPressAt pressNanoseconds: UInt64) { state.withLock { $0.press = pressNanoseconds } }
    func prepare(deviceID: AudioDeviceID, selectedInputChannels: [UInt32]?) throws {}
    func startRecording(toOutputFile url: URL, deviceID: AudioDeviceID, selectedInputChannels: [UInt32]?) throws {}
    func stopRecording() {}
    func switchDevice(to deviceID: AudioDeviceID, selectedInputChannels: [UInt32]?) throws {}
    func invalidatePreparation() {}
    func teardown() {}
}
