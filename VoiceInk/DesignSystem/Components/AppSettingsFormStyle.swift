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
                        .background(AppTranslucentCardBackground())

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
        SettingsRowLayout {
            HStack(alignment: .top, spacing: 16) { configuration.label }
            HStack(alignment: .top, spacing: 16) { configuration.content }
        }
    }
}

/// Puts a row's control at the top trailing edge and wraps its label beside it, as System Settings does. The control
/// moves below the label only when it would leave the label less than `minimumLabelWidth`.
struct SettingsRowLayout: Layout {
    static let spacing: CGFloat = 16
    static let stackedSpacing: CGFloat = 10
    static let minimumLabelWidth: CGFloat = 180

    /// Whether a control of `controlWidth` leaves room for a label of `labelIdealWidth` in `availableWidth`.
    static func isSideBySide(availableWidth: CGFloat, labelIdealWidth: CGFloat, controlWidth: CGFloat) -> Bool {
        availableWidth - controlWidth - spacing >= min(labelIdealWidth, minimumLabelWidth)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let frames = arrange(proposal: proposal, subviews: subviews)
        return CGSize(width: frames.width, height: frames.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let frames = arrange(proposal: ProposedViewSize(width: bounds.width, height: nil), subviews: subviews)
        for (subview, frame) in zip(subviews, [frames.label, frames.control]) {
            subview.place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                proposal: ProposedViewSize(frame.size)
            )
        }
    }

    private func arrange(proposal: ProposedViewSize, subviews: Subviews) -> (
        label: CGRect, control: CGRect, width: CGFloat, height: CGFloat
    ) {
        guard subviews.count == 2 else { return (.zero, .zero, 0, 0) }
        let label = subviews[0]
        let control = subviews[1]
        let labelIdeal = label.sizeThatFits(.unspecified)
        let controlIdeal = control.sizeThatFits(.unspecified)
        let width = proposal.width ?? labelIdeal.width + Self.spacing + controlIdeal.width

        if Self.isSideBySide(availableWidth: width, labelIdealWidth: labelIdeal.width, controlWidth: controlIdeal.width) {
            // Beside a one-line label, a flexible control such as a slider takes about half the free space, as it did
            // beside a spacer; beside a wrapping label it keeps its ideal width.
            let free = width - labelIdeal.width - Self.spacing
            let controlSize = free > controlIdeal.width
                ? control.sizeThatFits(ProposedViewSize(width: max(controlIdeal.width, free / 2), height: nil))
                : controlIdeal
            let labelWidth = width - controlSize.width - Self.spacing
            let labelSize = label.sizeThatFits(ProposedViewSize(width: labelWidth, height: nil))
            return (
                CGRect(x: 0, y: 0, width: labelWidth, height: labelSize.height),
                CGRect(x: width - controlSize.width, y: 0, width: controlSize.width, height: controlSize.height),
                width, max(labelSize.height, controlSize.height)
            )
        }

        let labelSize = label.sizeThatFits(ProposedViewSize(width: width, height: nil))
        let controlSize = control.sizeThatFits(ProposedViewSize(width: width, height: nil))
        let controlY = labelSize.height + Self.stackedSpacing
        return (
            CGRect(x: 0, y: 0, width: width, height: labelSize.height),
            CGRect(x: max(0, width - controlSize.width), y: controlY, width: controlSize.width, height: controlSize.height),
            width, controlY + controlSize.height
        )
    }
}
