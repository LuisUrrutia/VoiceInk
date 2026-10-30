import AppKit
import Carbon
import Testing
@testable import VoiceInk

@Suite(.serialized)
struct SystemHotKeyTests {
    @Test func optionSpaceUsesSystemRegistration() {
        let shortcut = Shortcut.key(keyCode: UInt16(kVK_Space), modifierFlags: [.option])

        #expect(shortcut.systemHotKeyModifiers == UInt32(optionKey))
    }

    @Test func functionKeyNormalizesItsImplicitFnFlag() {
        let shortcut = Shortcut.key(keyCode: UInt16(kVK_F5), modifierFlags: [.function, .control])

        #expect(shortcut.systemHotKeyModifiers == UInt32(controlKey))
    }

    @Test func unsupportedInputsKeepTheirEventTapRoute() {
        let shortcuts: [Shortcut] = [
            .key(keyCode: UInt16(kVK_Space), modifierFlags: [.function]),
            .rightCommand,
            .mouseButton(buttonNumber: 3, modifierFlags: [.option]),
        ]

        #expect(shortcuts.allSatisfy { $0.systemHotKeyModifiers == nil })
    }

    @Test func unmodifiedEscapeCanCancelTheRecorder() {
        let shortcut = Shortcut.key(keyCode: UInt16(kVK_Escape), modifierFlags: [])

        #expect(shortcut.systemHotKeyModifiers == 0)
    }

    @Test @MainActor func releasingARegistrationAllowsTheShortcutToBeReused() {
        let keyCode = UInt16(kVK_F19)
        let modifiers = UInt32(controlKey | optionKey | cmdKey)
        var first = SystemHotKey(keyCode: keyCode, modifiers: modifiers) { _, _ in }
        #expect(first != nil)
        withExtendedLifetime(first) {
            let duplicate = SystemHotKey(keyCode: keyCode, modifiers: modifiers) { _, _ in }
            #expect(duplicate == nil)
        }

        first = nil
        let replacement = SystemHotKey(keyCode: keyCode, modifiers: modifiers) { _, _ in }

        #expect(replacement != nil)
        withExtendedLifetime(replacement) {}
    }

    @Test @MainActor func incompleteMonitorStartKeepsSuccessfulRegistrationsForTapRecovery() {
        let monitor = ShortcutMonitor(makeEventTap: Self.unavailableEventTap)
        let keyCode = UInt16(kVK_F18)
        let modifiers = UInt32(controlKey | optionKey | cmdKey)

        let started = monitor.start(
            shortcuts: [
                .primaryRecording: .key(keyCode: keyCode, modifierFlags: [.control, .option, .command]),
                .secondaryRecording: .rightCommand,
            ],
            onShortcutDown: { _, _ in },
            onShortcutUp: { _, _ in }
        )
        let duplicate = SystemHotKey(keyCode: keyCode, modifiers: modifiers) { _, _ in }

        #expect(!started)
        #expect(monitor.isMonitoring(.primaryRecording))
        #expect(!monitor.isMonitoring(.secondaryRecording))
        #expect(duplicate == nil)
        monitor.stop()
        let replacement = SystemHotKey(keyCode: keyCode, modifiers: modifiers) { _, _ in }
        #expect(replacement != nil)
        withExtendedLifetime((monitor, replacement)) {}
    }

    @Test @MainActor func fullyRegisteredMonitorHoldsItsRegistrationWithoutAnEventTap() {
        let monitor = ShortcutMonitor(makeEventTap: Self.unavailableEventTap)
        let keyCode = UInt16(kVK_F18)
        let modifiers = UInt32(controlKey | optionKey | cmdKey)

        let started = monitor.start(
            shortcuts: [.primaryRecording: .key(keyCode: keyCode, modifierFlags: [.control, .option, .command])],
            onShortcutDown: { _, _ in },
            onShortcutUp: { _, _ in }
        )
        let duplicate = SystemHotKey(keyCode: keyCode, modifiers: modifiers) { _, _ in }

        #expect(started)
        #expect(duplicate == nil)
        withExtendedLifetime(monitor) {}
    }

    @Test @MainActor func eventTapInterruptionDoesNotReleaseSystemHotKey() async {
        let recorder = TransitionRecorder()
        let monitor = ShortcutMonitor(
            makeEventTap: Self.unavailableEventTap,
            allowsInput: { true },
            allowsDispatch: { true }
        )
        let started = monitor.start(
            shortcuts: [.primaryRecording: .key(keyCode: UInt16(kVK_F18), modifierFlags: [.control, .option, .command])],
            onShortcutDown: { _, _ in recorder.transitions.append("down") },
            onShortcutUp: { _, _ in recorder.transitions.append("up") }
        )
        #expect(started)
        guard started else { return }

        monitor.handleSystemHotKey(action: .primaryRecording, isDown: true, eventTime: 1)
        monitor.recoverEventTap(reason: "test-interruption")
        await flushDispatchedEvents()
        #expect(recorder.transitions == ["down"])

        monitor.handleSystemHotKey(action: .primaryRecording, isDown: false, eventTime: 2)
        await flushDispatchedEvents()
        #expect(recorder.transitions == ["down", "up"])
    }

    @Test @MainActor func systemHotKeyResetsAtLockedSessionBoundary() async {
        let recorder = TransitionRecorder()
        let session = TestSession()
        let monitor = ShortcutMonitor(
            makeEventTap: Self.unavailableEventTap,
            allowsInput: { session.allowsShortcuts },
            allowsDispatch: { session.allowsShortcuts }
        )
        let started = monitor.start(
            shortcuts: [.primaryRecording: .key(keyCode: UInt16(kVK_F18), modifierFlags: [.control, .option, .command])],
            onShortcutDown: { _, _ in recorder.transitions.append("down") },
            onShortcutUp: { _, _ in recorder.transitions.append("up") },
            onMonitoringReset: { _ in recorder.transitions.append("reset") }
        )
        #expect(started)
        guard started else { return }

        monitor.handleSystemHotKey(action: .primaryRecording, isDown: true, eventTime: 1)
        await flushDispatchedEvents()
        session.allowsShortcuts = false
        monitor.handleSystemHotKey(action: .primaryRecording, isDown: false, eventTime: 2)
        monitor.handleSystemHotKey(action: .primaryRecording, isDown: true, eventTime: 3)
        await flushDispatchedEvents()
        #expect(recorder.transitions == ["down", "reset"])

        session.allowsShortcuts = true
        monitor.handleSystemHotKey(action: .primaryRecording, isDown: true, eventTime: 4)
        monitor.handleSystemHotKey(action: .primaryRecording, isDown: false, eventTime: 5)
        await flushDispatchedEvents()
        #expect(recorder.transitions == ["down", "reset", "down", "up"])
    }

    private static let unavailableEventTap: ShortcutMonitor.EventTapFactory = { _, _ in
        throw ShortcutEventTapError.creationFailed
    }

    @MainActor private func flushDispatchedEvents() async {
        for _ in 0..<2 {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.main.async { continuation.resume() }
            }
            await Task.yield()
        }
    }

    private final class TransitionRecorder {
        var transitions: [String] = []
    }

    private final class TestSession {
        var allowsShortcuts = true
    }
}
