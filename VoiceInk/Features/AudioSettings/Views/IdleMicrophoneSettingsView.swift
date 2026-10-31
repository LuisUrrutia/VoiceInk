import AppKit
import SwiftUI

@MainActor
struct IdleMicrophoneSettingsView: View {
    @ObservedObject var recorder: Recorder
    @AppStorage(UserDefaults.Keys.keepMicrophoneReady) private var keepMicrophoneReady = false

    var body: some View {
        LabeledContent {
            Picker("Idle Microphone", selection: $keepMicrophoneReady) {
                Text("Release When Idle").tag(false)
                Text("Keep Ready").tag(true)
            }
            .labelsHidden()
        } label: {
            HStack(spacing: 4) {
                Text("Idle Microphone")
                InfoTip(
                    "Keep Ready starts recording without waiting for the microphone and includes up to 0.45 seconds spoken before the shortcut. The microphone stays open while VoiceInk is idle: the macOS microphone indicator stays on, battery use increases, and Bluetooth headsets stay in their lower-quality call mode. Idle audio stays only in memory and is never saved.\n\nKeep Ready requires active global shortcut monitoring, which may need Accessibility permission, and pauses during Secure Input.")
            }
        }
        .pickerStyle(.menu)

        if keepMicrophoneReady && !recorder.hasPreRollObserver {
            Text("Keep Ready is paused because shortcut monitoring is unavailable. Configure a recording shortcut in Settings and allow Accessibility if needed. Recording opens the microphone on demand without pre-roll.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open Accessibility Settings") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }
}
