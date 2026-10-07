import SwiftUI

struct AppSettingsFormStyle: FormStyle {
    func makeBody(configuration: Configuration) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                ForEach(sections: configuration.content) { section in
                    VStack(alignment: .leading, spacing: 10) {
                        if !section.header.isEmpty {
                            section.header
                                .font(.headline)
                                .padding(.horizontal, 12)
                        }

                        VStack(spacing: 0) {
                            ForEach(subviews: section.content) { row in
                                row
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 12)

                                if row.id != section.content.last?.id {
                                    Divider().padding(.horizontal, 12)
                                }
                            }
                        }
                        .background(AppSettingsCardBackground())

                        if !section.footer.isEmpty {
                            section.footer
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 12)
                        }
                    }
                }
            }
            .padding(24)
        }
        .labeledContentStyle(AppSettingsLabeledContentStyle())
        .toggleStyle(.switch)
        .pickerStyle(.menu)
        .appGlassButtonStyle()
    }
}

private struct AppSettingsLabeledContentStyle: LabeledContentStyle {
    func makeBody(configuration: Configuration) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 16) {
                configuration.label
                Spacer(minLength: 16)
                configuration.content
            }

            VStack(alignment: .leading, spacing: 10) {
                configuration.label
                configuration.content.frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }
}

private struct AppSettingsCardBackground: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        RoundedRectangle(cornerRadius: AppTheme.Radius.card)
            .fill(reduceTransparency ? AnyShapeStyle(opaqueFill) : AnyShapeStyle(.regularMaterial))
            .overlay {
                if !reduceTransparency {
                    RoundedRectangle(cornerRadius: AppTheme.Radius.card)
                        .fill(.white.opacity(colorScheme == .light ? 0.60 : 0.06))
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: AppTheme.Radius.card)
                    .strokeBorder(.primary.opacity(contrast == .increased ? 0.30 : 0.08))
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private var opaqueFill: Color {
        colorScheme == .light ? .white : AppTheme.Surface.card
    }
}
