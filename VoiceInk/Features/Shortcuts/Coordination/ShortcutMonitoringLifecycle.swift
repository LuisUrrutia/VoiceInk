import AppKit
import Foundation

@MainActor
final class ShortcutMonitoringLifecycle {
    private let notificationCenter: NotificationCenter
    private var launchObserver: NSObjectProtocol?
    private var hasFinishedLaunching: Bool
    private var pendingRefresh: (() -> Void)?

    init(
        notificationCenter: NotificationCenter = .default,
        hasFinishedLaunching: Bool = NSRunningApplication.current.isFinishedLaunching
    ) {
        self.notificationCenter = notificationCenter
        self.hasFinishedLaunching = hasFinishedLaunching

        guard !hasFinishedLaunching else { return }
        launchObserver = notificationCenter.addObserver(
            forName: NSApplication.didFinishLaunchingNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.applicationDidFinishLaunching()
            }
        }
    }

    func refreshWhenReady(_ refresh: @escaping () -> Void) {
        guard hasFinishedLaunching else {
            pendingRefresh = refresh
            return
        }
        refresh()
    }

    private func applicationDidFinishLaunching() {
        hasFinishedLaunching = true
        if let launchObserver {
            notificationCenter.removeObserver(launchObserver)
            self.launchObserver = nil
        }
        let refresh = pendingRefresh
        pendingRefresh = nil
        refresh?()
    }

    deinit {
        if let launchObserver {
            notificationCenter.removeObserver(launchObserver)
        }
    }
}
