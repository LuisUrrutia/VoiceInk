import AppKit
import SwiftUI

extension View {
    /// Polls permissions while this view is on screen and `isActive` holds.
    func livePermissionRefresh(isActive: Bool = true, monitor: PermissionMonitor? = nil) -> some View {
        modifier(LivePermissionRefreshModifier(isActive: isActive, monitor: monitor))
    }
}

private final class LivePermissionRefreshOwner: ObservableObject {}

private struct LivePermissionRefreshModifier: ViewModifier {
    let isActive: Bool
    let monitor: PermissionMonitor?
    @StateObject private var owner = LivePermissionRefreshOwner()
    @State private var isVisible = false
    @State private var isWindowShown = false

    func body(content: Content) -> some View {
        content
            .background(WindowPresenceReader { shown in
                isWindowShown = shown
                update()
            })
            .onAppear {
                isVisible = true
                update()
            }
            .onDisappear {
                isVisible = false
                update()
            }
            .onChange(of: isActive) { _, _ in update() }
    }

    private func update() {
        (monitor ?? .shared).setLiveRefresh(isVisible && isWindowShown && isActive, for: owner)
    }
}

extension EnvironmentValues {
    /// Whether a shown window is unobscured in the active app. Tests replace it: XCTest cannot activate its host app.
    @Entry var isWindowFrontmost: @MainActor (NSWindow) -> Bool = { window in
        NSApp.isActive && window.occlusionState.contains(.visible)
    }
}

extension View {
    /// Reports whether this view can be seen: it has appeared, part of it lies in its scroll view's visible area, and
    /// its window is shown (with `requiresFrontmost`, also unobscured in the active app). Settings forms keep rows
    /// mounted while they scroll away, so `onDisappear` alone misses that.
    func onScreenChange(requiresFrontmost: Bool = false, perform action: @escaping (Bool) -> Void) -> some View {
        modifier(OnScreenPresenceModifier(requiresFrontmost: requiresFrontmost, action: action))
    }
}

private struct OnScreenPresenceModifier: ViewModifier {
    let requiresFrontmost: Bool
    let action: (Bool) -> Void
    @State private var isAppeared = false
    @State private var isInScrollViewport = true
    @State private var isWindowShown = false
    @State private var reported: Bool?

    func body(content: Content) -> some View {
        content
            .background(WindowPresenceReader(requiresFrontmost: requiresFrontmost) { shown in
                isWindowShown = shown
                report()
            })
            .onScrollVisibilityChange(threshold: 0.01) { visible in
                isInScrollViewport = visible
                report()
            }
            .onAppear {
                isAppeared = true
                report()
            }
            .onDisappear {
                isAppeared = false
                report()
            }
    }

    private func report() {
        let shown = isAppeared && isInScrollViewport && isWindowShown
        guard shown != reported else { return }
        reported = shown
        action(shown)
    }
}

/// Reports whether the hosting window is on screen. SwiftUI keeps views of a closed retained window, or a minimized
/// one, without `onDisappear`. By default a covered window still counts: System Settings usually covers it during a
/// grant. `requiresFrontmost` also requires an unobscured window in the active app, for work that should stop as soon
/// as the user looks elsewhere.
struct WindowPresenceReader: NSViewRepresentable {
    var requiresFrontmost = false
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> PresenceView {
        let view = PresenceView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: PresenceView, context: Context) {
        view.requiresFrontmost = requiresFrontmost
        view.isFrontmost = context.environment.isWindowFrontmost
        view.onChange = onChange
    }

    final class PresenceView: NSView {
        var requiresFrontmost = false
        var isFrontmost: @MainActor (NSWindow) -> Bool = { _ in true }
        var onChange: ((Bool) -> Void)?
        private var observers: [NSObjectProtocol] = []
        private var lastReported: Bool?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let window else {
                report(false)
                return
            }
            let names: [Notification.Name] = [
                NSWindow.didChangeOcclusionStateNotification, NSWindow.willCloseNotification,
                NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification,
                // Posted to on-screen windows as AppKit updates them, so a reshown window is noticed without a key change.
                NSWindow.didBecomeKeyNotification, NSWindow.didUpdateNotification,
            ]
            for name in names {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) {
                    [weak self] notification in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.report(notification.name != NSWindow.willCloseNotification && self.isWindowShown)
                    }
                })
            }
            // WindowManager reopens the retained window by activating the app and making it key.
            for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) {
                    [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.report(self.isWindowShown)
                    }
                })
            }
            report(isWindowShown)
        }

        private var isWindowShown: Bool {
            guard let window, window.isVisible, !window.isMiniaturized else { return false }
            return !requiresFrontmost || isFrontmost(window)
        }

        private func report(_ shown: Bool) {
            guard shown != lastReported else { return }
            lastReported = shown
            // Outside the view update that moved this view into its window.
            DispatchQueue.main.async { [onChange] in onChange?(shown) }
        }

        deinit {
            observers.forEach(NotificationCenter.default.removeObserver)
        }
    }
}

/// Relaunch action for a grant that only a new VoiceInk process can use.
struct RestartVoiceInkButton: View {
    @ObservedObject var engine: VoiceInkEngine
    @ObservedObject private var diagnostic: MicrophoneDiagnostic

    init(engine: VoiceInkEngine) {
        self.engine = engine
        self.diagnostic = engine.microphoneDiagnostic
    }

    var body: some View {
        let relauncher = engine.relauncher
        Button("Restart VoiceInk") { relauncher.relaunch() }
            .disabled(!relauncher.canRelaunch)
            .help(
                relauncher.canRelaunch
                    ? String(localized: "Quit and reopen VoiceInk")
                    : String(localized: "Available when the current recording or microphone test finishes")
            )
    }
}
