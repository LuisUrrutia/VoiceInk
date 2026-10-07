import SwiftUI

enum ViewType: String, CaseIterable, Identifiable {
    case dashboard = "Dashboard"
    case modes = "Modes"
    case models = "AI Models"
    case transcribeAudio = "Transcribe Audio"
    case history = "History"
    case audio = "Audio"
    case dictionary = "Dictionary"
    case settings = "Settings"

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .dashboard: "Home"
        case .models: "Models"
        case .transcribeAudio: "Import Audio"
        default: LocalizedStringKey(rawValue)
        }
    }

    static let sidebarGroups: [[ViewType]] = [
        [.dashboard, .modes, .dictionary], [.settings, .audio, .models], [.history, .transcribeAudio]
    ]
}

final class MainWindowNavigation: ObservableObject {
    static let shared = MainWindowNavigation()

    @Published var selectedView: ViewType = .dashboard

    private init() {}

    func navigate(to destination: String) {
        guard let viewType = ViewType(rawValue: destination) else {
            return
        }

        navigate(to: viewType)
    }

    func navigate(to destination: ViewType) {
        selectedView = destination
    }
}

struct ContentView: View {
    @EnvironmentObject private var navigation: MainWindowNavigation
    @ObservedObject private var audioDevices = AudioDeviceManager.shared
    @AppStorage("mainWindowShowsSidebar") private var showsSidebar = true

    var body: some View {
        HStack(spacing: 0) {
            if showsSidebar {
                AppSidebar(selectedView: $navigation.selectedView)
            }

            VStack(spacing: 0) {
                AppGlassContainer { windowToolbar }
                detailView(for: navigation.selectedView).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(AppTheme.Surface.window)
        }
        .frame(minWidth: AppWindowLayout.minimumWidth, minHeight: AppWindowLayout.minimumHeight)
        .onReceive(NotificationCenter.default.publisher(for: .navigateToDestination)) { notification in
            if let destination = notification.userInfo?["destination"] as? String {
                navigation.navigate(to: destination)
            }
        }
    }
    private var windowToolbar: some View {
        HStack(spacing: 12) {
            Button {
                showsSidebar.toggle()
            } label: {
                Image(systemName: "sidebar.left").font(.system(size: 15)).frame(width: 18, height: 22)
            }
            .appGlassButtonStyle().help("Toggle sidebar").accessibilityLabel("Toggle sidebar")
            .keyboardShortcut(
                "s", modifiers: [.command, .control])

            if !showsSidebar {
                Menu {
                    ForEach(ViewType.sidebarGroups, id: \.self) { group in
                        Section {
                            ForEach(group) { destination in
                                Button {
                                    navigation.navigate(to: destination)
                                } label: {
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

            Spacer()

            Button {
                navigation.navigate(to: .audio)
            } label: {
                Label(currentMicrophoneName, systemImage: "mic").font(.system(size: 12)).lineLimit(1)
                    .truncationMode(
                        .middle
                    )
                    .frame(maxWidth: 300, alignment: .trailing).fixedSize(horizontal: true, vertical: false)
            }
            .appGlassButtonStyle()
            .help("Microphone settings")
            .accessibilityLabel(
                "Microphone: \(currentMicrophoneName). Open audio settings.")
        }
        .foregroundStyle(.secondary).padding(.horizontal, 18).frame(height: 44)
    }

    private var currentMicrophoneName: String {
        let currentID = audioDevices.getCurrentDevice()
        return audioDevices.availableDevices.first { $0.id == currentID }?.name
            ?? String(localized: "System microphone")
    }

    @ViewBuilder
    private func detailView(for viewType: ViewType) -> some View {
        switch viewType {
        case .dashboard:
            DashboardView()
        case .models:
            ModelManagementView()
        case .transcribeAudio:
            AudioTranscribeView()
        case .history:
            HistoryView()
        case .audio:
            AudioSetupView()
        case .dictionary:
            DictionarySettingsView()
        case .modes:
            ModeView()
        case .settings:
            SettingsView()
        }
    }
}
