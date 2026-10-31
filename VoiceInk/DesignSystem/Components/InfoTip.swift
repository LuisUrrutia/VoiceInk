import SwiftUI

/// A reusable info tip component that displays helpful information in a popover
struct InfoTip: View {
    // Content configuration
    var message: LocalizedStringKey
    var learnMoreLink: URL?

    // Appearance customization
    var iconName: String = "info.circle"
    var iconSize: Image.Scale = .medium
    var iconColor: Color = .primary
    var width: CGFloat = 280

    // State
    @State private var presentation = InfoTipPresentation()
    @State private var pendingHide: Task<Void, Never>?

    var body: some View {
        Button(action: togglePinned) {
            Image(appSymbol: iconName)
                .imageScale(iconSize)
                .foregroundColor(iconColor)
                .fontWeight(.semibold)
                .padding(5)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("More information")
        .onHover { setHovering($0, over: .icon) }
        .popover(isPresented: tipPresentation) {
            VStack(alignment: .leading, spacing: 0) {
                if learnMoreLink != nil {
                    (Text(message)
                        .foregroundColor(.secondary)
                        + Text(" ")
                        + Text("Learn more")
                        .foregroundColor(AppTheme.Accent.primary))
                        .font(.callout)
                } else {
                    Text(message)
                        .font(.callout)
                        .foregroundColor(.secondary)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: width, alignment: .leading)
            .padding(14)
            .onHover { setHovering($0, over: .tip) }
            .onTapGesture {
                if let url = learnMoreLink {
                    NSWorkspace.shared.open(url)
                }
            }
        }
        .onDisappear { pendingHide?.cancel() }
    }

    private var tipPresentation: Binding<Bool> {
        Binding(
            get: { presentation.isShowing },
            set: { isPresented in
                if !isPresented { presentation.systemDismissed() }
            })
    }

    private func togglePinned() {
        pendingHide?.cancel()
        presentation.togglePinned()
    }

    private func setHovering(_ hovering: Bool, over target: InfoTipPresentation.HoverTarget) {
        pendingHide?.cancel()
        guard presentation.setHovering(hovering, over: target) else { return }
        pendingHide = Task { @MainActor in
            do { try await Task.sleep(for: InfoTipPresentation.hoverGracePeriod) } catch { return }
            presentation.hoverGraceEnded()
        }
    }
}

/// Hover opens a tip and leaving closes it after a grace period; a click pins it until another click or dismissal.
struct InfoTipPresentation: Equatable {
    enum HoverTarget { case icon, tip }

    /// Time to move the pointer from the icon into the popover, which is a separate window.
    static let hoverGracePeriod: Duration = .milliseconds(250)

    private(set) var isShowing = false
    private(set) var isPinned = false
    private var isHoveringIcon = false
    private var isHoveringTip = false

    /// Returns whether to call `hoverGraceEnded()` after the grace period.
    mutating func setHovering(_ hovering: Bool, over target: HoverTarget) -> Bool {
        switch target {
        case .icon: isHoveringIcon = hovering
        case .tip: isHoveringTip = hovering
        }
        if isHoveringIcon || isHoveringTip {
            isShowing = true
            return false
        }
        return isShowing && !isPinned
    }

    mutating func hoverGraceEnded() {
        if !isHoveringIcon && !isHoveringTip && !isPinned { isShowing = false }
    }

    mutating func togglePinned() {
        isPinned = !(isPinned && isShowing)
        isShowing = isPinned
    }

    /// A click outside or Escape also ends a pinned tip.
    mutating func systemDismissed() {
        isShowing = false
        isPinned = false
    }
}

// MARK: - Convenience initializers

extension InfoTip {
    /// Creates an InfoTip with just a message
    init(_ message: LocalizedStringKey) {
        self.message = message
        self.learnMoreLink = nil
    }

    /// Creates an InfoTip with a dynamic string message
    init(_ message: String) {
        self.message = LocalizedStringKey(message)
        self.learnMoreLink = nil
    }

    /// Creates an InfoTip with a learn more link
    init(_ message: LocalizedStringKey, learnMoreURL: String) {
        self.message = message
        self.learnMoreLink = URL(string: learnMoreURL)
    }

    /// Creates an InfoTip with a dynamic string message and learn more link
    init(_ message: String, learnMoreURL: String) {
        self.message = LocalizedStringKey(message)
        self.learnMoreLink = URL(string: learnMoreURL)
    }
}
