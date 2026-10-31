import AppKit
import Combine
import SwiftUI

struct AnnotationsView: View {
    @ObservedObject private var recorder = AnnotationRecorder.shared
    @ObservedObject private var processor = AnnotationProcessor.shared

    var body: some View {
        Form {
            Section {
                if recorder.isRecording {
                    LabeledContent {
                        HStack {
                            Button("Stop") { Task { await recorder.stop() } }.disabled(recorder.isStopping)
                            Button("Cancel", role: .cancel) { Task { await recorder.cancel() } }
                        }
                    } label: {
                        if let startedAt = recorder.recordingStartedAt {
                            Text(startedAt, style: .timer).monospacedDigit()
                        }
                    }
                } else {
                    LabeledContent("Record the screen under the pointer") {
                        Button("Annotate") { Task { await recorder.toggle() } }.disabled(recorder.isStarting)
                    }
                }
                LabeledContent("Shortcut") { ShortcutRecorder(action: .toggleAnnotate) }
            } header: {
                Text("Annotate")
            } footer: {
                Text("Show and tell: VoiceInk records the display under the pointer while you narrate, for up to 20 minutes. When you stop, it transcribes the narration on this Mac and copies a summary that names the bundle's folder, for a local AI agent. VoiceInk's own windows are not recorded, and dictation waits until you stop.")
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Annotations") {
                if recorder.annotations.isEmpty {
                    Text("No annotations yet.").foregroundStyle(.secondary)
                } else {
                    ForEach(recorder.annotations) { annotation in
                        AnnotationRow(annotation: annotation, isProcessing: processor.processingID == annotation.id)
                    }
                }
            }
        }
        .formStyle(AppSettingsFormStyle())
        .onAppear { recorder.reload() }
    }
}

private struct AnnotationRow: View {
    let annotation: AnnotationManifest
    let isProcessing: Bool
    @ObservedObject private var recorder = AnnotationRecorder.shared

    var body: some View {
        LabeledContent {
            HStack {
                if annotation.status == .ready {
                    Button {
                        let url = recorder.store.url(for: annotation.id, file: AnnotationManifest.summaryFileName)
                        guard let summary = try? String(contentsOf: url, encoding: .utf8) else { return }
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(summary, forType: .string)
                    } label: {
                        Image(appSymbol: "doc.on.doc")
                    }
                    .help("Copy for an agent")
                    .accessibilityLabel("Copy for an agent")
                }
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([recorder.store.directory(for: annotation.id)])
                } label: {
                    Image(appSymbol: "folder")
                }
                .help("Show in Finder")
                .accessibilityLabel("Show in Finder")
                Button(role: .destructive) { recorder.delete(annotation) } label: { Image(appSymbol: "trash") }
                    .disabled(annotation.id == recorder.activeAnnotation?.id)
                    .help("Move to Trash")
                    .accessibilityLabel("Move to Trash")
            }
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(annotation.createdAt.formatted(date: .abbreviated, time: .shortened))
                Text(detail).settingsDescription()
            }
        }
    }

    private var detail: String {
        let status: String = switch annotation.status {
        case .recording: String(localized: "Recording")
        case .processing: isProcessing ? String(localized: "Transcribing") : String(localized: "Waiting")
        case .ready: String(localized: "Ready")
        case .failed: String(localized: "Failed")
        }
        return [MeetingMarkdown.timestamp(annotation.duration), status, annotation.failure].compactMap { $0 }.joined(separator: " · ")
    }
}

/// A capsule with the elapsed time, Stop and Cancel while an annotation records; it is not in the recording.
@MainActor
final class AnnotationCapsuleController {
    static let shared = AnnotationCapsuleController()

    private var panel: NSPanel?
    private var cancellable: AnyCancellable?

    func start(recorder: AnnotationRecorder = .shared) {
        guard cancellable == nil else { return }
        cancellable = recorder.$activeAnnotation.map { $0 != nil }.removeDuplicates().sink { [weak self] isRecording in
            MainActor.assumeIsolated { isRecording ? self?.show(recorder) : self?.hide() }
        }
    }

    private func show(_ recorder: AnnotationRecorder) {
        guard panel == nil else { return }
        let hosting = NSHostingView(rootView: AnnotationCapsule(recorder: recorder))
        let size = hosting.fittingSize
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
            defer: false
        )
        panel.contentView = hosting
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.minY + 24))
        }
        panel.orderFrontRegardless()
        self.panel = panel
    }

    private func hide() {
        panel?.close()
        panel = nil
    }
}

private struct AnnotationCapsule: View {
    @ObservedObject var recorder: AnnotationRecorder

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(Color.red).frame(width: 8, height: 8).accessibilityHidden(true)
            if let startedAt = recorder.recordingStartedAt {
                Text(startedAt, style: .timer).monospacedDigit()
            }
            Button("Stop") { Task { await recorder.stop() } }.disabled(recorder.isStopping)
            Button("Cancel") { Task { await recorder.cancel() } }
        }
        .controlSize(.small)
        .font(.system(size: 12, weight: .medium))
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(.regularMaterial, in: Capsule())
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Recording annotation"))
    }
}
