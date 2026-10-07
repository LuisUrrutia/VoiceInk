import SwiftUI

struct AppWindowToolbar<Content: View>: View {
    @EnvironmentObject private var navigation: MainWindowNavigation
    @AppStorage("mainWindowShowsSidebar") private var showsSidebar = true
    @ViewBuilder let content: () -> Content

    var body: some View {
        AppGlassContainer {
            HStack(spacing: 14) {
                AppIconButton(systemName: "sidebar.left", help: "Toggle sidebar") {
                    showsSidebar.toggle()
                }
                .keyboardShortcut("s", modifiers: [.command, .control])

                if !showsSidebar {
                    Menu {
                        ForEach(ViewType.sidebarGroups, id: \.self) { group in
                            Section {
                                ForEach(group) { destination in
                                    Button { navigation.navigate(to: destination) } label: {
                                        Text(destination.title)
                                    }
                                }
                            }
                        }
                    } label: {
                        Text(navigation.selectedView.title)
                    }
                    .menuStyle(.borderlessButton).fixedSize()
                }

                content()
            }
            .padding(.horizontal, 18)
            .frame(height: 50)
        }
    }
}

struct MicrophoneMenu: View {
    @ObservedObject private var devices = AudioDeviceManager.shared
    @EnvironmentObject private var navigation: MainWindowNavigation

    var body: some View {
        Menu {
            Toggle(isOn: Binding(
                get: { devices.inputMode == .systemDefault },
                set: { if $0 { devices.selectInputMode(.systemDefault) } }
            )) {
                Label("Use system default", systemImage: "desktopcomputer")
            }

            ForEach(devices.availableDevices, id: \.uid) { device in
                Toggle(isOn: Binding(
                    get: { devices.inputMode == .custom && devices.selectedDeviceID == device.id },
                    set: { if $0 { devices.selectDeviceAndSwitchToCustomMode(id: device.id) } }
                )) {
                    Label(device.name, systemImage: "mic")
                }
            }

            if !devices.prioritizedDevices.isEmpty {
                Divider()
                Toggle("Use priority order", isOn: Binding(
                    get: { devices.inputMode == .prioritized },
                    set: { if $0 { devices.selectInputMode(.prioritized) } }
                ))
            }

            Divider()
            Button("Audio Settings…") { navigation.navigate(to: .audio) }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .medium))
                    .accessibilityHidden(true)
                Text(microphoneName)
                    .lineLimit(1).truncationMode(.middle)
                Image(systemName: "mic")
                    .frame(width: 28, height: 28)
                    .background(AppTheme.Surface.subtle, in: Circle())
            }
            .font(.system(size: 13))
            .padding(.leading, 12).padding(.trailing, 4).padding(.vertical, 4)
            .contentShape(Capsule()).appHoverHighlight(cornerRadius: 20)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: 310, alignment: .trailing)
        .accessibilityLabel("Microphone")
        .accessibilityValue(microphoneName)
        .help("Select microphone")
    }

    private var microphoneName: String {
        let name = devices.availableDevices.first { $0.id == devices.getCurrentDevice() }?.name
            ?? String(localized: "System microphone")
        switch devices.inputMode {
        case .systemDefault: return String(localized: "\(name) (Default)")
        case .prioritized: return String(localized: "\(name) (Priority)")
        case .custom: return name
        }
    }
}
