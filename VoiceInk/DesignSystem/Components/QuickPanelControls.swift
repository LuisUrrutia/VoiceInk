import SwiftUI

enum QuickPanelEdge {
    case top
    case bottom
}

enum QuickPanelMetrics {
    static let headerHeight: CGFloat = 56
    static let footerHeight: CGFloat = 48
    static let edgePadding: CGFloat = 8

    static let topEdgeHeight = headerHeight + edgePadding
    static let bottomEdgeHeight = footerHeight + edgePadding
}

// Callers own scroll insets so headers and footers remain visible while scrolling.
struct QuickPanelScaffold<Content: View, Header: View, Footer: View>: View {
    private let content: Content
    private let header: Header
    private let footer: Footer?
    private let footerHeight: CGFloat
    private let inheritsContentBackground: Bool

    init(
        footerHeight: CGFloat = QuickPanelMetrics.footerHeight,
        inheritsContentBackground: Bool = false,
        @ViewBuilder content: () -> Content,
        @ViewBuilder header: () -> Header,
        @ViewBuilder footer: () -> Footer
    ) {
        self.content = content()
        self.header = header()
        self.footer = footer()
        self.footerHeight = footerHeight
        self.inheritsContentBackground = inheritsContentBackground
    }

    var body: some View {
        ZStack {
            content

            VStack(spacing: 0) {
                QuickPanelScrollEdge(edge: .top, inheritsContentBackground: inheritsContentBackground) {
                    header
                }

                Spacer(minLength: 0)

                if let footer {
                    QuickPanelScrollEdge(
                        edge: .bottom,
                        contentHeight: footerHeight,
                        inheritsContentBackground: inheritsContentBackground
                    ) {
                        footer
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(inheritsContentBackground ? .clear : AppTheme.Surface.window)
    }
}

extension QuickPanelScaffold where Footer == EmptyView {
    init(
        inheritsContentBackground: Bool = false,
        @ViewBuilder content: () -> Content,
        @ViewBuilder header: () -> Header
    ) {
        self.content = content()
        self.header = header()
        self.footer = nil
        self.footerHeight = QuickPanelMetrics.footerHeight
        self.inheritsContentBackground = inheritsContentBackground
    }
}

struct QuickPanelScrollEdge<Content: View>: View {
    let edge: QuickPanelEdge
    var contentHeight: CGFloat? = nil
    var inheritsContentBackground = false
    @ViewBuilder let content: () -> Content

    private var edgeHeight: CGFloat {
        let height = contentHeight ?? (edge == .top
            ? QuickPanelMetrics.headerHeight
            : QuickPanelMetrics.footerHeight)
        return height + QuickPanelMetrics.edgePadding
    }

    var body: some View {
        AppGlassContainer {
            content()
        }
        .padding(edge == .top ? .top : .bottom, QuickPanelMetrics.edgePadding)
        .frame(height: edgeHeight)
        .frame(maxWidth: .infinity)
        .background {
            Group {
                if inheritsContentBackground {
                    AppContentBackground()
                } else {
                    AppTheme.Surface.window
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}

struct QuickPanelButtonBackground: View {
    var isSelected = false

    var body: some View {
        RoundedRectangle(cornerRadius: AppTheme.Radius.control, style: .continuous)
            .fill(AppTheme.Surface.control)
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: AppTheme.Radius.control, style: .continuous)
                        .fill(AppTheme.Selection.fill)
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: AppTheme.Radius.control, style: .continuous)
                    .strokeBorder(
                        isSelected ? AppTheme.Selection.border : AppTheme.Border.card,
                        lineWidth: isSelected ? 1.5 : 1
                    )
            }
    }
}

struct QuickPanelEscapeButton: View {
    let help: LocalizedStringKey
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text("esc")
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(AppTheme.Text.secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(AppTheme.Surface.controlActive, in: RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel("Escape")
        .accessibilityHint(help)
    }
}
