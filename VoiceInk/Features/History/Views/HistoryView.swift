import SwiftData
import SwiftUI

struct HistoryView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var searchText = ""
    @State private var isSelecting = false
    @State private var detailTranscription: Transcription?
    @FocusState private var isSearchFocused: Bool
    @State private var selectedTranscriptions: Set<Transcription> = []
    @State private var showDeleteConfirmation = false
    @State private var isShowingInfo = false
    @State private var activePanel: HistoryPanel?
    @State private var pagination: HistoryPagination?
    @State private var isViewCurrentlyVisible = false

    private let exportService = VoiceInkCSVExportService()

    private var displayedTranscriptions: [Transcription] { pagination?.transcriptions ?? [] }
    private var hasMoreContent: Bool { pagination?.hasMoreContent ?? false }
    private var isLoading: Bool { pagination?.isLoading ?? true }

    @Query(Self.createLatestTranscriptionIndicatorDescriptor()) private var latestTranscriptionIndicator:
        [Transcription]

    private static func createLatestTranscriptionIndicatorDescriptor() -> FetchDescriptor<Transcription> {
        var descriptor = FetchDescriptor<Transcription>(
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        return descriptor
    }

    private var allSelected: Bool {
        !displayedTranscriptions.isEmpty && displayedTranscriptions.allSatisfy { selectedTranscriptions.contains($0) }
    }

    private func openDetail(_ transcription: Transcription) {
        activePanel = nil
        isShowingInfo = false
        isSearchFocused = false
        detailTranscription = transcription
    }

    private func closeDetail() {
        activePanel = nil
        isShowingInfo = false
        detailTranscription = nil
        isSearchFocused = true
    }

    var body: some View {
        ZStack {
            // Keep the list mounted so returning from details preserves its scroll position.
            historyContent
                .opacity(detailTranscription == nil ? 1 : 0)
                .allowsHitTesting(detailTranscription == nil)
                .disabled(detailTranscription != nil)
                .accessibilityHidden(detailTranscription != nil)

            if let transcription = detailTranscription {
                TranscriptionDetailView(
                    transcription: transcription,
                    isInfoPresented: $isShowingInfo,
                    onBack: closeDetail,
                    onTranscriptionUpdated: { updated in
                        guard detailTranscription?.id == transcription.id else { return }
                        isShowingInfo = false
                        detailTranscription = updated
                    }
                )
                .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: detailTranscription?.id)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sidePanel(
            isPresented: .init(
                get: { activePanel != nil },
                set: { if !$0 { activePanel = nil } }
            ),
            dismissOnExitCommand: false
        ) {
            panelContent
        }
        .onExitCommand {
            if isShowingInfo {
                isShowingInfo = false
            } else if activePanel != nil {
                activePanel = nil
            } else if detailTranscription != nil {
                closeDetail()
            }
        }
        .alert("Delete Selected Items?", isPresented: $showDeleteConfirmation) {
            Button("Delete", role: .destructive) {
                deleteSelectedTranscriptions()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                String(
                    localized:
                        "This action cannot be undone. Are you sure you want to delete \(selectedTranscriptions.count) items?"
                ))
        }
        .onAppear {
            isViewCurrentlyVisible = true
            isSearchFocused = true
            if pagination == nil { pagination = HistoryPagination(context: modelContext) }
            pagination?.activate(searchText: searchText)
        }
        .onDisappear {
            isViewCurrentlyVisible = false
            pagination?.suspend()
        }
        .onChange(of: searchText) { _, _ in
            loadInitialContent()
        }
        .onChange(of: latestTranscriptionIndicator.first?.id) { oldId, newId in
            guard isViewCurrentlyVisible else { return }
            if newId != oldId {
                loadInitialContent()
            }
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .transcriptionCreated)
                .merge(with: NotificationCenter.default.publisher(for: .transcriptionDeleted))
                .merge(with: NotificationCenter.default.publisher(for: .transcriptionCompleted))
        ) { _ in
            guard isViewCurrentlyVisible else { return }
            loadInitialContent()
        }
    }

    private var historyContent: some View {
        VStack(spacing: 0) {
            AppWindowToolbar {
                HStack(spacing: 10) {
                    Image(appSymbol: "magnifyingglass")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    TextField("Search history", text: $searchText)
                        .textFieldStyle(.plain).font(.system(size: 14))
                        .focused($isSearchFocused)
                        .accessibilityIdentifier("history.search")
                    if isLoading { ProgressView().controlSize(.small) }
                    if !searchText.isEmpty {
                        Button {
                            searchText = ""
                            isSearchFocused = true
                        } label: {
                            Image(appSymbol: "xmark.circle.fill")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Clear history search")
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .appGlassControl()
                .overlay {
                    Capsule().strokeBorder(
                        isSearchFocused ? Color.accentColor.opacity(0.6) : AppTheme.Border.control,
                        lineWidth: 1
                    )
                }
                .contentShape(Capsule())
                .onTapGesture { isSearchFocused = true }
                .frame(maxWidth: 420)

                Spacer(minLength: 0)

                HistoryIconButton(systemName: "checklist", help: "Select transcriptions", isSelected: isSelecting) {
                    isSelecting.toggle()
                    if !isSelecting { selectedTranscriptions.removeAll() }
                }
                HistoryIconButton(systemName: "gearshape", help: "History settings") {
                    activePanel = .settings
                }
            }

            if displayedTranscriptions.isEmpty && !isLoading {
                HistoryEmptyState(
                    hasSearchQuery: !searchText.isEmpty,
                    emptyMessage: "Your transcription history will appear here"
                )
            } else {
                historyList
            }

            if isSelecting {
                AppGlassContainer { selectionBar }.padding(.horizontal, 14).padding(.bottom, 10)
            }
        }
    }

    private var selectionBar: some View {
        HStack(spacing: 8) {
            if !selectedTranscriptions.isEmpty {
                Text(String(format: String(localized: "%lld selected"), Int64(selectedTranscriptions.count)))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(AppTheme.Text.secondary)

                Spacer(minLength: 8)

                HistoryCommandButton("Analyze", systemImage: "chart.bar.xaxis") {
                    activePanel = .analysis
                }

                HistoryCommandButton("Export", systemImage: "square.and.arrow.up") {
                    exportService.exportTranscriptionsToCSV(transcriptions: Array(selectedTranscriptions))
                }

                HistoryCommandButton("Delete", systemImage: "trash", isDestructive: true) {
                    showDeleteConfirmation = true
                }
            }

            if allSelected {
                HistoryCommandButton("Deselect All") {
                    selectedTranscriptions.removeAll()
                }
            } else {
                HistoryCommandButton("Select All") {
                    Task { await selectAllTranscriptions() }
                }
                .disabled(displayedTranscriptions.isEmpty)
            }

            if selectedTranscriptions.isEmpty {
                Spacer()
            }
        }
        .padding(.horizontal, 10)
        .frame(height: HistoryLayout.actionBarHeight)
    }

    // MARK: - History List

    private var historyList: some View {
        HistoryList(topInset: 18, bottomInset: 24, horizontalInset: 24) {
            ForEach(Array(displayedTranscriptions.enumerated()), id: \.element.id) { index, transcription in
                if index == 0 || !Calendar.current.isDate(
                    transcription.timestamp, inSameDayAs: displayedTranscriptions[index - 1].timestamp
                ) {
                    Text(transcription.timestamp, format: .dateTime.day().month(.wide).year())
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, index == 0 ? 0 : 12).padding(.bottom, 4)
                        .accessibilityAddTraits(.isHeader)
                }
                HistoryTranscriptionRow(
                    transcription: transcription,
                    isSelected: selectedTranscriptions.contains(transcription),
                    onSelect: { openDetail(transcription) },
                    onToggleCheck: { toggleSelection(transcription) },
                    showsCopyButton: true,
                    isCompact: false
                )
                .id(transcription.id)
            }

            if hasMoreContent {
                HistoryCommandButton("Load More") {
                    pagination?.loadMore()
                }
                .disabled(isLoading)
                .padding(.vertical, 8)
            }
        }
    }

    // MARK: - Side Panel

    @ViewBuilder
    private var panelContent: some View {
        if let activePanel {
            switch activePanel {
            case .analysis:
                HistoryAnalysisPanelView(
                    transcriptions: Array(selectedTranscriptions),
                    onClose: { self.activePanel = nil }
                )
                .id(selectedTranscriptions.count)
            case .settings:
                HistorySettingsPanel(onClose: { self.activePanel = nil })
            }
        }
    }

    // MARK: - Data Loading

    @MainActor
    private func loadInitialContent() {
        pagination?.reload(searchText: searchText)
    }

    // MARK: - Selection & Deletion

    private func toggleSelection(_ transcription: Transcription) {
        isSelecting = true
        if selectedTranscriptions.contains(transcription) {
            selectedTranscriptions.remove(transcription)
        } else {
            selectedTranscriptions.insert(transcription)
        }
    }

    private func performDeletion(for transcription: Transcription) {
        if let url = transcription.availableHistoryAudioURL {
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                print("Error deleting audio file: \(error.localizedDescription)")
            }
        }

        if detailTranscription?.id == transcription.id {
            closeDetail()
        }

        selectedTranscriptions.remove(transcription)
        modelContext.delete(transcription)
    }

    private func deleteSelectedTranscriptions() {
        for transcription in selectedTranscriptions {
            performDeletion(for: transcription)
        }
        selectedTranscriptions.removeAll()

        Task {
            do {
                try modelContext.save()
                NotificationCenter.default.post(name: .transcriptionDeleted, object: nil)
                loadInitialContent()
            } catch {
                print("Error saving deletion: \(error.localizedDescription)")
                loadInitialContent()
            }
        }
    }

    @MainActor
    private func selectAllTranscriptions() async {
        do {
            var allDescriptor = FetchDescriptor<Transcription>()

            if !searchText.isEmpty {
                let query = searchText
                allDescriptor.predicate = #Predicate<Transcription> { transcription in
                    transcription.text.localizedStandardContains(query)
                        || (transcription.enhancedText?.localizedStandardContains(query) ?? false)
                }
            }

            allDescriptor.propertiesToFetch = [\.id]
            let allTranscriptions = try modelContext.fetch(allDescriptor)
            selectedTranscriptions = Set(displayedTranscriptions)
            selectedTranscriptions.formUnion(allTranscriptions)
        } catch {
            print("Error selecting all transcriptions: \(error)")
        }
    }
}

private enum HistoryPanel {
    case analysis
    case settings
}
