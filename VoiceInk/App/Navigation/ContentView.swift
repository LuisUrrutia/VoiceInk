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
    @AppStorage("mainWindowShowsSidebar") private var showsSidebar = true

    var body: some View {
        HStack(spacing: 0) {
            if showsSidebar {
                AppSidebar(selectedView: $navigation.selectedView)
            }

            VStack(spacing: 0) {
                if ![ViewType.history, .models, .modes, .dictionary].contains(navigation.selectedView) {
                    AppWindowToolbar {
                        Spacer()
                        MicrophoneMenu()
                    }
                }
                detailView(for: navigation.selectedView).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background {
                AppContentBackground()
                    .ignoresSafeArea()
            }
        }
        .buttonBorderShape(.capsule)
        .frame(minWidth: AppWindowLayout.minimumWidth, minHeight: AppWindowLayout.minimumHeight)
        .onReceive(NotificationCenter.default.publisher(for: .navigateToDestination)) { notification in
            if let destination = notification.userInfo?["destination"] as? String {
                navigation.navigate(to: destination)
            }
        }
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
