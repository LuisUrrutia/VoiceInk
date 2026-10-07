import AppKit
import Carbon
import Testing
@testable import VoiceInk

@Suite(.serialized)
@MainActor
struct ShortcutMonitoringLifecycleTests {
    @Test func refreshWaitsForLaunchCompletion() {
        let notificationCenter = NotificationCenter()
        let lifecycle = ShortcutMonitoringLifecycle(
            notificationCenter: notificationCenter,
            hasFinishedLaunching: false
        )
        var refreshCount = 0

        lifecycle.refreshWhenReady { refreshCount += 1 }
        #expect(refreshCount == 0)

        notificationCenter.post(name: NSApplication.didFinishLaunchingNotification, object: nil)

        #expect(refreshCount == 1)
    }

    @Test func launchUsesOnlyTheLatestPendingRefresh() {
        let notificationCenter = NotificationCenter()
        let lifecycle = ShortcutMonitoringLifecycle(
            notificationCenter: notificationCenter,
            hasFinishedLaunching: false
        )
        var refreshedShortcuts: [Shortcut] = []
        var selectedShortcut = Shortcut.rightCommand
        lifecycle.refreshWhenReady { refreshedShortcuts.append(.rightCommand) }

        let replacement = Shortcut.key(keyCode: UInt16(kVK_F20), modifierFlags: [.control, .option, .command])
        selectedShortcut = replacement
        lifecycle.refreshWhenReady { refreshedShortcuts.append(selectedShortcut) }
        #expect(refreshedShortcuts.isEmpty)
        notificationCenter.post(name: NSApplication.didFinishLaunchingNotification, object: nil)

        #expect(refreshedShortcuts == [replacement])
    }

    @Test func defaultReadinessUsesTheCurrentApplicationLaunchState() {
        let notificationCenter = NotificationCenter()
        let hasFinishedLaunching = NSRunningApplication.current.isFinishedLaunching
        let lifecycle = ShortcutMonitoringLifecycle(notificationCenter: notificationCenter)
        var didRefresh = false

        lifecycle.refreshWhenReady { didRefresh = true }

        #expect(didRefresh == hasFinishedLaunching)
    }

    @Test func systemRegistrationWaitsForLaunchAndUsesTheLatestShortcut() {
        let notificationCenter = NotificationCenter()
        let lifecycle = ShortcutMonitoringLifecycle(
            notificationCenter: notificationCenter,
            hasFinishedLaunching: false
        )
        let monitor = ShortcutMonitor(createEventTap: { _, _ in nil })
        let modifiers = UInt32(controlKey | optionKey | cmdKey)
        let initialKeyCode = UInt16(kVK_F20)
        let latestKeyCode = UInt16(kVK_F17)
        var keyCode = initialKeyCode
        var didStart = false
        let refresh = {
            didStart = monitor.start(
                shortcuts: [.primaryRecording: .key(keyCode: keyCode, modifierFlags: [.control, .option, .command])],
                onShortcutDown: { _, _ in },
                onShortcutUp: { _, _ in }
            )
        }
        lifecycle.refreshWhenReady(refresh)

        keyCode = latestKeyCode
        lifecycle.refreshWhenReady(refresh)
        #expect(!didStart)
        #expect(isShortcutAvailable(keyCode: latestKeyCode, modifiers: modifiers))
        notificationCenter.post(name: NSApplication.didFinishLaunchingNotification, object: nil)

        #expect(didStart)
        #expect(isShortcutAvailable(keyCode: initialKeyCode, modifiers: modifiers))
        #expect(!isShortcutAvailable(keyCode: latestKeyCode, modifiers: modifiers))

        keyCode = initialKeyCode
        lifecycle.refreshWhenReady(refresh)

        #expect(didStart)
        #expect(isShortcutAvailable(keyCode: latestKeyCode, modifiers: modifiers))
        #expect(!isShortcutAvailable(keyCode: initialKeyCode, modifiers: modifiers))
        monitor.stop()
        #expect(isShortcutAvailable(keyCode: initialKeyCode, modifiers: modifiers))
    }

    @Test func lateCreatedLifecycleRefreshesImmediately() {
        let notificationCenter = NotificationCenter()
        let lifecycle = ShortcutMonitoringLifecycle(
            notificationCenter: notificationCenter,
            hasFinishedLaunching: true
        )
        var refreshCount = 0

        lifecycle.refreshWhenReady { refreshCount += 1 }
        lifecycle.refreshWhenReady { refreshCount += 1 }
        notificationCenter.post(name: NSApplication.didFinishLaunchingNotification, object: nil)

        #expect(refreshCount == 2)
    }

    @Test func refreshesAfterLaunchDoNotWaitOrRepeatInitialSetup() {
        let notificationCenter = NotificationCenter()
        let lifecycle = ShortcutMonitoringLifecycle(
            notificationCenter: notificationCenter,
            hasFinishedLaunching: false
        )
        var refreshCount = 0
        lifecycle.refreshWhenReady { refreshCount += 1 }

        notificationCenter.post(name: NSApplication.didFinishLaunchingNotification, object: nil)
        lifecycle.refreshWhenReady { refreshCount += 1 }
        notificationCenter.post(name: NSApplication.didFinishLaunchingNotification, object: nil)

        #expect(refreshCount == 2)
    }

    @Test func releasedLifecycleDoesNotRunPendingRefresh() {
        let notificationCenter = NotificationCenter()
        var lifecycle: ShortcutMonitoringLifecycle? = ShortcutMonitoringLifecycle(
            notificationCenter: notificationCenter,
            hasFinishedLaunching: false
        )
        weak var releasedLifecycle = lifecycle
        var refreshCount = 0
        lifecycle?.refreshWhenReady { refreshCount += 1 }

        lifecycle = nil
        notificationCenter.post(name: NSApplication.didFinishLaunchingNotification, object: nil)

        #expect(releasedLifecycle == nil)
        #expect(refreshCount == 0)
    }

    private func isShortcutAvailable(keyCode: UInt16, modifiers: UInt32) -> Bool {
        let registration = SystemHotKey(keyCode: keyCode, modifiers: modifiers) { _, _ in }
        return registration != nil
    }
}
