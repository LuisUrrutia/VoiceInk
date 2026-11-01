import AppKit
import Foundation
import os

/// Turns a recorded annotation into its bundle: the narration transcribed with timing on a local model, then
/// `summary.md`, copied to the clipboard for an agent.
@MainActor
final class AnnotationProcessor: ObservableObject {
    static let shared = AnnotationProcessor()

    struct Environment {
        var chooseModel: @MainActor () -> (any TranscriptionModel)?
        var makeTranscriber: @MainActor (any TranscriptionModel) -> any TimedSpeechTranscribing
        var requestContext: @MainActor (any TranscriptionModel) -> TranscriptionRequestContext
        var copy: @MainActor (String) -> Void = { text in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
        var notify: @MainActor (String) -> Void = { NotificationManager.shared.showNotification(title: $0, type: .success) }
        var frameSource: (_ movie: URL, _ offset: TimeInterval) -> any AnnotationFrameSource = { MovieFrameSource(url: $0, offset: $1) }
        var agentCommand: () -> String? = { AnnotationSettings.agentCommand() }
        var agentTimeout: () -> TimeInterval = { AnnotationSettings.agentTimeout() }
        var agentRunner: any AnnotationAgentRunning = LoginShellAgentRunner()
        var notifyFailure: @MainActor (String) -> Void = { NotificationManager.shared.showNotification(title: $0, type: .error, duration: 7) }
    }

    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "AnnotationProcessor")
    private var environment: Environment?
    private weak var recorder: AnnotationRecorder?
    private var worker: Task<Void, Never>?
    @Published private(set) var processingID: UUID?
    /// Annotations whose agent command is running.
    @Published private(set) var agentIDs = Set<UUID>()
    private var agentTasks: [UUID: Task<Void, Never>] = [:]

    func configure(engine: VoiceInkEngine, recorder: AnnotationRecorder = .shared) {
        let models = engine.transcriptionModelManager
        let whisperModels = engine.whisperModelManager
        configure(
            environment: Environment(
                chooseModel: { MeetingTranscriptionModelChoice.choose(current: models.currentTranscriptionModel, usable: models.usableModels) },
                makeTranscriber: { model -> any TimedSpeechTranscribing in
                    if model.provider == .whisper {
                        return MeetingWhisperTranscriber(modelURL: { name in whisperModels.availableModels.first { $0.name == name }?.url })
                    }
                    return FluidAudioTranscriptionService()
                },
                requestContext: { [weak engine] model in
                    let context = TranscriptionRequestContext(languages: UserDefaults.standard.selectedTranscriptionLanguages, model: model)
                    guard let engine else { return context }
                    return context.withVocabulary(CustomVocabularyService.shared.loadSavedVocabulary(from: engine.modelContext))
                }
            ),
            recorder: recorder
        )
    }

    func configure(environment: Environment, recorder: AnnotationRecorder) {
        self.environment = environment
        self.recorder = recorder
        recorder.onRecorded = { [weak self] manifest in self?.process(manifest.id) }
        recorder.isProcessing = { [weak self] id in
            self?.processingID == id || self?.pendingIDs.contains(id) == true || self?.agentIDs.contains(id) == true
        }
    }

    private var pendingIDs = Set<UUID>()

    /// One annotation at a time; a newer one waits for the current one.
    func process(_ id: UUID) {
        pendingIDs.insert(id)
        let previous = worker
        worker = Task { [weak self] in
            await previous?.value
            await self?.run(id)
            self?.pendingIDs.remove(id)
        }
    }

    func waitUntilIdle() async {
        while let worker {
            await worker.value
            if self.worker == worker { self.worker = nil }
        }
    }

    /// Runs the configured command with the summary on standard input and the bundle's paths in its environment,
    /// saving its output in the bundle. The annotation stays undeletable until the command ends or is cancelled.
    private func runAgent(_ command: String, summary: String, manifest: AnnotationManifest, environment: Environment) {
        guard let recorder else { return }
        let id = manifest.id
        let store = recorder.store
        let variables = AnnotationAgentHandoff.environment(for: manifest, store: store)
        agentIDs.insert(id)
        agentTasks[id] = Task { [weak self] in
            var run = AnnotationAgentRun(command: command, exitStatus: nil, failure: nil, finishedAt: Date())
            do {
                let result = try await environment.agentRunner.run(
                    command: command, standardInput: Data(summary.utf8), timeout: environment.agentTimeout(), environment: variables
                )
                run.exitStatus = result.status
                let url = store.url(for: id, file: AnnotationAgentHandoff.outputFileName)
                if FileManager.default.fileExists(atPath: store.directory(for: id).path) {
                    try? result.output.write(to: url, options: [.atomic])
                    store.protect(url)
                }
                if result.status != 0 { run.failure = String(format: String(localized: "The agent command exited with status %d."), result.status) }
            } catch is CancellationError {
                run.failure = String(localized: "The agent command was cancelled.")
            } catch {
                run.failure = error.localizedDescription
            }
            run.finishedAt = Date()
            guard let self else { return }
            self.agentIDs.remove(id)
            self.agentTasks[id] = nil
            if var saved = try? store.load(id: id) {
                saved.agentRun = run
                self.recorder?.update(saved)
            }
            if let failure = run.failure {
                environment.notifyFailure(failure)
            } else {
                environment.notify(String(localized: "The agent command finished"))
            }
        }
    }

