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
    case labs = "Labs"

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .dashboard: "Home"
        case .models: "Models"
        case .transcribeAudio: "Import Audio"
        default: LocalizedStringKey(rawValue)
        }
    }

    static var sidebarGroups: [[ViewType]] { sidebarGroups(labsFeatures: LabsFeature.all) }

    /// Labs is the last item, and only while it lists a feature.
    static func sidebarGroups(labsFeatures: [LabsFeature]) -> [[ViewType]] {
        let groups: [[ViewType]] = [
            [.dashboard, .modes, .dictionary], [.settings, .audio, .models], [.history, .transcribeAudio],
        ]
        return labsFeatures.isEmpty ? groups : groups + [[.labs]]
    }

    func isAvailable(labsFeatures: [LabsFeature] = LabsFeature.all) -> Bool {
        self != .labs || !labsFeatures.isEmpty
    }
}

final class MainWindowNavigation: ObservableObject {
    static let shared = MainWindowNavigation()

    @Published var selectedView: ViewType = .dashboard
    @Published var dictionarySettingsRequested = false

    private init() {}

    func navigate(to destination: String) {
        guard let viewType = ViewType(rawValue: destination) else {
            return
        }

        navigate(to: viewType)
    }

    func navigate(to destination: ViewType) {
        guard destination.isAvailable() else { return }
        selectedView = destination
    }

    func openDictionarySettings() {
        dictionarySettingsRequested = true
        navigate(to: .dictionary)
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
        case .labs:
            LabsView()
        }
    }
}
