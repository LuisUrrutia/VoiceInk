import SwiftUI

struct DashboardGettingStarted: View {
    let hasModes: Bool
    let onNavigate: (ViewType) -> Void

    var body: some View {
        VStack(spacing: 0) {
            row(
                "Choose a model", detail: "Download a model or connect your preferred provider.",
                icon: "books.vertical", destination: .models)
            Divider().padding(.leading, 58)
            row(
                hasModes ? "Customize your modes" : "Create your first mode",
                detail: "Choose how VoiceInk transcribes and formats your speech.", icon: "sparkles",
                destination: .modes)
            Divider().padding(.leading, 58)
            row(
                "Set your shortcuts", detail: "Start dictating from anywhere with a keyboard shortcut.",
                icon: "command", destination: .settings)
            Divider().padding(.leading, 58)
            row(
                "Add your vocabulary", detail: "Keep names, technical terms, and unique spellings accurate.",
                icon: "character.book.closed", destination: .dictionary)
        }
        .background(AppCardBackground())
    }

    private func row(_ title: LocalizedStringKey, detail: LocalizedStringKey, icon: String, destination: ViewType)
        -> some View
    {
        Button {
            onNavigate(destination)
        } label: {
            HStack(spacing: 14) {
                Image(systemName: icon).font(.system(size: 18)).foregroundStyle(.secondary).frame(width: 24)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 14, weight: .medium))
                    Text(detail).font(.callout).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 20).padding(.vertical, 15).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
