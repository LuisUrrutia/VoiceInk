import SwiftUI

struct TranscriptionLanguagePicker: View {
    @Binding var selection: [String]
    let model: any TranscriptionModel

    private var availableLanguages: [(key: String, value: String)] {
        TranscriptionLanguageSupport.languages(for: model).sorted {
            if ($0.key == "auto") != ($1.key == "auto") { return $0.key == "auto" }
            return $0.value.localizedCaseInsensitiveCompare($1.value) == .orderedAscending
        }
    }

    private var displayName: String {
        let languages = TranscriptionLanguageSupport.languages(for: model)
        return selection.map { languages[$0] ?? $0 }.joined(separator: " + ")
    }

    var body: some View {
        if TranscriptionLanguageSupport.supportsMultipleSelection(for: model) {
            Menu {
                ForEach(availableLanguages, id: \.key) { code, name in
                    Toggle(name, isOn: Binding(
                        get: { selection.contains(code) },
                        set: { isSelected in
                            selection = TranscriptionLanguageSupport.settingLanguage(
                                code, isSelected: isSelected, in: selection)
                        }
                    ))
                    .disabled(selection == [code])
                }
            } label: {
                if selection.count > 2 {
                    Text("\(selection.count) languages")
                } else {
                    Text(displayName)
                        .lineLimit(1)
                }
            }
            .accessibilityLabel("Transcription languages")
            .accessibilityValue(displayName)
            .help(displayName)
        } else {
            Picker("Transcription language", selection: Binding(
                get: { selection.first ?? "en" },
                set: { selection = [$0] }
            )) {
                ForEach(availableLanguages, id: \.key) { code, name in
                    Text(name).tag(code)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .accessibilityLabel("Transcription language")
        }
    }
}