    func cancelAgent(_ id: UUID) {
        agentTasks[id]?.cancel()
    }

    /// Waits for every agent command started so far.
    func waitForAgents() async {
        while let task = agentTasks.values.first { await task.value }
    }

    enum RenderError: Error {
        /// The bundle was removed while frames were decoded.
        case bundleRemoved
    }

    /// Chooses keyframes and renders them with ink and clicks into `frames/` and the contact sheet. A movie that
    /// cannot be read leaves the bundle without images, and the summary lists the narration instead; a write that
    /// fails, or a bundle removed meanwhile, is an error.
    private func renderKeyframes(
        _ manifest: inout AnnotationManifest, store: AnnotationStore,
        frameSource: (URL, TimeInterval) -> any AnnotationFrameSource
    ) async throws {
        var keyframes = AnnotationKeyframes.keyframes(manifest, sceneChanges: manifest.sceneChanges)
        manifest.keyframes = []
        manifest.contactSheet = nil
        let source = frameSource(store.url(for: manifest.id, file: AnnotationManifest.videoFileName), manifest.videoOffset ?? 0)
        guard !keyframes.isEmpty, let images = try? await source.images(at: keyframes.map(\.t)) else { return }
        let bundle = store.directory(for: manifest.id)
        guard FileManager.default.fileExists(atPath: bundle.path) else { throw RenderError.bundleRemoved }
        let folder = bundle.appendingPathComponent(AnnotationManifest.framesDirectoryName, isDirectory: true)
        // Never recreates a removed bundle: only the frames folder inside an existing one.
        if !FileManager.default.fileExists(atPath: folder.path) {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        var rendered: [(image: CGImage, label: String)] = []
        for index in keyframes.indices {
            guard index < images.count, let image = images[index],
                let annotated = AnnotationRenderer.annotate(image, keyframe: keyframes[index], manifest: manifest),
                let file = keyframes[index].file
            else {
                keyframes[index].file = nil
                continue
            }
            let url = bundle.appendingPathComponent(file)
            try AnnotationRenderer.writePNG(annotated, to: url)
            store.protect(url)
            rendered.append((annotated, "#\(keyframes[index].index) \(MeetingMarkdown.timestamp(keyframes[index].t))"))
        }
        manifest.keyframes = keyframes.filter { $0.file != nil }
        if let sheet = AnnotationRenderer.contactSheet(rendered) {
            let url = store.url(for: manifest.id, file: AnnotationManifest.contactSheetFileName)
            try AnnotationRenderer.writePNG(sheet, to: url)
            store.protect(url)
            manifest.contactSheet = AnnotationManifest.contactSheetFileName
        }
    }

    private func run(_ id: UUID) async {
        guard let environment, let recorder, var manifest = try? recorder.store.load(id: id) else { return }
        processingID = id
        defer { processingID = nil }
        let store = recorder.store
        if let model = environment.chooseModel() {
            let transcriber = environment.makeTranscriber(model)
            let meetingTranscriber = MeetingTranscriber(transcriber: transcriber, model: model, context: environment.requestContext(model))
            do {
                let samples = try MeetingTranscriber.readSamples(from: store.url(for: id, file: AnnotationManifest.narrationFileName))
                manifest.transcript = try await meetingTranscriber.transcribeTrack(samples).map {
                    MeetingTranscriber.meetingTime($0, timeline: manifest.narrationTimeline)
                }
                manifest.transcriptModel = model.name
            } catch {
                logger.error("Annotation narration transcription failed: \(error, privacy: .public)")
                manifest.failure = error.localizedDescription
            }
            await transcriber.releaseResources()
        } else {
            manifest.failure = TimedTranscriptionError.unsupportedModel.localizedDescription
        }

        do {
            try await renderKeyframes(&manifest, store: store, frameSource: environment.frameSource)
        } catch RenderError.bundleRemoved {
            logger.notice("Annotation was removed while its frames were decoded")
            return
        } catch {
            logger.error("Could not write the annotation images: \(error, privacy: .public)")
            manifest.status = .failed
            manifest.failure = error.localizedDescription
            if FileManager.default.fileExists(atPath: store.directory(for: id).path) { recorder.update(manifest) }
            return
        }

        // The bundle can be trashed while its narration transcribes; then nothing is written or copied.
        guard FileManager.default.fileExists(atPath: store.directory(for: id).path) else {
            logger.notice("Annotation was removed during processing")
            return
        }
        let summary = AnnotationSummary.render(manifest, folder: store.directory(for: id))
        do {
            let url = store.url(for: id, file: AnnotationManifest.summaryFileName)
            try Data(summary.utf8).write(to: url, options: [.atomic])
            store.protect(url)
            manifest.status = .ready
            try store.save(manifest)
        } catch {
            logger.error("Could not write the annotation bundle: \(error, privacy: .public)")
            manifest.status = .failed
            manifest.failure = error.localizedDescription
            recorder.update(manifest)
            return
        }
        recorder.reload()
        environment.copy(summary)
        environment.notify(String(localized: "Annotation copied for your agent"))
        if let command = environment.agentCommand() { runAgent(command, summary: summary, manifest: manifest, environment: environment) }
    }
}

/// `summary.md`: what an agent reads first. It names the bundle's folder, so a local agent can open its files.
enum AnnotationSummary {
    static func render(_ manifest: AnnotationManifest, folder: URL, locale: Locale = .current) -> String {
        var lines = [
            "# \(String(localized: "Annotation")) · \(manifest.createdAt.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, locale: locale)))",
            "",
            String(format: String(localized: "A %@ screen recording with spoken narration, in %@."), MeetingMarkdown.timestamp(manifest.duration), folder.path),
            "",
            "- `\(AnnotationManifest.videoFileName)`: \(String(localized: "the screen recording"))",
            "- `\(AnnotationManifest.narrationFileName)`: \(String(localized: "the narration audio"))",
            "- `\(AnnotationManifest.fileName)`: \(String(localized: "timestamps and the transcript with word times"))",
        ]
        if !manifest.keyframes.isEmpty {
            if let sheet = manifest.contactSheet {
                lines.append("- `\(sheet)`: \(String(localized: "every keyframe in order, numbered"))")
            }
            lines.append("- `\(AnnotationManifest.framesDirectoryName)/`: \(String(localized: "each keyframe at full size, with the ink and clicks drawn"))")
            lines += [
                "",
                // As Hex's summary does: the marks and words only make sense on the images.
                "Open \([manifest.contactSheet, AnnotationManifest.framesDirectoryName + "/"].compactMap { $0 }.joined(separator: " and ")) in that folder before changing anything: the marks and words only make sense on the images, which can show more than the text does.",
                "",
                "## \(String(localized: "Keyframes"))",
                "",
            ]
            for keyframe in manifest.keyframes {
                var line = "- #\(keyframe.index) (\(MeetingMarkdown.timestamp(keyframe.t)))"
                if let said = keyframe.said { line += " “\(said)”" }
                if let event = keyframe.event { line += " [\(event)]" }
                lines.append(line)
            }
        }
        lines += ["", "## \(String(localized: "Narration"))", ""]
        if manifest.transcript.isEmpty {
            lines.append("_\(String(localized: "No narration was transcribed."))_")
        } else {
            for segment in manifest.transcript {
                lines.append("- \(MeetingMarkdown.timestamp(segment.start)) “\(segment.text)”")
            }
        }
        let moments = manifest.marks.map { (t: $0.start, text: $0.description) }
            + manifest.events.map { event in
                let verb = switch event.kind {
                case .click: "clicked"
                case .rightClick: "right-clicked"
                case .scroll: "scrolled"
                }
                return (t: event.t, text: String(format: "\(verb) at x %.2f, y %.2f", event.x, event.y))
            }
        if !moments.isEmpty {
            lines += ["", "## \(String(localized: "Marks and clicks"))", ""]
            lines.append(String(localized: "Positions are fractions of the display, from its top-left corner."))
            lines.append("")
            for moment in moments.sorted(by: { $0.t < $1.t }) {
                lines.append("- \(MeetingMarkdown.timestamp(moment.t)) \(moment.text)")
            }
        }
        if let failure = manifest.narrationFailure {
            lines += ["", "_\(String(format: String(localized: "The narration recording failed (%@), so it may be incomplete."), failure))_"]
        }
        if let failure = manifest.failure {
            lines += ["", "_\(failure)_"]
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
