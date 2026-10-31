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

    func body(content: Content) -> some View {
        content
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
        (monitor ?? .shared).setLiveRefresh(isVisible && isActive, for: owner)
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
