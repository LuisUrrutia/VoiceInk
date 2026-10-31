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
    @State private var isShowingTip: Bool = false
    @State private var isPinned = false
    @State private var isHoveringIcon = false
    @State private var isHoveringTip = false
    @State private var pendingHide: Task<Void, Never>?

    var body: some View {
        Image(appSymbol: iconName)
            .imageScale(iconSize)
            .foregroundColor(iconColor)
            .fontWeight(.semibold)
            .padding(5)
            .contentShape(Rectangle())
            .onHover { hovering in
                isHoveringIcon = hovering
                updateHoverPresentation()
            }
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
                .onHover { hovering in
                    isHoveringTip = hovering
                    updateHoverPresentation()
                }
                .onTapGesture {
                    if let url = learnMoreLink {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
            .onTapGesture(perform: togglePinned)
            .accessibilityElement()
            .accessibilityLabel("More information")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { togglePinned() }
            .onDisappear { pendingHide?.cancel() }
    }

    /// A system dismissal (click outside, Escape) also ends a pinned tip.
    private var tipPresentation: Binding<Bool> {
        Binding(
            get: { isShowingTip },
            set: { isPresented in
                isShowingTip = isPresented
                if !isPresented { isPinned = false }
            })
    }

    private func togglePinned() {
        pendingHide?.cancel()
        isPinned = !(isPinned && isShowingTip)
        isShowingTip = isPinned
    }

    private func updateHoverPresentation() {
        pendingHide?.cancel()
        if isHoveringIcon || isHoveringTip {
            isShowingTip = true
            return
        }
        guard !isPinned else { return }
        // Leave time to move the pointer from the icon into the popover, which is a separate window.
        pendingHide = Task { @MainActor in
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            if !isHoveringIcon && !isHoveringTip && !isPinned { isShowingTip = false }
        }
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
