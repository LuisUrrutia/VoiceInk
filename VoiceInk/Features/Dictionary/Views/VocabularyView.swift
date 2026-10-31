import SwiftData
import SwiftUI

private struct VocabularyWordDragPayload {
    let term: String
    let sectionID: UUID?

    var encoded: String {
        "\(sectionID?.uuidString ?? "")\n\(term)"
    }

    init(term: String, sectionID: UUID?) {
        self.term = term
        self.sectionID = sectionID
    }

    init?(encoded: String) {
        guard let separator = encoded.firstIndex(of: "\n") else { return nil }
        let sectionText = String(encoded[..<separator])
        if sectionText.isEmpty {
            sectionID = nil
        } else if let sectionID = UUID(uuidString: sectionText) {
            self.sectionID = sectionID
        } else {
            return nil
        }
        term = String(encoded[encoded.index(after: separator)...])
    }
}

struct VocabularyView: View {
    @Query private var vocabularyWords: [VocabularyWord]
    @Query private var vocabularySections: [VocabularySection]
    @Environment(\.modelContext) private var modelContext
    @State private var newWord = ""
    @State private var newSoundsLike = ""
    @State private var showAlert = false
    @State private var alertMessage = ""
    @State private var sortMode: VocabularySortMode = .wordAsc
    @State private var showInfoPopover = false
    @State private var selectedSectionID: UUID?
    @State private var sectionEditor: SectionEditor?
    @State private var sectionToDelete: VocabularySection?
    @State private var targetedDropTarget: VocabularyDropTarget?
    @State private var editedWord: VocabularyWord?
    @FocusState private var focusedField: ComposerField?

    private enum ComposerField {
        case word, soundsLike
    }

    private struct SectionEditor: Identifiable {
        let id = UUID()
        let section: VocabularySection?
    }

    private enum VocabularyDropTarget: Equatable {
        case noSection
        case section(UUID)

        var sectionID: UUID? {
            switch self {
            case .noSection: nil
            case .section(let id): id
            }
        }
    }

    init() {
        _sortMode = State(initialValue: DictionarySortService.shared.savedVocabularyMode())
    }

    private var sortedItems: [VocabularyWord] {
        DictionarySortService.shared.sortVocabulary(vocabularyWords, by: sortMode)
    }

