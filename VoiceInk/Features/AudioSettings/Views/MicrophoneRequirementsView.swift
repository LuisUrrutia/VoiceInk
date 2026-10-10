import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct MicrophoneRequirementsView: View {
    @ObservedObject var devices: AudioDeviceManager
    let microphone: PrioritizedDevice
    @Environment(\.dismiss) private var dismiss
    @State private var requirements: MicrophoneRequirements
    @State private var applicationError: String?

    init(devices: AudioDeviceManager, microphone: PrioritizedDevice) {
        self.devices = devices
        self.microphone = microphone
        _requirements = State(initialValue: microphone.requirements ?? MicrophoneRequirements())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Microphone Requirements").font(.headline)
            Text(microphone.name).foregroundStyle(.secondary)

            Form {
                Picker("Required Microphone", selection: requiredMicrophone) {
                    Text("None").tag("")
                    if let saved = requirements.microphone,
                        !devices.availableDevices.contains(where: { $0.uid == saved.uid })
                    {
                        Text("\(saved.name) (Unavailable)").tag(saved.uid)
                    }
                    ForEach(devices.availableDevices.filter { $0.uid != microphone.id }, id: \.uid) { device in
                        Text(device.name).tag(device.uid)
                    }
                }
                LabeledContent("Required Application", value: requirements.application?.name ?? String(localized: "None"))
                HStack {
                    Button("Choose Application…", action: chooseApplication)
                    if requirements.application != nil {
                        Button("Clear Application") { requirements.application = nil }
                    }
                }
                if let applicationError {
                    Text(applicationError).foregroundStyle(.red)
                }
            }

            Text("VoiceInk uses this microphone only when the required microphone is available and the required application is open. An open application may still have its audio processing stopped.")
                .font(.caption).foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    devices.updateMicrophoneRequirements(requirements, for: microphone.id)
                    dismiss()
                }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 460)
    }

    private var requiredMicrophone: Binding<String> {
        Binding(
            get: { requirements.microphone?.uid ?? "" },
            set: { uid in
                requirements.microphone = devices.availableDevices.first(where: { $0.uid == uid }).map { device in
                    MicrophoneReference(
                        uid: device.uid, name: device.name, modelUID: devices.getDeviceModelUID(deviceID: device.id)
                    )
                }
            }
        )
    }

    private func chooseApplication() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            guard let bundle = Bundle(url: url), let bundleID = bundle.bundleIdentifier else {
                applicationError = String(localized: "Choose a macOS application with a bundle identifier.")
                return
            }
            applicationError = nil
            requirements.application = MicrophoneApplication(
                bundleID: bundleID,
                name: (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                    ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
                    ?? url.deletingPathExtension().lastPathComponent
            )
        }
    }
}
