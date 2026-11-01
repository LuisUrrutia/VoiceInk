import AppKit
import SwiftUI

@MainActor
final class SystemAudioRecordingPermissionModel: ObservableObject {
    @Published private(set) var authorization: SystemAudioRecordingAuthorization
    @Published private(set) var isWaitingForAnswer = false
    private let permission: any SystemAudioRecordingPermissionChecking
    private let answerTimeout: Duration
    private var waitTimeout: Task<Void, Never>?

    init(
        permission: any SystemAudioRecordingPermissionChecking = TCCSystemAudioRecordingPermission(),
        answerTimeout: Duration = .seconds(30)
    ) {
        self.permission = permission
        self.answerTimeout = answerTimeout
        authorization = permission.authorization()
    }

    func refresh() {
        authorization = permission.authorization()
        if authorization != .notDetermined { stopWaiting() }
    }

    /// macOS may show no prompt (observed for an ad-hoc Debug build), so returning to
    /// VoiceInk or the timeout offers Allow again instead of waiting forever.
    func applicationDidBecomeActive() {
        stopWaiting()
        refresh()
    }

    /// Asks only from the settings control, never while dictating.
    func requestIfUndetermined() {
        refresh()
        guard !isWaitingForAnswer else { return }
        let asked = permission.request { [weak self] _ in
            Task { @MainActor in
                self?.stopWaiting()
                self?.refresh()
            }
        }
        isWaitingForAnswer = asked
        guard asked else { return }
        waitTimeout = Task { [weak self, answerTimeout] in
            try? await Task.sleep(for: answerTimeout)
            guard !Task.isCancelled else { return }
            self?.applicationDidBecomeActive()
        }
    }

    private func stopWaiting() {
        waitTimeout?.cancel()
        waitTimeout = nil
        isWaitingForAnswer = false
    }
}

@MainActor
struct BrowserMediaPausingSettingsView: View {
    @ObservedObject var playbackController: PlaybackController
    @StateObject private var permission = SystemAudioRecordingPermissionModel()

    var body: some View {
        Toggle(isOn: isEnabled) {
            HStack(spacing: 4) {
                Text("Also Pause the Browser")
                InfoTip(
                    LocalizedStringKey(
                        "Pause a browser tab that is audibly playing, and play it again after dictation only if VoiceInk paused it and you did not restart it. Browsers using the microphone, such as calls, are left alone. VoiceInk listens to the browser's own output without recording it, which requires Screen & System Audio Recording permission."
                    )
                )
            }
        }
        .disabled(!playbackController.isPauseMediaEnabled)

        if playbackController.isPauseMediaEnabled && playbackController.isPauseBrowserMediaEnabled {
            LabeledContent("Screen & System Audio Recording") {
                permissionStatus
            }
            .onAppear { permission.refresh() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                permission.applicationDidBecomeActive()
            }
        }
    }

    private var isEnabled: Binding<Bool> {
        Binding(
            get: { playbackController.isPauseBrowserMediaEnabled },
            set: { enabled in
                playbackController.isPauseBrowserMediaEnabled = enabled
                if enabled { permission.requestIfUndetermined() }
            }
        )
    }

    @ViewBuilder
    private var permissionStatus: some View {
        switch permission.authorization {
        case .granted:
            Text("Allowed").foregroundStyle(.secondary)
        case .notDetermined where permission.isWaitingForAnswer:
            Text("Waiting for your answer…").foregroundStyle(.secondary)
        case .notDetermined:
            Button("Allow") { permission.requestIfUndetermined() }
        case .denied:
            Button("Open System Settings") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                    NSWorkspace.shared.open(url)
                }
            }
            .help("Allow VoiceInk under System Audio Recording Only, then return to VoiceInk.")
        case .unknown:
            Text("Unavailable on this Mac").foregroundStyle(.secondary)
                .help("VoiceInk cannot check this permission, so it leaves the browser alone.")
        }
    }
}
