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

/// Reports whether the hosting window is on screen. SwiftUI keeps views of a closed retained window, or a minimized
/// one, without `onDisappear`. A covered window still counts: System Settings usually covers it during a grant.
private struct WindowPresenceReader: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> PresenceView {
        let view = PresenceView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: PresenceView, context: Context) {
        view.onChange = onChange
    }

    final class PresenceView: NSView {
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
                        guard let self, let window = self.window else { return }
                        let closing = notification.name == NSWindow.willCloseNotification
                        self.report(!closing && window.isVisible && !window.isMiniaturized)
                    }
                })
            }
            // WindowManager reopens the retained window by activating the app and making it key.
            observers.append(NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let window = self.window else { return }
                    self.report(window.isVisible && !window.isMiniaturized)
                }
            })
            report(window.isVisible && !window.isMiniaturized)
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
