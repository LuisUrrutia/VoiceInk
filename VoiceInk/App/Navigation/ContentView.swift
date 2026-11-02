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
    case meetings = "Meetings"
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

    /// Labs is the last item, and only while it lists a feature. Destinations of Labs features appear while
    /// their switch is on.
    static func sidebarGroups(labsFeatures: [LabsFeature], defaults: UserDefaults = .standard) -> [[ViewType]] {
        let groups: [[ViewType]] = [
            [.dashboard, .modes, .dictionary], [.settings, .audio, .models], [.history, .transcribeAudio, .meetings],
        ].map { group in group.filter { $0.isAvailable(labsFeatures: labsFeatures, defaults: defaults) } }
        return labsFeatures.isEmpty ? groups : groups + [[.labs]]
    }

    /// The Labs feature whose switch shows this destination.
    var labsFeature: LabsFeature? {
        self == .meetings ? .meetings : nil
    }

    func isAvailable(labsFeatures: [LabsFeature] = LabsFeature.all, defaults: UserDefaults = .standard) -> Bool {
        if self == .labs { return !labsFeatures.isEmpty }
        guard let labsFeature else { return true }
        return labsFeatures.contains(labsFeature) && Labs.isEnabled(labsFeature, in: defaults)
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
    @AppStorage(LabsFeature.meetings.defaultsKey) private var showsMeetings = false

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
        .onChange(of: showsMeetings) {
            if !navigation.selectedView.isAvailable() { navigation.selectedView = .dashboard }
        }
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
        case .meetings:
            MeetingsView()
        case .labs:
            LabsView()
        }
    }
}
