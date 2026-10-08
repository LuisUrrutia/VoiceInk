import CoreGraphics
import Foundation

enum ActiveWindowSelector {
    struct Window: Sendable {
        let windowID: CGWindowID
        let processID: pid_t?
        let title: String?
        let frame: CGRect
        let windowLayer: Int
        let isOnScreen: Bool
    }

    struct FocusedWindow: Sendable {
        let processID: pid_t
        let windowID: CGWindowID?
        let title: String?
        let frame: CGRect?
    }

    private static let frameTolerance: CGFloat = 96

    static func select(
        from windows: [Window],
        focusedWindow: FocusedWindow?,
        excluding currentPID: pid_t
    ) -> Window? {
        let candidates = windows.filter { window in
            guard let processID = window.processID else { return false }
            return processID != currentPID && window.windowLayer == 0 && window.isOnScreen
                && window.frame.width > 0 && window.frame.height > 0
        }

        guard let focusedWindow else { return candidates.first }

        let appWindows = candidates.filter { $0.processID == focusedWindow.processID }
        guard !appWindows.isEmpty else { return candidates.first }

        if let windowID = focusedWindow.windowID,
            let identifiedWindow = appWindows.first(where: { $0.windowID == windowID })
        {
            return identifiedWindow
        }

        if let focusedFrame = focusedWindow.frame,
            let closestWindow = appWindows.min(by: {
                frameDistance($0.frame, focusedFrame) < frameDistance($1.frame, focusedFrame)
            }),
            frameDistance(closestWindow.frame, focusedFrame) <= frameTolerance
        {
            return closestWindow
        }

        if let focusedTitle = normalized(focusedWindow.title),
            let titledWindow = appWindows.first(where: { normalized($0.title) == focusedTitle })
        {
            return titledWindow
        }

        return appWindows.first
    }

    private static func frameDistance(_ first: CGRect, _ second: CGRect) -> CGFloat {
        abs(first.origin.x - second.origin.x) + abs(first.origin.y - second.origin.y)
            + abs(first.size.width - second.size.width) + abs(first.size.height - second.size.height)
    }

    private static func normalized(_ text: String?) -> String? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
