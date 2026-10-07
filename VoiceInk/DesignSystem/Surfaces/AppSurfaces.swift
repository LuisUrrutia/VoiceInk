import SwiftUI

struct AppContentBackground: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        Group {
            if reduceTransparency {
                AppTheme.Surface.window
            } else {
                VisualEffectView(material: .underWindowBackground, blendingMode: .behindWindow)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

struct AppCardBackground: View {
    var isSelected: Bool = false
    var cornerRadius: CGFloat = AppTheme.Radius.card

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(AppTheme.Surface.card)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(
                        isSelected ? AppTheme.Selection.border : AppTheme.Border.subtle,
                        lineWidth: isSelected ? 1.5 : 1
                    )
            )
    }
}

struct AppMaterialCardBackground: View {
    var isSelected: Bool = false
    var cornerRadius: CGFloat = AppTheme.Radius.card

    static let fill = AppTheme.Surface.materialCard

    static func border(for isSelected: Bool) -> Color {
        isSelected ? AppTheme.Selection.border : AppTheme.Border.card
    }

    static func lineWidth(for isSelected: Bool) -> CGFloat {
        isSelected ? 1.5 : 1
    }

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(Self.fill)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(
                        Self.border(for: isSelected),
                        lineWidth: Self.lineWidth(for: isSelected)
                    )
            )
    }
}

struct AppTranslucentCardBackground: View {
    var cornerRadius: CGFloat = AppTheme.Radius.card

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(reduceTransparency ? AnyShapeStyle(opaqueFill) : AnyShapeStyle(.regularMaterial))
            .overlay {
                if !reduceTransparency {
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .fill(.white.opacity(colorScheme == .light ? 0.60 : 0.06))
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(.primary.opacity(contrast == .increased ? 0.30 : 0.08))
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private var opaqueFill: Color {
        colorScheme == .light ? .white : AppTheme.Surface.card
    }
}

struct MetricTintBackground: View {
    let color: Color
    var cornerRadius: CGFloat = AppTheme.Radius.card

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(
                LinearGradient(
                    gradient: Gradient(stops: [
                        .init(color: color.opacity(0.15), location: 0),
                        .init(color: AppTheme.Surface.window.opacity(0.1), location: 0.6),
                    ]),
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(
                        LinearGradient(
                            gradient: Gradient(colors: [
                                AppTheme.Border.subtle,
                                AppTheme.Border.subtle.opacity(0.4),
                            ]),
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 1
                    )
            )
            .shadow(color: Color.black.opacity(0.05), radius: 5, y: 3)
    }
}
