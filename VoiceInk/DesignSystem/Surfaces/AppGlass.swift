import SwiftUI

struct AppGlassContainer<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: 8, content: content)
        } else {
            content()
        }
    }
}

extension View {
    func appNavigationSurface() -> some View {
        modifier(AppNavigationSurface())
    }

    @ViewBuilder
    func appGlassControl(isSelected: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(
                .regular.tint(isSelected ? AppTheme.Selection.fill : nil).interactive(),
                in: .capsule
            )
        } else {
            background(QuickPanelButtonBackground(isSelected: isSelected))
        }
    }

    /// Card surface shared by mode cards and the Home cards. Only whole-card buttons should be interactive.
    func appGlassCard(isSelected: Bool = false, isInteractive: Bool = false) -> some View {
        modifier(AppGlassCardSurface(isSelected: isSelected, isInteractive: isInteractive))
    }
}

private struct AppGlassCardSurface: ViewModifier {
    let isSelected: Bool
    let isInteractive: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        Group {
            if reduceTransparency {
                content.background(AppTheme.Surface.card, in: .rect(cornerRadius: 16))
            } else if #available(macOS 26.0, *) {
                content.glassEffect(.regular.interactive(isInteractive), in: .rect(cornerRadius: 16))
            } else {
                content.background(.thinMaterial, in: .rect(cornerRadius: 16))
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .stroke(
                    AppMaterialCardBackground.border(for: isSelected),
                    lineWidth: AppMaterialCardBackground.lineWidth(for: isSelected)
                )
                .allowsHitTesting(false)
        }
        .contentShape(RoundedRectangle(cornerRadius: 16))
    }
}

private struct AppNavigationSurface: ViewModifier {
    func body(content: Content) -> some View {
        GeometryReader { geometry in
            if #available(macOS 26.0, *) {
                content
                    .padding(.top, geometry.safeAreaInsets.top)
                    .glassEffect(.regular, in: .rect(cornerRadius: 0))
                    .ignoresSafeArea(.container, edges: .top)
            } else {
                content.background {
                    VisualEffectView(material: .sidebar, blendingMode: .behindWindow)
                        .ignoresSafeArea(.container, edges: .top)
                }
            }
        }
    }
}
