import AppKit
import SwiftUI

@MainActor
struct IdleMicrophoneSettingsView: View {
    @ObservedObject var recorder: Recorder
    @AppStorage(UserDefaults.Keys.keepMicrophoneReady) private var keepMicrophoneReady = false

    var body: some View {
        LabeledContent("Idle Microphone") {
            Picker("Idle Microphone", selection: $keepMicrophoneReady) {
                Text("Release When Idle").tag(false)
                Text("Keep Ready").tag(true)
            }
            .labelsHidden()
        }
        .pickerStyle(.menu)

        Text(
            "Keep Ready starts recording without waiting for the microphone and includes up to 0.45 seconds spoken before the shortcut. The microphone stays open while VoiceInk is idle: the macOS microphone indicator stays on, battery use increases, and Bluetooth headsets stay in their lower-quality call mode. Idle audio stays only in memory and is never saved."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

        Text("Keep Ready requires active global shortcut monitoring. This may require Accessibility permission. Keep Ready pauses during Secure Input.")
            .font(.caption)
            .foregroundStyle(.secondary)

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