    private var sortedSections: [VocabularySection] {
        vocabularySections.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var ungroupedWords: [VocabularyWord] {
        let sectionIDs = Set(vocabularySections.map(\.id))
        return sortedItems.filter { word in
            guard let sectionID = word.sectionID else { return true }
            return !sectionIDs.contains(sectionID)
        }
    }

    private func toggleSort() {
        let service = DictionarySortService.shared
        sortMode = service.nextVocabularyMode(after: sortMode)
        service.saveVocabularyMode(sortMode)
    }

    private var sortIconName: String {
        switch sortMode {
        case .wordAsc: "chevron.up"
        case .wordDesc: "chevron.down"
        case .newest: "clock.arrow.circlepath"
        case .oldest: "clock"
        }
    }

    private var canAddWords: Bool {
        !newWord.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var selectedSectionName: String {
        sortedSections.first { $0.id == selectedSectionID }?.name ?? String(localized: "No section")
    }

    private var composerHeader: some View {
        AppGlassContainer {
            HStack(spacing: 8) {
                Text("Vocabulary")
                    .font(.system(size: 16, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                Spacer()

                Button {
                    sectionEditor = SectionEditor(section: nil)
                } label: {
                    Label("New section", appSymbol: "plus")
                }
                .appGlassButtonStyle()

                AppIconButton(systemName: "info.circle", help: "Vocabulary examples") {
                    showInfoPopover.toggle()
                }
                .popover(isPresented: $showInfoPopover) {
                    VocabularyInfoPopover()
                }
            }
        }
    }

    private var soundsLikeExceedsLimits: Bool {
        VocabularySoundsLike.normalize(
            VocabularySoundsLike.parse(newSoundsLike),
            term: newWord.trimmingCharacters(in: .whitespacesAndNewlines)
        ).wasClamped
    }

    private func composerField(
        _ title: LocalizedStringKey,
        text: Binding<String>,
        prompt: LocalizedStringKey,
        field: ComposerField,
        minWidth: CGFloat
    ) -> some View {
        let isFocused = focusedField == field
        return TextField(title, text: text, prompt: Text(prompt))
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .focused($focusedField, equals: field)
            .onSubmit { addWords() }
            .padding(.horizontal, 12)
            .frame(minWidth: minWidth, minHeight: 36)
            .appGlassControl()
            .overlay {
                Capsule()
                    .strokeBorder(
                        isFocused ? AppTheme.Accent.primary : AppTheme.Border.control.opacity(0.5),
                        lineWidth: isFocused ? 1.5 : 0.5
                    )
                    .allowsHitTesting(false)
            }
            .contentShape(Capsule())
            .onTapGesture { focusedField = field }
            .accessibilityLabel(title)
    }

    private var wordField: some View {
        composerField(
            "Word or phrase", text: $newWord, prompt: "Add a word or phrase", field: .word, minWidth: 120
        )
        .help("Separate multiple entries with commas")
    }

    private var soundsLikeField: some View {
        composerField(
            "Sounds like", text: $newSoundsLike, prompt: "Sounds like (optional)", field: .soundsLike,
            minWidth: 100
        )
        .help("Comma-separated spellings a transcript may show instead; AI enhancement uses them")
    }

    private var sectionMenu: some View {
        Menu {
            Picker("Add to section", selection: $selectedSectionID) {
                Text("No section").tag(Optional<UUID>.none)
                ForEach(sortedSections) { section in
                    Text(section.name).tag(Optional(section.id))
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Text(selectedSectionName)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .menuStyle(.button)
        .appGlassButtonStyle()
        .controlSize(.large)
        .frame(width: 160)
        .accessibilityLabel("Add to section")
        .accessibilityValue(selectedSectionName)
        .help("Add to section: \(selectedSectionName)")
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            AppGlassContainer {
                HStack(spacing: 10) {
                    wordField
                    soundsLikeField
                    sectionMenu
                    AppActionButton("Add word", kind: .primary, action: addWords)
                        .disabled(!canAddWords)
                        .fixedSize()
                }
            }
            if soundsLikeExceedsLimits {
                VocabularySoundsLikeLimitNote()
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            composerHeader
            composer

            if !vocabularyWords.isEmpty || !vocabularySections.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    if !vocabularyWords.isEmpty {
                        Button(action: toggleSort) {
                            HStack(spacing: 4) {
                                Text(String(localized: "Vocabulary Words (\(vocabularyWords.count))"))
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundColor(.secondary)

                                Image(appSymbol: sortIconName)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                        .help("Change sort order")
                    }

                    if !vocabularySections.isEmpty {
                        sectionDropTarget(.noSection) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("No section")
                                    .font(.system(size: 12, weight: .semibold))
                                sectionWordFlow(ungroupedWords)
                            }
                        }
                    } else if !ungroupedWords.isEmpty {
                        wordFlow(ungroupedWords)
                    }

                    ForEach(sortedSections) { section in
                        sectionDropTarget(.section(section.id)) {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(section.name)
                                        .font(.system(size: 13, weight: .semibold))
                                    Spacer()
                                    Button("Edit") {
                                        sectionEditor = SectionEditor(section: section)
                                    }
                                    .buttonStyle(.borderless)
                                    Button("Delete") {
                                        sectionToDelete = section
                                    }
                                    .buttonStyle(.borderless)
                                }
                                if !section.sectionDescription.isEmpty {
                                    Text(section.sectionDescription)
                                        .font(.system(size: 12))
                                        .foregroundStyle(.secondary)
                                }
                                sectionWordFlow(sortedItems.filter { $0.sectionID == section.id })
                            }
                        }
                        .padding(.top, 4)
                    }
                }
                .padding(.top, 4)
            }

        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: vocabularySections.map(\.id)) { _, sectionIDs in
            if let selectedSectionID, !sectionIDs.contains(selectedSectionID) {
                self.selectedSectionID = nil
            }
        }
        .alert("Vocabulary", isPresented: $showAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(alertMessage)
        }
        .onChange(of: vocabularyWords.map(\.persistentModelID)) { _, wordIDs in
            if let editedWord, !wordIDs.contains(editedWord.persistentModelID) {
                self.editedWord = nil
            }
        }
        .sheet(item: $sectionEditor) { editor in
            VocabularySectionEditor(section: editor.section)
        }
        .confirmationDialog(
            "Delete section?",
            isPresented: Binding(
                get: { sectionToDelete != nil },
                set: { if !$0 { sectionToDelete = nil } }
            )
        ) {
            Button("Delete section", role: .destructive) {
                if let sectionToDelete {
                    if let error = VocabularySectionService.delete(
                        sectionToDelete, words: vocabularyWords, context: modelContext
                    ) {
                        alertMessage = error
                        showAlert = true
                    }
                    if selectedSectionID == sectionToDelete.id { selectedSectionID = nil }
                    self.sectionToDelete = nil
                }
            }
        } message: {
            Text("Its words will stay in your vocabulary without a section.")
        }
    }

    private func sectionDropTarget<Content: View>(
        _ target: VocabularyDropTarget,
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .padding(8)
            .frame(maxWidth: .infinity, minHeight: 42, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 8)
                    .fill(
                        targetedDropTarget == target
                            ? Color.accentColor.opacity(0.12)
                            : Color.clear
                    )
            }
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(
                        targetedDropTarget == target
                            ? Color.accentColor.opacity(0.8)
                            : Color.clear,
                        style: StrokeStyle(lineWidth: 1, dash: [4])
                    )
            }
            .contentShape(Rectangle())
            .dropDestination(for: String.self) { encodedPayloads, _ in
                guard
                    let encodedPayload = encodedPayloads.first,
                    let payload = VocabularyWordDragPayload(encoded: encodedPayload),
                    let word = vocabularyWords.first(where: {
                        $0.word == payload.term && $0.sectionID == payload.sectionID
                    })
                else {
                    return false
                }

                targetedDropTarget = nil
                guard word.sectionID != target.sectionID else { return true }
                return moveWord(word, to: target.sectionID)
            } isTargeted: { isTargeted in
                withAnimation(.easeInOut(duration: 0.15)) {
                    if isTargeted {
                        targetedDropTarget = target
                    } else if targetedDropTarget == target {
                        targetedDropTarget = nil
                    }
                }
            }
    }

    @ViewBuilder
    private func sectionWordFlow(_ words: [VocabularyWord]) -> some View {
        if words.isEmpty {
            Text("Drop terms here")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
        } else {
            wordFlow(words)
        }
    }

    private func wordFlow(_ words: [VocabularyWord]) -> some View {
        FlowLayout(spacing: 8) {
            ForEach(words) { item in
                VocabularyWordView(
                    item: item,
                    isEditing: Binding(
                        get: { editedWord?.persistentModelID == item.persistentModelID },
                        set: { editedWord = $0 ? item : nil }
                    ),
                    onDelete: { removeWord(item) }
                )
                .contentShape(Rectangle())
                .draggable(
                    VocabularyWordDragPayload(term: item.word, sectionID: item.sectionID).encoded
                ) {
                    Color.clear
                        .frame(width: 1, height: 1)
                }
                .help("Drag to move this term to another section")
            }
        }
        .padding(.vertical, 4)
    }

    private func moveWord(_ word: VocabularyWord, to sectionID: UUID?) -> Bool {
        if let error = VocabularySectionService.move(word, to: sectionID, context: modelContext) {
            alertMessage = error
            showAlert = true
            return false
        }
        return true
    }

    private func addWords() {
        let input = newWord.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return }
        if let error = DictionaryService.addVocabularyWords(
            input,
            existing: Array(vocabularyWords),
            context: modelContext,
            sectionID: selectedSectionID.flatMap { id in
                vocabularySections.contains(where: { $0.id == id }) ? id : nil
            },
            soundsLike: newSoundsLike)
        {
            alertMessage = error
            showAlert = true
            return
        }
        newWord = ""
        newSoundsLike = ""
        focusedField = .word
    }

