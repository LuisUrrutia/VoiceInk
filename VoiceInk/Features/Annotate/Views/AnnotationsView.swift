import AppKit
import Combine
import SwiftUI

struct AnnotationsView: View {
    @ObservedObject private var recorder = AnnotationRecorder.shared
    @ObservedObject private var processor = AnnotationProcessor.shared
    @AppStorage(AnnotationSettings.agentCommandKey) private var agentCommand = ""
    @AppStorage(AnnotationSettings.agentTimeoutKey) private var agentTimeout = AnnotationSettings.defaultAgentTimeout
    @AppStorage(AnnotationSettings.retentionKey) private var retention = AnnotationRetention.default.rawValue

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
                        Button("Annotate") { Task { await recorder.toggle() } }.disabled(recorder.isBusy)
                    }
                }
                LabeledContent("Shortcut") { ShortcutRecorder(action: .toggleAnnotate) }
            } header: {
                Text("Annotate")
            } footer: {
                Text("Show and tell: VoiceInk records the display under the pointer while you narrate, for up to 20 minutes. Hold Shift alone, or turn on the pen in the capsule, to draw; ink fades after a moment and is kept with its time. Clicks are noted with their positions; keystrokes are not. When you stop, it transcribes the narration on this Mac and copies a summary that names the bundle's folder, for a local AI agent. VoiceInk's own windows are not recorded, and dictation waits until you stop.")
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                TextField("Agent command", text: $agentCommand, prompt: Text("Optional"), axis: .vertical)
                    .lineLimit(2...5)
                    .font(.system(.body, design: .monospaced))
                Stepper(value: $agentTimeout, in: 30...3_600, step: 30) {
                    LabeledContent("Time limit", value: Duration.seconds(agentTimeout).formatted(.units(allowed: [.minutes, .seconds])))
                }
                .disabled(agentCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Picker("Keep annotations", selection: $retention) {
                    ForEach(AnnotationRetention.allCases, id: \.rawValue) { Text($0.displayName).tag($0.rawValue) }
                }
                .onChange(of: retention) { recorder.applyRetention() }
            } header: {
                Text("After an annotation")
            } footer: {
                Text("The summary is always copied, for pasting into an agent that runs in a terminal. A command runs in your login shell with the summary on standard input and VOICEINK_ANNOTATION_DIR, VOICEINK_ANNOTATION_SUMMARY, VOICEINK_ANNOTATION_CONTACT_SHEET and VOICEINK_ANNOTATION_IMAGES set; it starts a new agent session, and its output is saved as agent-output.txt in the bundle. Examples are in docs/annotate.md.")
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
    @ObservedObject private var processor = AnnotationProcessor.shared

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
                    if annotation.contactSheet != nil {
                        Button {
                            AnnotationAgentHandoff.copyContactSheet(of: annotation, store: recorder.store)
                        } label: {
                            Image(appSymbol: "camera.fill")
                        }
                        .help("Copy the contact sheet image, for chat apps")
                        .accessibilityLabel("Copy contact sheet image")
                    }
                }
                if processor.agentIDs.contains(annotation.id) {
                    Button("Stop Agent") { processor.cancelAgent(annotation.id) }
                } else if let output = annotation.agentRun?.outputFile {
                    Button("Agent Output") {
                        NSWorkspace.shared.open(recorder.store.url(for: annotation.id, file: output))
                    }
                }
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([recorder.store.directory(for: annotation.id)])
                } label: {
                    Image(appSymbol: "folder")
                }
                .help("Show in Finder")
                .accessibilityLabel("Show in Finder")
                Button(role: .destructive) { recorder.delete(annotation) } label: { Image(appSymbol: "trash") }
                    .disabled(annotation.id == recorder.ownedAnnotationID || recorder.isProcessing(annotation.id))
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
        let agent: String? = processor.agentIDs.contains(annotation.id)
            ? String(localized: "Agent running") : annotation.agentRun?.failure
        let media = annotation.mediaRemoved ? String(localized: "Movie removed") : nil
        let status: String = switch annotation.status {
        case .recording: String(localized: "Recording")
        case .processing: isProcessing ? String(localized: "Transcribing") : String(localized: "Waiting")
        case .ready: String(localized: "Ready")
        case .failed: String(localized: "Failed")
        }
        let narration = annotation.narrationFailure.map { _ in String(localized: "Narration incomplete") }
        return [MeetingMarkdown.timestamp(annotation.duration), status, narration, media, agent, annotation.failure].compactMap { $0 }
            .joined(separator: " · ")
    }
}

/// A capsule with the elapsed time, Stop and Cancel while an annotation records; it is not in the recording.
@MainActor
final class AnnotationCapsuleController {
    static let shared = AnnotationCapsuleController()
    /// Above the ink overlay, so Stop, Cancel and the pen stay clickable while drawing.
    static let capsuleLevel = NSWindow.Level(rawValue: AnnotationInputCapture.overlayLevel.rawValue + 1)

    private var panel: NSPanel?
    private var cancellable: AnyCancellable?

    func start(recorder: AnnotationRecorder = .shared) {
        guard cancellable == nil else { return }
        cancellable = recorder.$activeAnnotation.map { $0 != nil }.combineLatest(recorder.$isStopping).map { $0 || $1 }
            .removeDuplicates().sink { [weak self] isRecording in
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
        panel.level = Self.capsuleLevel
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
            Toggle(isOn: Binding(get: { recorder.isPenEnabled }, set: { recorder.setPenEnabled($0) })) {
                Image(appSymbol: "pencil")
            }
            .toggleStyle(.button)
            .help("Draw on the screen (or hold Shift)")
            .accessibilityLabel("Draw")
            .disabled(recorder.isStopping)
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
