import AppKit
import Combine
import SwiftUI

/// A small floating capsule that shows a meeting is recording, with its elapsed time and Stop on hover.
/// It never takes focus, and asks to stay out of screen sharing.
@MainActor
final class MeetingIndicatorController {
    static let shared = MeetingIndicatorController()

    private var panel: NSPanel?
    private var cancellables = Set<AnyCancellable>()

    func start(recorder: MeetingRecorder = .shared, defaults: UserDefaults = .standard) {
        guard cancellables.isEmpty else { return }
        recorder.$activeMeeting.map { $0 != nil }.removeDuplicates()
            .combineLatest(
                NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification, object: defaults)
                    .map { _ in MeetingSettings.showsRecordingIndicator(in: defaults) }
                    .prepend(MeetingSettings.showsRecordingIndicator(in: defaults))
                    .removeDuplicates()
            )
            .sink { [weak self] isRecording, showsIndicator in
                if isRecording && showsIndicator { self?.show(recorder: recorder) } else { self?.hide() }
            }
            .store(in: &cancellables)
    }

    private func show(recorder: MeetingRecorder) {
        guard panel == nil else { return }
        let hosting = NSHostingView(rootView: MeetingIndicatorView(recorder: recorder))
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
        panel.isMovableByWindowBackground = true
        panel.sharingType = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: frame.maxX - size.width - 16, y: frame.maxY - size.height - 12))
        }
        panel.orderFrontRegardless()
        self.panel = panel
    }

    private func hide() {
        panel?.close()
        panel = nil
    }
}

private struct MeetingIndicatorView: View {
    @ObservedObject var recorder: MeetingRecorder
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(Color.red).frame(width: 8, height: 8).accessibilityHidden(true)
            Text(recorder.activeMeeting?.title ?? "")
                .lineLimit(1).frame(maxWidth: 160, alignment: .leading)
            if let startedAt = recorder.recordingStartedAt {
                Text(startedAt, style: .timer).monospacedDigit().foregroundStyle(.secondary)
            }
            if isHovering {
                Button("Stop") { Task { _ = await recorder.stop() } }
                    .controlSize(.small)
                    .disabled(recorder.isStopping)
            }
        }
        .font(.system(size: 12, weight: .medium))
        .padding(.horizontal, 12).padding(.vertical, 7)
        .frame(width: 280, alignment: .leading)
        .background(.regularMaterial, in: Capsule())
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Recording meeting"))
    }
}