    private func removeWord(_ word: VocabularyWord) {
        if let error = DictionaryService.removeVocabularyWord(word, context: modelContext) {
            alertMessage = error
            showAlert = true
        }
    }
}

struct VocabularyInfoPopover: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("How to use Vocabulary")
                .font(.headline)

            Text(
                "Vocabulary helps supported transcription models and AI enhancement preserve important names, technical terms, and unique spellings."
            )
            .font(.subheadline)
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            Text("Add one entry at a time, or paste multiple entries separated by commas.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text(
                "Sounds like lists comma-separated spellings a transcript may show instead of one term. AI enhancement uses them to restore the term; transcription and word replacements do not. Click a term to edit its spellings."
            )
            .font(.subheadline)
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            Divider()

            Text("Examples")
                .font(.subheadline)
                .foregroundColor(.secondary)

            Text(verbatim: "Prakash, VoiceInk, SwiftData, WebSocket")
                .font(.callout)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.textBackgroundColor))
                .cornerRadius(6)

            Text(verbatim: "VoiceInk — voice ink, voicing")
                .font(.callout)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.textBackgroundColor))
                .cornerRadius(6)
        }
        .padding()
        .frame(width: 320)
    }
}

struct VocabularyWordView: View {
    let item: VocabularyWord
    @Binding var isEditing: Bool
    let onDelete: () -> Void

