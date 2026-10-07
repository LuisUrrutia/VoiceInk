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
                in: .rect(cornerRadius: AppTheme.Radius.control)
            )
        } else {
            background(QuickPanelButtonBackground(isSelected: isSelected))
        }
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
