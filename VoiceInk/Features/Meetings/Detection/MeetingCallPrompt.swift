import AppKit
import SwiftUI

/// Focus-free offers about a detected call. Answers arrive through the callback once; a dismissed offer answers
/// with its timeout value.
@MainActor
protocol MeetingCallPrompting: AnyObject {
    func offerRecording(_ provider: MeetingProvider, timeout: Duration, answer: @escaping @MainActor (MeetingCallPromptAnswer) -> Void)
    func offerStop(_ provider: MeetingProvider, answer: @escaping @MainActor (MeetingCallPromptAnswer) -> Void)
    func showStartedAutomatically(_ provider: MeetingProvider)
    func dismiss()
}

enum MeetingCallPromptAnswer: Equatable {
    case record, notNow, neverOffer, keepRecording, stop
}

/// A non-activating capsule near the top-right corner, excluded from screen sharing like the recording indicator.
@MainActor
final class MeetingCallPromptPanel: MeetingCallPrompting {
    static let shared = MeetingCallPromptPanel()

    private var panel: NSPanel?
    private var timeoutTask: Task<Void, Never>?
    private var pendingAnswer: (@MainActor (MeetingCallPromptAnswer) -> Void)?

    func offerRecording(
        _ provider: MeetingProvider, timeout: Duration, answer: @escaping @MainActor (MeetingCallPromptAnswer) -> Void
    ) {
        present(
            title: String(format: String(localized: "%@ is on a call. Record it?"), provider.displayName),
            buttons: [
                (String(localized: "Record"), .record),
                (String(localized: "Not now"), .notNow),
                (String(format: String(localized: "Never for %@"), provider.displayName), .neverOffer),
            ],
            answer: answer
        )
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            self?.finish(.notNow)
        }
    }

    func offerStop(_ provider: MeetingProvider, answer: @escaping @MainActor (MeetingCallPromptAnswer) -> Void) {
        present(
            title: String(format: String(localized: "%@ left the call."), provider.displayName),
            buttons: [(String(localized: "Keep recording"), .keepRecording), (String(localized: "Stop & Transcribe"), .stop)],
            answer: answer
        )
    }

    func showStartedAutomatically(_ provider: MeetingProvider) {
        NotificationManager.shared.showNotification(
            title: String(format: String(localized: "Recording %@. Started automatically."), provider.callName),
            type: .info, duration: 10, playsSound: false
        )
    }

    func dismiss() {
        timeoutTask?.cancel()
        timeoutTask = nil
        pendingAnswer = nil
        panel?.close()
        panel = nil
    }

    private func finish(_ answer: MeetingCallPromptAnswer) {
        let callback = pendingAnswer
        dismiss()
        callback?(answer)
    }

    private func present(
        title: String, buttons: [(String, MeetingCallPromptAnswer)],
        answer: @escaping @MainActor (MeetingCallPromptAnswer) -> Void
    ) {
        dismiss()
        pendingAnswer = answer
        let view = MeetingCallPromptView(title: title, buttons: buttons) { [weak self] in self?.finish($0) }
        let hosting = NSHostingView(rootView: view)
        let size = hosting.fittingSize
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.contentView = hosting
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.sharingType = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: frame.maxX - size.width - 16, y: frame.maxY - size.height - 52))
        }
        panel.orderFrontRegardless()
        self.panel = panel
        NSAccessibility.post(
            element: NSApp as Any, notification: .announcementRequested,
            userInfo: [.announcement: title, .priority: NSAccessibilityPriorityLevel.high.rawValue]
        )
    }
}

private struct MeetingCallPromptView: View {
    let title: String
    let buttons: [(String, MeetingCallPromptAnswer)]
    let choose: (MeetingCallPromptAnswer) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 13, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                ForEach(Array(buttons.enumerated()), id: \.offset) { index, button in
                    if index == 0 {
                        Button(button.0) { choose(button.1) }.buttonStyle(.borderedProminent)
                    } else {
                        Button(button.0) { choose(button.1) }
                    }
                }
            }
            .controlSize(.small)
        }
        .padding(14)
        .frame(width: 320, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }
}