    private var soundsLikeSummary: String {
        item.soundsLike.joined(separator: ", ")
    }

    var body: some View {
        DictionaryPill(onRemove: onDelete, removeHelp: "Remove word") {
            Button {
                isEditing = true
            } label: {
                HStack(spacing: 4) {
                    Text(item.word)
                        .lineLimit(1)
                    if !item.soundsLike.isEmpty {
                        Text(verbatim: "≈ \(soundsLikeSummary)")
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(maxWidth: 160, alignment: .leading)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(item.word)
            .accessibilityValue(
                item.soundsLike.isEmpty ? "" : String(localized: "Sounds like \(soundsLikeSummary)")
            )
            .accessibilityHint("Edit sounds like spellings")
            .popover(isPresented: $isEditing, arrowEdge: .bottom) {
                VocabularySoundsLikeEditor(word: item)
            }
        }
    }
}

struct VocabularySoundsLikeLimitNote: View {
    var body: some View {
        Text(
            "Only the first \(VocabularySoundsLike.maximumCount) spellings of up to \(VocabularySoundsLike.maximumLength) characters are kept."
        )
        .font(.system(size: 12))
        .foregroundStyle(.red)
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct VocabularySoundsLikeEditor: View {
    let word: VocabularyWord

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @State private var soundsLike: String
    @State private var errorMessage: String?
    @FocusState private var isFieldFocused: Bool

    init(word: VocabularyWord) {
        self.word = word
        _soundsLike = State(initialValue: VocabularySoundsLike.serialize(word.soundsLike))
    }

    private var exceedsLimits: Bool {
        VocabularySoundsLike.normalize(VocabularySoundsLike.parse(soundsLike), term: word.word).wasClamped
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(word.word)
                .font(.headline)
                .lineLimit(2)
            TextField("Sounds like", text: $soundsLike, prompt: Text("voice ink, voicing"))
                .textFieldStyle(.roundedBorder)
                .focused($isFieldFocused)
                .onSubmit(save)
            Text("Comma-separated spellings a transcript may show instead. AI enhancement uses them to restore this term.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if exceedsLimits {
                VocabularySoundsLikeLimitNote()
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        .frame(width: 320)
        .onAppear { isFieldFocused = true }
    }

    private func save() {
        errorMessage = DictionaryService.updateVocabularySoundsLike(
            word, soundsLike: soundsLike, context: modelContext
        )
        if errorMessage == nil { dismiss() }
    }
}
