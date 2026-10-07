import SwiftData
import SwiftUI

extension View {
    func placeholder<Content: View>(
        when shouldShow: Bool,
        alignment: Alignment = .center,
        @ViewBuilder placeholder: () -> Content
    ) -> some View {

        ZStack(alignment: alignment) {
            placeholder().opacity(shouldShow ? 1 : 0)
            self
        }
    }
}

enum ConfigurationMode: Hashable {
    case add
    case edit(ModeConfig)

    var isAdding: Bool {
        if case .add = self { return true }
        return false
    }

    func hash(into hasher: inout Hasher) {
        switch self {
        case .add:
            hasher.combine(0)
        case .edit(let config):
            hasher.combine(1)
            hasher.combine(config.id)
        }
    }

    static func == (lhs: ConfigurationMode, rhs: ConfigurationMode) -> Bool {
        switch (lhs, rhs) {
        case (.add, .add):
            return true
        case (.edit(let lhsConfig), .edit(let rhsConfig)):
            return lhsConfig.id == rhsConfig.id
        default:
            return false
        }
    }
}

enum ConfigurationType {
    case application
    case website
}

struct ModeView: View {
    @StateObject private var modeManager = ModeManager.shared
    @StateObject private var modeWarmupStore = ModeFormWarmupStore.shared
    @EnvironmentObject private var enhancementService: AIEnhancementService
    @EnvironmentObject private var aiService: AIService
    @EnvironmentObject private var transcriptionModelManager: TranscriptionModelManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var activePanel: PanelType?
    @State private var panelID = UUID()

    private enum PanelType {
        case configuration(ConfigurationMode)
        case settings
    }

    private var isSettingsOpen: Bool {
        if case .settings? = activePanel { return true }
        return false
    }

    private var isEditingMode: Bool {
        if case .configuration? = activePanel { return true }
        return false
    }

    private var headerControls: some View {
        HStack(spacing: 8) {
            addModeButton
            settingsButton
        }
    }

    private var addModeButton: some View {
        AppIconButton(
            systemName: "plus",
            help: "Add a new mode"
        ) {
            openPanel(mode: .add)
        }
    }

    private var settingsButton: some View {
        AppIconButton(
            systemName: "gearshape.fill",
            help: "Modes Settings"
        ) {
            openSettingsPanel()
        }
    }

    var body: some View {
        ZStack {
            if case .configuration(let mode)? = activePanel {
                ModeConfigEditorView(mode: mode, modeManager: modeManager, onDismiss: closePanel)
                    .environmentObject(modeWarmupStore)
                    .id(panelID)
                    .transition(reduceMotion ? .opacity : .move(edge: .trailing).combined(with: .opacity))
            } else {
                modeList
                    .transition(reduceMotion ? .opacity : .move(edge: .leading).combined(with: .opacity))
            }
        }
        .clipped()
        .animation(reduceMotion ? .easeOut(duration: 0.12) : .smooth(duration: 0.32), value: isEditingMode)
        .sidePanel(isPresented: .init(
            get: { isSettingsOpen },
            set: { if !$0 { closePanel() } }
        )) {
            ModeSettingsPanelView(modeManager: modeManager, onDismiss: closePanel)
        }
        .onAppear {
            modeWarmupStore.configure(
                aiService: aiService,
                enhancementService: enhancementService,
                transcriptionModelManager: transcriptionModelManager
            )
        }
    }

    private var modeList: some View {
        VStack(spacing: 0) {
            AppWindowToolbar {
                Spacer()
                MicrophoneMenu()
                headerControls
            }

            Group {
                GeometryReader { geometry in
                    ScrollView {
                        VStack(spacing: 0) {
                            if modeManager.configurations.isEmpty {
                                VStack(spacing: 24) {
                                    Spacer()
                                        .frame(height: geometry.size.height * 0.2)

                                    VStack(spacing: 16) {
                                        Image(systemName: "square.grid.2x2.fill")
                                            .font(.system(size: 48, weight: .regular))
                                            .foregroundColor(.secondary.opacity(0.6))

                                        VStack(spacing: 8) {
                                            Text("Create your first mode")
                                                .font(.system(size: 20, weight: .medium))
                                                .foregroundColor(.primary)

                                            Text(
                                                "Set how VoiceInk transcribes and formats your speech, then start dictating in any app."
                                            )
                                            .font(.system(size: 14))
                                            .foregroundColor(.secondary)
                                            .multilineTextAlignment(.center)
                                            .lineSpacing(2)
                                        }
                                    }

                                    AppActionButton("Create a mode", kind: .primary) { openPanel(mode: .add) }

                                    Spacer()
                                }
                                .frame(maxWidth: .infinity)
                                .frame(minHeight: geometry.size.height)
                            } else {
                                VStack(spacing: 0) {
                                    ModeConfigurationsGrid(
                                        modeManager: modeManager,
                                        onEditConfig: { config in
                                            openPanel(mode: .edit(config))
                                        }
                                    )
                                    .padding(.horizontal, 24)
                                    .padding(.vertical, 20)

                                    Spacer()
                                        .frame(height: 40)
                                }
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func openPanel(mode: ConfigurationMode) {
        panelID = UUID()
        activePanel = .configuration(mode)
    }

    private func closePanel() {
        activePanel = nil
    }

    private func openSettingsPanel() {
        activePanel = .settings
    }
}

struct SectionHeader: View {
    let title: LocalizedStringKey

    var body: some View {
        Text(title)
            .font(.system(size: 16, weight: .bold))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 8)
    }
}
