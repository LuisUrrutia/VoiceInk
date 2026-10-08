import SwiftUI

struct CaptureReadinessView: View {
    @ObservedObject var engine: VoiceInkEngine
    @ObservedObject var shortcuts: RecordingShortcutManager
    @ObservedObject private var readiness: CaptureReadinessController
    @ObservedObject private var diagnostic: MicrophoneDiagnostic
    let onRecord: () -> Void

    init(engine: VoiceInkEngine, shortcuts: RecordingShortcutManager, onRecord: @escaping () -> Void) {
        self.engine = engine
        self.shortcuts = shortcuts
        self.readiness = engine.captureReadiness
        self.diagnostic = engine.microphoneDiagnostic
        self.onRecord = onRecord
    }

    private var issues: [CaptureReadiness.Issue] { readiness.snapshot.issues(for: .onScreenDictation) }
    private var feedback: CaptureFeedback {
        CaptureFeedback.resolve(
            state: engine.recordingState, hasSetupIssues: !issues.isEmpty, hasError: engine.recordingError != nil
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack {
                    status
                    Spacer()
                    recordingActions
                }
                VStack(alignment: .leading, spacing: 10) {
                    status
                    recordingActions
                }
            }
            if let error = engine.recordingError {
                Text(error).font(.callout).foregroundStyle(.secondary)
            }
            ForEach(Array(issues.enumerated()), id: \.offset) { _, issue in
                setupRow(issue)
            }
            if let pasteIssue = readiness.snapshot.issues(for: .paste).first {
                setupRow(pasteIssue)
            }
            HStack {
                Text(shortcuts.hotkeyAvailability.message).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Shortcuts") { MainWindowNavigation.shared.navigate(to: .settings) }
                    .buttonStyle(.borderless)
            }
        }
    }

    private var status: some View {
        HStack(spacing: 8) {
            if feedback == .recording { ActiveCaptureIndicator() }
            Text(feedback.title).font(.headline).accessibilityAddTraits(.isHeader)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var recordingActions: some View {
        if engine.recordingState == .recording {
            Button("Stop recording", action: onRecord)
            Button("Cancel", action: cancelRecording)
        } else if engine.recordingState == .starting {
            Button("Cancel", action: cancelRecording)
        } else {
            Button("Start recording", action: onRecord)
                .disabled(!issues.isEmpty || engine.recordingState != .idle || diagnostic.isBusy)
        }
    }

    private func cancelRecording() {
        Task {
            await engine.cancelRecording()
            await engine.recorderUIManager?.dismissRecorderPanel()
        }
    }

    private func setupRow(_ issue: CaptureReadiness.Issue) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(issue.message).font(.callout).frame(maxWidth: .infinity, alignment: .leading)
            if issue != .model(.checking) {
                Button("Set up") { performSetup(issue) }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Set up: \(issue.message)")
            }
        }
    }

    private func performSetup(_ issue: CaptureReadiness.Issue) {
        switch issue {
        case .microphonePermission: Task { await readiness.requestMicrophoneAccess() }
        case .microphoneUnavailable: MainWindowNavigation.shared.navigate(to: .audio)
        case .model(.noMode), .model(.noSelection): MainWindowNavigation.shared.navigate(to: .modes)
        case .model: MainWindowNavigation.shared.navigate(to: .models)
        case .accessibility: readiness.openPrivacySettings(.accessibility)
        case .hotkey: MainWindowNavigation.shared.navigate(to: .settings)
        }
    }
}

struct MicrophoneDiagnosticView: View {
    @ObservedObject private var engine: VoiceInkEngine
    @ObservedObject private var diagnostic: MicrophoneDiagnostic
    @ObservedObject private var readiness: CaptureReadinessController

    init(engine: VoiceInkEngine) {
        self.engine = engine
        self.diagnostic = engine.microphoneDiagnostic
        self.readiness = engine.captureReadiness
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Record for five seconds on this Mac. No transcription, upload, or paste.")
                .font(.callout).foregroundStyle(.secondary)
            if let issue = readiness.snapshot.issues(for: .microphoneTest).first {
                HStack {
                    Text(issue.message).font(.callout)
                    Spacer()
                    Button("Set up microphone") {
                        if case .microphonePermission = issue {
                            Task { await readiness.requestMicrophoneAccess() }
                        } else {
                            MainWindowNavigation.shared.navigate(to: .audio)
                        }
                    }
                }
            }
            HStack {
                if diagnostic.phase == .recording {
                    ActiveCaptureIndicator()
                    Text("Microphone active · \(diagnostic.elapsedSeconds) / 5 s")
                    Spacer()
                    Button("Stop test") { Task { await diagnostic.stop() } }
                } else {
                    Text(statusText).font(.callout)
                    Spacer()
                }
                if diagnostic.isBusy {
                    Button("Cancel test") { Task { await diagnostic.cancel() } }
                        .disabled(diagnostic.phase == .closing)
                } else {
                    Button("Test microphone") { diagnostic.start() }
                        .disabled(
                            engine.recordingState != .idle
                                || !readiness.snapshot.issues(for: .microphoneTest).isEmpty
                        )
                }
            }
            if let url = diagnostic.resultURL {
                Button("Show test audio in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    .buttonStyle(.borderless)
            }
        }
    }

    private var statusText: String {
        switch diagnostic.phase {
        case .idle: String(localized: "Uses your configured microphone.")
        case .starting: String(localized: "Starting microphone…")
        case .recording: String(localized: "Microphone active")
        case .closing: String(localized: "Closing and checking local audio…")
        case .failed(let message): message
        case .finished(let report):
            report.peakInputLevel > 0
                ? String(localized: "Captured a valid 16 kHz WAV locally. Nothing uploaded.")
                : String(localized: "Captured a valid 16 kHz WAV. Input was quiet; check the microphone and try again.")
        }
    }
}

struct ActiveCaptureIndicator: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.1, paused: reduceMotion)) { context in
            Circle()
                .fill(AppTheme.Status.error)
                .frame(width: 7, height: 7)
                .opacity(reduceMotion ? 1 : 0.7 + 0.3 * sin(context.date.timeIntervalSince1970 * 3))
        }
        .accessibilityHidden(true)
    }
}
