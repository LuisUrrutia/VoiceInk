import SwiftUI

struct ModelCatalogRow: View {
    let model: any TranscriptionModel
    let isInstalled: Bool
    let isExpanded: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 10) {
                ModelProviderIcon(modelName: model.name, kind: .transcription, size: 24)
                    .accessibilityHidden(true)
                HStack(spacing: 6) {
                    Text(model.displayName).font(.system(size: 13))
                    if model.language == "English" {
                        Text("EN").font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary)
                            .padding(.horizontal, 4).padding(.vertical, 2)
                            .background(AppTheme.Surface.subtle, in: RoundedRectangle(cornerRadius: 4))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "waveform").foregroundStyle(.secondary)
                    .frame(width: 26, height: 24)
                    .background(AppTheme.Surface.subtle, in: RoundedRectangle(cornerRadius: 6))
                    .accessibilityLabel("Speech model")

                VStack(alignment: .leading, spacing: 4) {
                    rating(ModelCatalogSortOrder.speed.score(for: model), title: "Speed")
                    rating(ModelCatalogSortOrder.accuracy.score(for: model), title: "Accuracy")
                }
                .frame(width: 102, alignment: .leading)

                Text(model.provider == .nativeApple ? String(localized: "Built in") : storageSize)
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .frame(width: 80, alignment: .trailing)
                Image(systemName: isExpanded ? "chevron.up" : (isInstalled ? "checkmark" : "arrow.down.circle"))
                    .font(.system(size: 14))
                    .foregroundStyle(isInstalled ? Color.accentColor : Color.secondary).frame(width: 24)
            }
            .frame(minHeight: 40).padding(.horizontal, 10).contentShape(Rectangle())
            .background(isExpanded ? AppTheme.Selection.fill : .clear, in: RoundedRectangle(cornerRadius: 10))
            .appHoverHighlight()
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            "\(model.displayName), \(isInstalled ? String(localized: "Installed") : storageSize)"
        )
        .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
        .accessibilityHint(
            "Show model details and download controls")
    }

    private func rating(_ value: Double?, title: LocalizedStringKey) -> some View {
        HStack(spacing: 3) {
            if let value {
                ForEach(0..<5) { index in
                    Capsule()
                        .fill(
                            Double(index) < (value * 5).rounded() ? Color.secondary : Color.secondary.opacity(0.18)
                        )
                        .frame(width: 14, height: 2)
                }
            } else {
                Text("—").font(.caption).foregroundStyle(.tertiary)
            }
        }
        .accessibilityElement(children: .ignore).accessibilityLabel(title)
        .accessibilityValue(
            value.map { String(Int(($0 * 10).rounded())) + " / 10" } ?? String(localized: "Not rated"))
    }

    private var storageSize: String {
        switch model {
        case let model as WhisperModel: model.size
        case let model as FluidAudioModel: model.size
        case let model as TranscribeCppModel: model.size
        default: "—"
        }
    }
}
