import AppKit
import SwiftUI

struct ConfigurationFileSettingsView: View {
    @ObservedObject private var configuration = ConfigurationFileStore.shared

    var body: some View {
        Section {
            LabeledContent("Configuration file") {
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([configuration.fileURL])
                }
            }
            Text(configuration.fileURL.path)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            if let error = configuration.errorMessage {
                Label(error, appSymbol: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text("Portable Configuration")
        } footer: {
            Text("Preferences, modes, prompts, model definitions and the dictionary are saved as JSONC. Quit VoiceInk before editing this file; changes load when you reopen it. API keys stay in Keychain. Model files and History are stored separately.")
        }
    }
}
