import SwiftUI

struct DashboardGettingStarted: View {
    let hasModes: Bool
    let onNavigate: (ViewType) -> Void

    var body: some View {
        VStack(spacing: 4) {
            row(
                "Choose a model", detail: "Download a model or connect your preferred provider.",
                icon: "books.vertical", destination: .models)
            row(
                hasModes ? "Customize your modes" : "Create your first mode",
                detail: "Choose how VoiceInk transcribes and formats your speech.", icon: "sparkles",
                destination: .modes)
            row(
                "Set your shortcuts", detail: "Start dictating from anywhere with a keyboard shortcut.",
                icon: "command", destination: .settings)
            row(
                "Add your vocabulary", detail: "Keep names, technical terms, and unique spellings accurate.",
                icon: "character.book.closed", destination: .dictionary)
        }
    }

    private func row(_ title: LocalizedStringKey, detail: LocalizedStringKey, icon: String, destination: ViewType)
        -> some View
    {
        Button {
            onNavigate(destination)
        } label: {
            HStack(spacing: 14) {
                Image(systemName: icon).font(.system(size: 14)).foregroundStyle(.secondary).frame(width: 24)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 14, weight: .medium))
                    Text(detail).font(.callout).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
            }
            .padding(.horizontal, 16).padding(.vertical, 10).contentShape(Rectangle())
            .appHoverHighlight()
        }
        .buttonStyle(.plain)
    }
}
