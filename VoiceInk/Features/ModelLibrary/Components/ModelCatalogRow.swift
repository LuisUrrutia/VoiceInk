import SwiftUI

struct ModelCatalogRow: View {
    let model: any TranscriptionModel
    let isInstalled: Bool
    let isExpanded: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 12) {
                Image(systemName: isInstalled ? "checkmark.circle.fill" : "waveform").font(.system(size: 18))
                    .foregroundStyle(isInstalled ? Color.accentColor : Color.secondary).frame(width: 28)
                VStack(alignment: .leading, spacing: 5) {
                    Text(model.displayName).font(.system(size: 14, weight: .medium))
                    Text("\(model.provider.rawValue) · \(model.language)").font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .leading, spacing: 7) {
                    rating(ModelCatalogSortOrder.speed.score(for: model), title: "Speed")
                    rating(ModelCatalogSortOrder.accuracy.score(for: model), title: "Accuracy")
                }
                .frame(width: 120, alignment: .leading)

                VStack(alignment: .trailing, spacing: 5) {
                    Text(storageSize).font(.callout)
                    if isInstalled {
                        Text(model.provider == .nativeApple ? "Built in" : "Installed").font(.caption)
                            .foregroundStyle(
                                .secondary)
                    }
                }
                .frame(width: 80, alignment: .trailing)
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right").font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary).frame(width: 20)
            }
            .padding(16).contentShape(Rectangle()).background(isExpanded ? AppTheme.Selection.fill : .clear)
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
                        .frame(width: 16, height: 4)
                }
            } else {
                Text("Not rated").font(.caption).foregroundStyle(.secondary)
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
