import SwiftUI

// Define a display mode for flexible usage
enum LanguageDisplayMode {
    case full  // For settings page with descriptions
    case menuItem  // For menu bar with compact layout
}

struct LanguageSelectionView: View {
    @ObservedObject var transcriptionModelManager: TranscriptionModelManager
    @State private var selectedLanguages = UserDefaults.standard.selectedTranscriptionLanguages
    // Add display mode parameter with full as the default
    var displayMode: LanguageDisplayMode = .full
    @ObservedObject var whisperPrompt: WhisperPrompt

    private func updateLanguages(_ languages: [String]) {
        let selection = TranscriptionLanguageSupport.normalizedSelection(languages)
        guard selectedLanguages != selection else { return }
        selectedLanguages = selection
        UserDefaults.standard.selectedTranscriptionLanguages = selection
        NotificationCenter.default.post(name: .languageDidChange, object: nil)
        NotificationCenter.default.post(name: .AppSettingsDidChange, object: nil)
    }

    private func hasLanguageChoices() -> Bool {
        guard let currentModel = transcriptionModelManager.currentTranscriptionModel else {
            return false
        }
        return currentModel.supportedLanguages.count > 1
    }

    private func isNativeAppleModelSelected() -> Bool {
        transcriptionModelManager.currentTranscriptionModel?.provider == .nativeApple
    }

    private func useCompatibleLanguageForCurrentModel() {
        guard let currentModel = transcriptionModelManager.currentTranscriptionModel else { return }
        updateLanguages(TranscriptionLanguageSupport.validLanguagesOrFallback(selectedLanguages, for: currentModel))
    }

    private var selectedLanguagesBinding: Binding<[String]> {
        Binding(
            get: { selectedLanguages },
            set: { updateLanguages($0) }
        )
    }

    private var nativeAppleAssetControl: some View {
        NativeAppleLanguageAssetControl(
            localeIdentifier: selectedLanguages.first ?? "en-US",
            isVisible: true
        )
        .layoutPriority(1)
    }

    var body: some View {
        Group {
            switch displayMode {
            case .full:
                fullView
            case .menuItem:
                menuItemView
            }
        }
        .onAppear {
            selectedLanguages = UserDefaults.standard.selectedTranscriptionLanguages
            useCompatibleLanguageForCurrentModel()
        }
        .onChange(of: transcriptionModelManager.currentTranscriptionModel?.name) { _, _ in
            selectedLanguages = UserDefaults.standard.selectedTranscriptionLanguages
            useCompatibleLanguageForCurrentModel()
        }
        .onReceive(NotificationCenter.default.publisher(for: .AppSettingsDidChange)) { _ in
            selectedLanguages = UserDefaults.standard.selectedTranscriptionLanguages
            useCompatibleLanguageForCurrentModel()
        }
        .onReceive(NotificationCenter.default.publisher(for: .languageDidChange)) { _ in
            selectedLanguages = UserDefaults.standard.selectedTranscriptionLanguages
            useCompatibleLanguageForCurrentModel()
        }
    }

    // The original full view layout for settings page
    private var fullView: some View {
        VStack(alignment: .leading, spacing: 16) {
            languageSelectionSection
        }
    }

    private var languageSelectionSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Transcription Language")
                .font(.headline)

            if let model = transcriptionModelManager.currentTranscriptionModel {
                if hasLanguageChoices() {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            TranscriptionLanguagePicker(selection: selectedLanguagesBinding, model: model)
                            .frame(maxWidth: isNativeAppleModelSelected() ? 280 : .infinity, alignment: .leading)

                            if isNativeAppleModelSelected() {
                                nativeAppleAssetControl
                            }
                        }

                        Text(TranscriptionLanguageSupport.supportsMultipleSelection(for: model)
                            ? "Choose languages to guide Whisper with their prompts. With multiple languages, Whisper detects the language automatically and may recognize other languages."
                            : "Select a supported transcription language or locale.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    }
                } else {
                    // For English-only models, force set language to English
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Language: English")
                            .font(.subheadline)
                            .foregroundColor(.primary)

                        Text(
                            "This is an English-optimized model and only supports English transcription."
                        )
                        .font(.caption)
                        .foregroundColor(.secondary)
                    }
                    .onAppear {
                        // Ensure English is set when viewing English-only model
                        updateLanguages(["en"])
                    }
                }
            } else {
                Text("No model selected")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.Surface.control)
        .cornerRadius(10)
    }

    // New compact view for menu bar
    private var menuItemView: some View {
        Group {
            if hasLanguageChoices(), let model = transcriptionModelManager.currentTranscriptionModel {
                HStack(spacing: 8) {
                    TranscriptionLanguagePicker(selection: selectedLanguagesBinding, model: model)

                    if isNativeAppleModelSelected() {
                        nativeAppleAssetControl
                    }
                }
            } else {
                // For English-only models
                Button {
                    // Do nothing, just showing info
                } label: {
                    Text("Language: English (only)")
                        .foregroundColor(.secondary)
                }
                .disabled(true)
                .onAppear {
                    // Ensure English is set for English-only models
                    updateLanguages(["en"])
                }
            }
        }
    }
}
