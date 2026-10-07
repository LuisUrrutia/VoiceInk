import SwiftUI

extension View {
    func appHoverHighlight(cornerRadius: CGFloat = 10) -> some View {
        modifier(AppHoverHighlight(cornerRadius: cornerRadius))
    }
}

private struct AppHoverHighlight: ViewModifier {
    let cornerRadius: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .background(isHovered ? AppTheme.Selection.fill : .clear,
                        in: RoundedRectangle(cornerRadius: cornerRadius))
            .onHover { isHovered = $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isHovered)
    }
}
