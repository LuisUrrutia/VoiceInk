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
    @StateObject private var permission: SystemAudioRecordingPermissionModel

    init(playbackController: PlaybackController, permission: SystemAudioRecordingPermissionModel? = nil) {
        self.playbackController = playbackController
        _permission = StateObject(wrappedValue: permission ?? SystemAudioRecordingPermissionModel())
    }

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
        // On the toggle, which always exists: the notice is absent while the permission is granted.
        .onAppear { if needsPermission { permission.refresh() } }
        // Turning Pause Media back on can follow a change made in System Settings while it was off.
        .onChange(of: needsPermission) { _, needs in if needs { permission.refresh() } }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if needsPermission { permission.applicationDidBecomeActive() }
        }

        if needsPermission {
            permissionNotice
        }
    }

    private var needsPermission: Bool {
        playbackController.isPauseMediaEnabled && playbackController.isPauseBrowserMediaEnabled
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

    /// Shown only while the permission is missing; a granted permission needs no row.
    @ViewBuilder
    private var permissionNotice: some View {
        if let message = permissionMessage {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Label(message, appSymbol: "exclamationmark.triangle")
                    .frame(maxWidth: .infinity, alignment: .leading)
                permissionAction
            }
        }
    }

    private var permissionMessage: LocalizedStringKey? {
        Self.permissionMessage(for: permission.authorization, isWaitingForAnswer: permission.isWaitingForAnswer)
    }

    static func permissionMessage(
        for authorization: SystemAudioRecordingAuthorization, isWaitingForAnswer: Bool
    ) -> LocalizedStringKey? {
        switch authorization {
        case .granted: nil
        case .notDetermined where isWaitingForAnswer:
            "Waiting for your answer to the Screen & System Audio Recording request…"
        case .notDetermined: "Pausing the browser needs Screen & System Audio Recording permission."
        case .denied: "Screen & System Audio Recording is denied, so VoiceInk leaves the browser alone."
        case .unknown: "VoiceInk cannot check Screen & System Audio Recording on this Mac, so it leaves the browser alone."
        }
    }

    @ViewBuilder
    private var permissionAction: some View {
        switch permission.authorization {
        case .notDetermined where !permission.isWaitingForAnswer:
            Button("Allow") { permission.requestIfUndetermined() }
        case .denied:
            Button("Open System Settings") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                    NSWorkspace.shared.open(url)
                }
            }
            .help("Allow VoiceInk under System Audio Recording Only, then return to VoiceInk.")
        case .granted, .notDetermined, .unknown:
            EmptyView()
        }
    }
}
