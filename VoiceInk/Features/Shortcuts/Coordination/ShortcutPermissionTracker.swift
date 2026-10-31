import ApplicationServices
import Combine
import Foundation

/// Restarts shortcut monitoring when Accessibility changes, and keeps recording-shortcut availability
/// current when a monitor's taps change, so a live grant needs neither activation nor the health check.
@MainActor
final class ShortcutPermissionTracker {
    struct Availability {
        var isMonitoring: @MainActor () -> Bool
        var hasShortcut: @MainActor () -> Bool
        var publish: @MainActor (RecordingHotkeyAvailability) -> Void
    }

    private let permissionMonitor: PermissionMonitor
    private let accessibilityTrusted: () -> Bool
    private let availability: Availability?
    private var subscriptions: Set<AnyCancellable> = []

    init(
        permissionMonitor: PermissionMonitor,
        notificationCenter: NotificationCenter = .default,
        accessibilityTrusted: @escaping () -> Bool = { AXIsProcessTrusted() },
        refreshMonitoring: @escaping @MainActor () -> Void,
        availability: Availability? = nil
    ) {
        self.permissionMonitor = permissionMonitor
        self.accessibilityTrusted = accessibilityTrusted
        self.availability = availability
        permissionMonitor.observeAccessibilityChanges { _ in refreshMonitoring() }
            .store(in: &subscriptions)
        guard availability != nil else { return }
        notificationCenter.publisher(for: ShortcutMonitor.captureAvailabilityDidChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.updateAvailability() } }
            .store(in: &subscriptions)
    }

    func updateAvailability() {
        guard let availability else { return }
        availability.publish(
            RecordingHotkeyAvailability.resolve(
                isMonitoring: availability.isMonitoring(),
                hasShortcut: availability.hasShortcut(),
                accessibilityTrusted: accessibilityTrusted(),
                accessibilityGrantedSinceLaunch: permissionMonitor.hasObservedUntrustedAccessibility
            )
        )
    }
}
