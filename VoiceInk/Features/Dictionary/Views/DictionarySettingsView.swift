import SwiftUI

struct DictionarySettingsView: View {
    @State private var selectedSection: DictionarySection = .spellings
    @State private var activePanel: DictionaryPanel?
    @State private var isAutoLearnReviewPresented = false
    @AppStorage(AutoLearnSettings.hasFailureKey) private var hasAutoLearnFailure = false
    private let dictionaryInfoMessage: LocalizedStringKey =
        "Word Replacements run after transcription. Vocabulary helps supported transcription models and AI enhancement recognize names, technical terms, and unique spellings."

    enum DictionarySection: String, CaseIterable, Hashable {
        case spellings = "Vocabulary"
        case replacements = "Word Replacements"

        var description: String {
            switch self {
            case .spellings:
                return String(
                    localized:
                        "Vocabulary helps supported transcription models and AI enhancement preserve important names, technical terms, and unique spellings."
                )
            case .replacements:
                return String(
                    localized:
                        "Word Replacements run after transcription to replace misheard words, phrases, abbreviations, or boilerplate text."
                )
            }
        }

        var systemImage: String {
            switch self {
            case .spellings:
                return "character.book.closed"
            case .replacements:
                return "arrow.left.arrow.right"
            }
        }
    }

    private enum DictionaryPanel: Equatable {
        case settings
        case autoLearnFailure
    }

    var body: some View {
        VStack(spacing: 0) {
            headerSection

            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 18) {
                    sectionSelector
                    selectedSectionContent
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .padding(.horizontal, 24)
                .padding(.top, 18)
                .padding(.bottom, 28)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 600, minHeight: 500)
        .sidePanel(
            isPresented: Binding(
                get: { activePanel != nil },
                set: { if !$0 { activePanel = nil } }
            )
        ) {
            switch activePanel {
            case .settings:
                DictionarySettingsPanel {
                    activePanel = nil
                } onReviewNow: {
                    activePanel = nil
                    isAutoLearnReviewPresented = true
                }
            case .autoLearnFailure:
                AutoLearnFailurePanel {
                    activePanel = nil
                }
            case nil:
                EmptyView()
            }
        }
        .sidePanel(isPresented: $isAutoLearnReviewPresented) {
            AutoLearnReviewPanel {
                isAutoLearnReviewPresented = false
            }
        }
    }

    private var headerSection: some View {
        AppWindowToolbar {
            InfoTip(dictionaryInfoMessage, learnMoreURL: "https://tryvoiceink.com/docs/auto-learn-dictionary")
            Spacer()
            HStack(spacing: 8) {
                if hasAutoLearnFailure {
                    AppIconButton(
                        systemName: "exclamationmark.triangle.fill",
                        help: "Dictionary Auto Learn failed"
                    ) {
                        activePanel = .autoLearnFailure
                    }
                }
                settingsButton
            }
        }
    }

    private var settingsButton: some View {
        AppIconButton(
            systemName: "gearshape.fill",
            help: "Dictionary Settings"
        ) {
            activePanel = activePanel == .settings ? nil : .settings
        }
    }

    private var sectionSelector: some View {
        Picker("Dictionary section", selection: $selectedSection) {
            ForEach(DictionarySection.allCases, id: \.self) { section in
                Label(LocalizedStringKey(section.rawValue), systemImage: section.systemImage)
                    .tag(section)
                    .help(section.description)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.large)
        .fixedSize(horizontal: true, vertical: false)
    }

    @ViewBuilder
    private var selectedSectionContent: some View {
        switch selectedSection {
        case .spellings:
            VocabularyView()
        case .replacements:
            WordReplacementView()
        }
    }
}
