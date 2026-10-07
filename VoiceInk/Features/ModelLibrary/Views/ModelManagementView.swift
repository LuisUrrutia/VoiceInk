import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ModelManagementView: View {
    @EnvironmentObject private var aiService: AIService
    @EnvironmentObject private var whisperModelManager: WhisperModelManager
    @EnvironmentObject private var fluidAudioModelManager: FluidAudioModelManager
    @EnvironmentObject private var transcriptionModelManager: TranscriptionModelManager
    @StateObject private var customModelManager = CustomCloudModelManager.shared
    @StateObject private var customAIProviderManager = CustomAIProviderManager.shared
    @ObservedObject private var warmupCoordinator = WhisperModelWarmupCoordinator.shared
    @ObservedObject private var voiceInkRefineService = VoiceInkRefineService.shared
    @ObservedObject private var transcribeCppModelManager = TranscribeCppModelManager.shared

    @State private var selectedCategory: ModelCatalogCategory = .speech
    @State private var selectedSource: ModelCatalogSource = .local
    @State private var installationFilter: ModelInstallationFilter = .all
    @State private var sortOrder: ModelCatalogSortOrder = .catalog
    @State private var activePanel: ModelManagementPanel?

    @State private var isShowingDeleteAlert = false
    @State private var alertTitle = ""
    @State private var alertMessage = ""
    @State private var deleteActionClosure: () -> Void = {}

    private enum ModelManagementPanel {
        case settings
        case cloudProvider(ProviderDescriptor)
        case customTranscriptionModel(CustomCloudModel?)
        case customEnhancementModel(CustomAIProviderConfig?)
    }

    private var isSettingsPanelOpen: Bool {
        if case .settings? = activePanel { return true }
        return false
    }

    private var isPanelOpen: Bool {
        activePanel != nil
    }

    private var selectedCloudProviderID: String? {
        if case .cloudProvider(let descriptor)? = activePanel {
            return descriptor.id
        }
        return nil
    }

    private func closePanel() {
        activePanel = nil
    }

    private func toggleSettingsPanel() {
        activePanel = isSettingsPanelOpen ? nil : .settings
    }

    private func openCloudProviderPanel(_ descriptor: ProviderDescriptor) {
        activePanel = .cloudProvider(descriptor)
    }

    private func openCustomTranscriptionModelPanel(_ model: CustomCloudModel? = nil) {
        activePanel = .customTranscriptionModel(model)
    }

    private func openCustomEnhancementModelPanel(_ provider: CustomAIProviderConfig? = nil) {
        activePanel = .customEnhancementModel(provider)
    }

    var body: some View {
        VStack(spacing: 0) {
            headerSection

            catalogControls
                .padding(.horizontal, 24)
                .padding(.top, 18)
                .padding(.bottom, 12)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if SystemArchitecture.isIntelMac && selectedSource == .local {
                        intelMacWarningBanner
                    }

                    availableModelsSection
                }
                .padding(.horizontal, 24)
                .padding(.top, 18)
                .padding(.bottom, 28)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 600, minHeight: 500)
        .onChange(of: selectedCategory) { _, _ in closePanel() }
        .onChange(of: selectedSource) { _, _ in closePanel() }
        .sidePanel(
            isPresented: .init(
                get: { isPanelOpen },
                set: { if !$0 { closePanel() } }
            )
        ) {
            modelPanelContent
        }
        .alert(isPresented: $isShowingDeleteAlert) {
            Alert(
                title: Text(alertTitle),
                message: Text(alertMessage),
                primaryButton: .destructive(Text("Delete"), action: deleteActionClosure),
                secondaryButton: .cancel()
            )
        }
    }

    private var headerSection: some View {
        AppScreenHeader(title: "Model Catalog") {
            settingsButton
        }
    }

    @ViewBuilder
    private var modelPanelContent: some View {
        switch activePanel {
        case .settings:
            settingsPanelContent
        case .cloudProvider(let descriptor):
            ProviderDetailPanel(descriptor: descriptor, category: selectedCategory, onClose: closePanel)
                .environmentObject(aiService)
                .environmentObject(transcriptionModelManager)
                .id(descriptor.id)
        case .customTranscriptionModel(let model):
            CustomTranscriptionModelEditorPanel(
                editingModel: model,
                customModelManager: customModelManager,
                onClose: closePanel,
                onSave: {
                    transcriptionModelManager.refreshAllAvailableModels()
                    closePanel()
                }
            )
        case .customEnhancementModel(let provider):
            CustomEnhancementModelEditorPanel(
                editingProvider: provider,
                manager: customAIProviderManager,
                onClose: closePanel,
                onSave: closePanel
            )
        case nil:
            EmptyView()
        }
    }

    private var settingsPanelContent: some View {
        VStack(spacing: 0) {
            AppPanelHeader(title: "Model Settings", onClose: closePanel)

            ModelSettingsPanel()
        }
    }

    private var availableModelsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            switch selectedSource {
            case .local:
                if selectedCategory == .speech {
                    localSpeechModelsSection
                } else {
                    localEnhancementModelsSection
                }
            case .cloud:
                CloudProviderManagementView(
                    category: selectedCategory,
                    selectedProviderID: selectedCloudProviderID,
                    onSelectProvider: openCloudProviderPanel
                )
                .environmentObject(aiService)
                .environmentObject(transcriptionModelManager)
            case .custom:
                CustomProviderManagementView(
                    category: selectedCategory,
                    customModelManager: customModelManager,
                    customAIProviderManager: customAIProviderManager,
                    onAddTranscriptionModel: {
                        openCustomTranscriptionModelPanel()
                    },
                    onEditTranscriptionModel: { model in
                        openCustomTranscriptionModelPanel(model)
                    },
                    onDeleteTranscriptionModel: { model in
                        confirmDeleteCustomModel(model)
                    },
                    onAddEnhancementModel: {
                        openCustomEnhancementModelPanel()
                    },
                    onEditEnhancementModel: { provider in
                        openCustomEnhancementModelPanel(provider)
                    },
                    onDeleteEnhancementModel: { provider in
                        confirmDeleteCustomEnhancementModel(provider)
                    }
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var catalogControls: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("Model Type", selection: $selectedCategory) {
                ForEach(ModelCatalogCategory.allCases) { category in
                    Text(category.title).tag(category)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 360)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) { filterControls }
                VStack(alignment: .leading, spacing: 10) { filterControls }
            }

            if selectedSource == .local && selectedCategory == .speech && (sortOrder == .speed || sortOrder == .accuracy) {
                Text("Models without a rating appear last.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if selectedSource == .local && selectedCategory == .enhancement {
                Text("Installation filters apply to downloadable models. Services are configured separately.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var filterControls: some View {
        Picker("Source", selection: $selectedSource) {
            ForEach(ModelCatalogSource.allCases) { source in
                Text(source.title).tag(source)
            }
        }
        .fixedSize()

        if selectedSource == .local {
            Picker("Installation", selection: $installationFilter) {
                ForEach(ModelInstallationFilter.allCases) { filter in
                    Text(filter.title).tag(filter)
                }
            }
            .fixedSize()

            if selectedCategory == .speech {
                Picker("Sort by", selection: $sortOrder) {
                    ForEach(ModelCatalogSortOrder.allCases) { order in
                        Text(order.title).tag(order)
                    }
                }
                .fixedSize()
            }
        }
    }

    private var settingsButton: some View {
        AppIconButton(
            systemName: "gearshape.fill",
            help: "Model Settings"
        ) {
            toggleSettingsPanel()
        }
    }

    private var localSpeechModelsSection: some View {
        let models = filteredLocalSpeechModels

        return VStack(spacing: 12) {
            if models.isEmpty {
                emptyModelsState
            } else {
                ForEach(models, id: \.id) { model in
                    localModelCard(model)
                }
            }

            importLocalModelButton
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var localEnhancementModelsSection: some View {
        VStack(spacing: 12) {
            if installationFilter.includes(isInstalled: voiceInkRefineService.isDownloaded) {
                VoiceInkRefineModelCardView(
                    service: voiceInkRefineService,
                    deleteAction: deleteVoiceInkRefineModel
                )
            } else {
                emptyModelsState
            }

            LocalEnhancementServiceManagementView()
                .environmentObject(aiService)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var emptyModelsState: some View {
        ContentUnavailableView {
            Label("No Matching Models", systemImage: "line.3.horizontal.decrease.circle")
        } description: {
            Text("Try showing all models to find one to download.")
        } actions: {
            Button("Show All Models") { installationFilter = .all }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }

    private func localModelCard(_ model: any TranscriptionModel) -> some View {
        let isWarming =
            (model as? WhisperModel).map { whisperModel in
                warmupCoordinator.isWarming(modelNamed: whisperModel.name)
            } ?? false

        return ModelCardView(
            model: model,
            isDownloaded: whisperModelManager.availableModels.contains { $0.name == model.name },
            downloadProgress: whisperModelManager.downloadProgress,
            modelURL: whisperModelManager.availableModels.first { $0.name == model.name }?.url,
            isWarming: isWarming,
            deleteAction: {
                deleteLocalModel(model)
            },
            downloadAction: {
                if let whisperModel = model as? WhisperModel {
                    whisperModelManager.startDownload(whisperModel)
                }
            },
            cancelDownloadAction: {
                if let whisperModel = model as? WhisperModel {
                    whisperModelManager.cancelDownload(whisperModel)
                }
            }
        )
    }

    private var importLocalModelButton: some View {
        HStack(spacing: 8) {
            Button(action: { presentImportPanel() }) {
                HStack(spacing: 8) {
                    Image(systemName: "square.and.arrow.down")
                    Text("Import Local Model…")
                        .font(.system(size: 12, weight: .semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(16)
                .background(AppMaterialCardBackground(cornerRadius: 10))
            }
            .buttonStyle(.plain)

            InfoTip(
                "Add a custom fine-tuned whisper model to use with VoiceInk. Select the downloaded .bin file.",
                learnMoreURL: "https://tryvoiceink.com/docs/custom-local-whisper-models"
            )
            .help("Read more about custom local models")
        }
    }

    private var intelMacWarningBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(AppTheme.Status.warningStrong)

            Text("Local models don't work reliably on Intel Macs")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.primary.opacity(0.85))

            Spacer()

            Button(action: {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    selectedSource = .cloud
                }
            }) {
                HStack(spacing: 4) {
                    Text("Use Cloud")
                        .font(.system(size: 12, weight: .semibold))
                    Image(systemName: "arrow.right")
                        .font(.system(size: 10, weight: .bold))
                }
                .foregroundColor(AppTheme.Status.warningStrong)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(AppTheme.Status.warningStrong.opacity(0.12))
                .cornerRadius(6)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(AppTheme.Status.warningStrong.opacity(0.08))
        .cornerRadius(8)
    }

    private var filteredLocalSpeechModels: [any TranscriptionModel] {
        ModelCatalog.localSpeechModels(
            from: transcriptionModelManager.allAvailableModels.filter {
                transcriptionModelManager.isAvailableOnCurrentOS($0)
            },
            installation: installationFilter,
            sortOrder: sortOrder,
            isInstalled: { model in
                switch model.provider {
                case .whisper:
                    whisperModelManager.availableModels.contains { $0.name == model.name }
                case .fluidAudio:
                    fluidAudioModelManager.isFluidAudioModelDownloaded(named: model.name)
                case .transcribeCpp:
                    transcribeCppModelManager.isModelDownloaded(named: model.name)
                default:
                    false
                }
            }
        )
    }

    private func deleteLocalModel(_ model: any TranscriptionModel) {
        guard let downloadedModel = whisperModelManager.availableModels.first(where: { $0.name == model.name }) else {
            return
        }

        Task {
            await whisperModelManager.deleteModel(downloadedModel)
        }
    }

    private func confirmDeleteCustomModel(_ model: CustomCloudModel) {
        alertTitle = String(localized: "Delete Custom Model")
        alertMessage = String(
            format: String(localized: "Are you sure you want to delete the custom model '%@'?"),
            model.displayName
        )
        deleteActionClosure = {
            customModelManager.removeCustomModel(withId: model.id)
            transcriptionModelManager.refreshAllAvailableModels()
        }
        isShowingDeleteAlert = true
    }

    private func deleteVoiceInkRefineModel() {
        Task {
            await voiceInkRefineService.deleteModel()
        }
    }

    private func confirmDeleteCustomEnhancementModel(_ provider: CustomAIProviderConfig) {
        alertTitle = String(localized: "Delete Custom Enhancement Model")
        alertMessage = String(
            format: String(localized: "Are you sure you want to delete the custom enhancement model '%@'?"),
            provider.name
        )
        deleteActionClosure = {
            customAIProviderManager.deleteProvider(provider)
        }
        isShowingDeleteAlert = true
    }

    private func presentImportPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.init(filenameExtension: "bin")!]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.resolvesAliases = true
        panel.title = String(localized: "Select a Whisper ggml .bin model")
        if panel.runModal() == .OK, let url = panel.url {
            Task { @MainActor in
                await whisperModelManager.importWhisperModel(from: url)
            }
        }
    }
}
