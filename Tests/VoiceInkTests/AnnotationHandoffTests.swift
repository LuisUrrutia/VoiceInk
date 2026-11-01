import AppKit
import Combine
import XCTest

@testable import VoiceInk

@MainActor final class AnnotationHandoffTests: XCTestCase {
    private var root: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("AnnotationHandoffTests-\(UUID().uuidString)")
        suiteName = "AnnotationHandoffTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        Labs.setEnabled(true, for: .annotate, in: defaults)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
        defaults.removePersistentDomain(forName: suiteName)
    }

    // MARK: - Handoff

    func testTheAgentGetsAbsolutePathsWithTheContactSheetFirst() {
        let store = AnnotationStore(rootURL: root, movesToTrash: false)
        var manifest = AnnotationManifest()
        manifest.contactSheet = AnnotationManifest.contactSheetFileName
        manifest.keyframes = [
            AnnotationKeyframe(index: 1, t: 0.5, reason: .initial, file: "frames/frame-01.png"),
            AnnotationKeyframe(index: 2, t: 3, reason: .click, file: "frames/frame-02.png"),
        ]

        let environment = AnnotationAgentHandoff.environment(for: manifest, store: store)

        let folder = store.directory(for: manifest.id).path
        XCTAssertEqual(environment["VOICEINK_ANNOTATION_DIR"], folder)
        XCTAssertEqual(environment["VOICEINK_ANNOTATION_SUMMARY"], folder + "/summary.md")
        XCTAssertEqual(environment["VOICEINK_ANNOTATION_CONTACT_SHEET"], folder + "/contact-sheet.png")
        XCTAssertEqual(
            environment["VOICEINK_ANNOTATION_IMAGES"]?.components(separatedBy: "\n"),
            [folder + "/contact-sheet.png", folder + "/frames/frame-01.png", folder + "/frames/frame-02.png"]
        )
    }

    func testTheContactSheetCanBeCopiedAsAnImage() throws {
        let store = AnnotationStore(rootURL: root, movesToTrash: false)
        var manifest = AnnotationManifest()
        try store.createDirectory(for: manifest.id)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("AnnotationHandoffTests.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        XCTAssertFalse(AnnotationAgentHandoff.copyContactSheet(of: manifest, store: store, to: pasteboard))

        let image = NSImage(size: NSSize(width: 4, height: 4))
        image.lockFocus()
        NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: 4, height: 4).fill()
        image.unlockFocus()
        let png = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation))?.representation(using: .png, properties: [:]))
        try png.write(to: store.url(for: manifest.id, file: AnnotationManifest.contactSheetFileName))
        manifest.contactSheet = AnnotationManifest.contactSheetFileName

        XCTAssertTrue(AnnotationAgentHandoff.copyContactSheet(of: manifest, store: store, to: pasteboard))
        XCTAssertNotNil(NSImage(pasteboard: pasteboard))
    }

    func testAConfiguredCommandGetsTheSummaryAndItsOutputIsSaved() async throws {
        let runner = FakeAgentRunner(status: 0, output: "fixed the button")
        let fixture = try makeProcessing(command: "my-agent", runner: runner)

        fixture.processor.process(fixture.id)
        await fixture.processor.waitUntilIdle()
        await fixture.processor.waitForAgents()

        XCTAssertEqual(runner.commands, ["my-agent"])
        XCTAssertEqual(runner.inputs.first, fixture.copied.values.first)
        XCTAssertEqual(runner.environments.first?["VOICEINK_ANNOTATION_DIR"], fixture.store.directory(for: fixture.id).path)
        XCTAssertEqual(
            try String(contentsOf: fixture.store.url(for: fixture.id, file: "agent-output.txt"), encoding: .utf8), "fixed the button"
        )
        let run = try XCTUnwrap(try fixture.store.load(id: fixture.id).agentRun)
        XCTAssertEqual(run.exitStatus, 0)
        XCTAssertNil(run.failure)
        XCTAssertEqual(run.outputFile, "agent-output.txt")
        XCTAssertTrue(fixture.failures.values.isEmpty)
    }

    func testNoCommandStartsWhenAnnotateTurnsOffDuringProcessing() async throws {
        let runner = FakeAgentRunner(status: 0, output: "")
        let fixture = try makeProcessing(command: "my-agent", runner: runner)
        fixture.copied.onAppend = { fixture.enabled.isOn = false }

        fixture.processor.process(fixture.id)
        await fixture.processor.waitUntilIdle()
        await fixture.processor.waitForAgents()

        XCTAssertEqual(fixture.copied.values.count, 1)
        XCTAssertTrue(runner.commands.isEmpty)
        XCTAssertNil(try fixture.store.load(id: fixture.id).agentRun)
    }

    func testTurningAnnotateOffOrQuittingStopsARunningCommand() async throws {
        for quits in [false, true] {
            let held = FakeAgentRunner(status: 0, output: "", holds: true)
            let fixture = try makeProcessing(command: "my-agent", runner: held)
            fixture.processor.process(fixture.id)
            await fixture.processor.waitUntilIdle()
            try await waitUntil { held.isHolding }

            if quits {
                await fixture.processor.stopAllAgents()
            } else {
                fixture.enabled.changes.send(false)
                await fixture.processor.waitForAgents()
            }

            XCTAssertTrue(fixture.processor.agentIDs.isEmpty)
            XCTAssertEqual(
                try fixture.store.load(id: fixture.id).agentRun?.failure, String(localized: "The agent command was cancelled.")
            )
        }
    }

    func testQuittingStartsNoCommandForAnAnnotationStillProcessing() async throws {
        let held = FakeAgentRunner(status: 0, output: "", holds: true)
        let frames = GatedFrames()
        let fixture = try makeProcessing(command: "my-agent", runner: held, frames: frames)
        let later = try fixture.addAnnotation()
        fixture.processor.process(fixture.id)
        try await waitUntil { held.isHolding }
        fixture.processor.process(later)
        try await waitUntil { frames.isWaiting }

        // Runs once stopAllAgents suspends, after it has closed command admission.
        Task { @MainActor in frames.open() }
        await fixture.processor.stopAllAgents()
        await fixture.processor.waitUntilIdle()

        XCTAssertEqual(held.commands.count, 1)
        XCTAssertNil(try fixture.store.load(id: later).agentRun)
        XCTAssertEqual(try fixture.store.load(id: later).status, .ready)
        XCTAssertTrue(fixture.processor.agentIDs.isEmpty)
    }

    func testAnOutputThatCannotBeSavedIsReportedAsAFailure() async throws {
        let fixture = try makeProcessing(command: "my-agent", runner: FakeAgentRunner(status: 0, output: "answer"))
        try FileManager.default.createDirectory(
            at: fixture.store.url(for: fixture.id, file: "agent-output.txt"), withIntermediateDirectories: false
        )

        fixture.processor.process(fixture.id)
        await fixture.processor.waitUntilIdle()
        await fixture.processor.waitForAgents()

        let run = try XCTUnwrap(try fixture.store.load(id: fixture.id).agentRun)
        XCTAssertEqual(run.exitStatus, 0)
        XCTAssertNotNil(run.failure)
        XCTAssertNil(run.outputFile)
        XCTAssertEqual(fixture.failures.values.count, 1)
    }

    func testAFailingOrCancelledCommandIsReportedAndKeepsTheBundleSafeMeanwhile() async throws {
        let failing = try makeProcessing(command: "my-agent", runner: FakeAgentRunner(status: 2, output: "boom"))
        failing.processor.process(failing.id)
        await failing.processor.waitUntilIdle()
        await failing.processor.waitForAgents()
        XCTAssertEqual(try failing.store.load(id: failing.id).agentRun?.exitStatus, 2)
        XCTAssertEqual(failing.failures.values.count, 1)

        let held = FakeAgentRunner(status: 0, output: "", holds: true)
        let cancelled = try makeProcessing(command: "my-agent", runner: held)
        cancelled.processor.process(cancelled.id)
        await cancelled.processor.waitUntilIdle()
        try await waitUntil { held.isHolding }
        cancelled.recorder.delete(try cancelled.store.load(id: cancelled.id))
        XCTAssertNotNil(try? cancelled.store.load(id: cancelled.id), "deletion waits for the agent")

        cancelled.processor.cancelAgent(cancelled.id)
        await cancelled.processor.waitForAgents()

        XCTAssertEqual(try cancelled.store.load(id: cancelled.id).agentRun?.failure, String(localized: "The agent command was cancelled."))
        XCTAssertFalse(cancelled.processor.agentIDs.contains(cancelled.id))
    }

    func testTheLoginShellRunnerPassesStandardInputAndEnvironmentAndHonorsItsTimeout() async throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let runner = LoginShellAgentRunner()

        let result = try await runner.run(
            command: #"cat > "$VOICEINK_ANNOTATION_DIR/received.txt"; printf "done %s" "$VOICEINK_ANNOTATION_SUMMARY""#,
            standardInput: Data("the summary".utf8), timeout: 10,
            environment: ["VOICEINK_ANNOTATION_DIR": root.path, "VOICEINK_ANNOTATION_SUMMARY": "summary.md"]
        )

        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(String(data: result.output, encoding: .utf8), "done summary.md")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("received.txt"), encoding: .utf8), "the summary")
        let started = ContinuousClock.now
        do {
            _ = try await runner.run(command: "sleep 30", standardInput: Data(), timeout: 0.3, environment: [:])
            XCTFail("Expected a timeout")
        } catch {}
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(10))
    }

    // MARK: - Retention

    func testRetentionRemovesMediaThenBundlesAndSkipsBusyAnnotations() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func annotation(daysAgo: Double, status: AnnotationManifest.Status = .ready) -> AnnotationManifest {
            var manifest = AnnotationManifest(createdAt: now.addingTimeInterval(-daysAgo * 86_400))
            manifest.status = status
            return manifest
        }
        let fresh = annotation(daysAgo: 2), aged = annotation(daysAgo: 8), old = annotation(daysAgo: 31)
        let processing = annotation(daysAgo: 40, status: .processing), busy = annotation(daysAgo: 40)

        let actions = AnnotationRetention.week.actions(
            for: [fresh, aged, old, processing, busy], now: now, isBusy: { $0 == busy.id }
        )

        XCTAssertEqual(actions, [.removeMedia(aged.id), .removeBundle(old.id)])
        XCTAssertEqual(AnnotationRetention.month.actions(for: [aged, old], now: now, isBusy: { _ in false }), [.removeMedia(old.id)])
        XCTAssertTrue(AnnotationRetention.forever.actions(for: [old], now: now, isBusy: { _ in false }).isEmpty)
    }

    func testRetentionDeletesTheMovieAndNarrationButKeepsImagesAndText() throws {
        let store = AnnotationStore(rootURL: root, movesToTrash: false)
        var manifest = AnnotationManifest(createdAt: Date().addingTimeInterval(-10 * 86_400))
        manifest.status = .ready
        try store.createDirectory(for: manifest.id)
        try store.save(manifest)
        for file in ["recording.mp4", "narration.wav", "summary.md", "contact-sheet.png"] {
            FileManager.default.createFile(atPath: store.url(for: manifest.id, file: file).path, contents: Data("x".utf8))
        }
        var dependencies = AnnotationRecorder.Dependencies()
        dependencies.store = store
        dependencies.defaults = defaults
        let recorder = AnnotationRecorder(dependencies: dependencies)

        recorder.applyRetention()

        XCTAssertFalse(FileManager.default.fileExists(atPath: store.url(for: manifest.id, file: "recording.mp4").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.url(for: manifest.id, file: "narration.wav").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.url(for: manifest.id, file: "summary.md").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.url(for: manifest.id, file: "contact-sheet.png").path))
        XCTAssertTrue(try store.load(id: manifest.id).mediaRemoved)
    }

    func testAMovieThatCannotBeRemovedStaysUnmarkedAndIsRetried() throws {
        let store = AnnotationStore(rootURL: root, movesToTrash: false)
        var manifest = AnnotationManifest(createdAt: Date().addingTimeInterval(-10 * 86_400))
        manifest.status = .ready
        try store.createDirectory(for: manifest.id)
        try store.save(manifest)
        let movie = store.url(for: manifest.id, file: "recording.mp4")
        FileManager.default.createFile(atPath: movie.path, contents: Data("x".utf8))
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: movie.path)
        defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: movie.path) }
        var dependencies = AnnotationRecorder.Dependencies()
        dependencies.store = store
        dependencies.defaults = defaults
        let recorder = AnnotationRecorder(dependencies: dependencies)

        recorder.applyRetention()

        XCTAssertTrue(FileManager.default.fileExists(atPath: movie.path))
        XCTAssertFalse(try store.load(id: manifest.id).mediaRemoved)

        try FileManager.default.setAttributes([.immutable: false], ofItemAtPath: movie.path)
        recorder.applyRetention()

        XCTAssertFalse(FileManager.default.fileExists(atPath: movie.path))
        XCTAssertTrue(try store.load(id: manifest.id).mediaRemoved)
    }

    func testAnUnsupportedConfigurationRetentionKeepsTheCurrentPolicy() throws {
        defaults.set(AnnotationRetention.forever.rawValue, forKey: AnnotationSettings.retentionKey)
        let bogus: [String: ConfigurationValue] = [AnnotationSettings.retentionKey: .string("bogus")]

        try ConfigurationPreferences.validate(bogus)
        try ConfigurationPreferences.apply(bogus, to: defaults)

        XCTAssertEqual(AnnotationRetention.current(in: defaults), .forever)
        try ConfigurationPreferences.apply([AnnotationSettings.retentionKey: .string("month")], to: defaults)
        XCTAssertEqual(AnnotationRetention.current(in: defaults), .month)
    }

    func testAgentAndRetentionSettingsRoundTripThroughBackupsAndTheConfigurationFile() throws {
        defaults.set("claude -p", forKey: AnnotationSettings.agentCommandKey)
        defaults.set(600.0, forKey: AnnotationSettings.agentTimeoutKey)
        defaults.set(AnnotationRetention.forever.rawValue, forKey: AnnotationSettings.retentionKey)
        let restoredName = "\(suiteName!).restored"
        let restored = UserDefaults(suiteName: restoredName)!
        defer { restored.removePersistentDomain(forName: restoredName) }

        AnnotationSettings.Backup.capture(from: defaults).restore(in: restored)
        AnnotationSettings.Backup(retention: "bogus").restore(in: restored)

        XCTAssertEqual(AnnotationSettings.agentCommand(in: restored), "claude -p")
        XCTAssertEqual(AnnotationSettings.agentTimeout(in: restored), 600)
        XCTAssertEqual(AnnotationRetention.current(in: restored), .forever)
        let captured = try ConfigurationPreferences.capture(from: defaults)
        XCTAssertEqual(captured[AnnotationSettings.agentCommandKey], .string("claude -p"))
        XCTAssertEqual(captured[AnnotationSettings.retentionKey], .string("forever"))
        defaults.set("   ", forKey: AnnotationSettings.agentCommandKey)
        XCTAssertNil(AnnotationSettings.agentCommand(in: defaults))
    }

    // MARK: - Fixtures

    private final class Values {
        var values: [String] = [] { didSet { onAppend() } }
        var onAppend: () -> Void = {}
    }

    private final class EnabledSwitch {
        var isOn = true
        let changes = PassthroughSubject<Bool, Never>()
    }

    private struct ProcessingFixture {
        let processor: AnnotationProcessor
        let recorder: AnnotationRecorder
        let store: AnnotationStore
        let id: UUID
        let copied: Values
        let failures: Values
        let enabled: EnabledSwitch

        func addAnnotation() throws -> UUID {
            var manifest = AnnotationManifest()
            manifest.status = .processing
            manifest.duration = 3
            try store.createDirectory(for: manifest.id)
            try store.save(manifest)
            return manifest.id
        }
    }

    private func makeProcessing(
        command: String?, runner: any AnnotationAgentRunning, frames: (any AnnotationFrameSource)? = nil
    ) throws -> ProcessingFixture {
        let store = AnnotationStore(rootURL: root, movesToTrash: false)
        var manifest = AnnotationManifest()
        manifest.status = .processing
        manifest.duration = 3
        try store.createDirectory(for: manifest.id)
        try store.save(manifest)
        var dependencies = AnnotationRecorder.Dependencies()
        dependencies.store = store
        dependencies.defaults = defaults
        let recorder = AnnotationRecorder(dependencies: dependencies)
        let processor = AnnotationProcessor()
        let copied = Values(), failures = Values(), enabled = EnabledSwitch()
        processor.configure(
            environment: .init(
                chooseModel: { nil }, makeTranscriber: { _ in fatalError("no model") },
                requestContext: { _ in TranscriptionRequestContext(languages: ["en"]) }, copy: { copied.values.append($0) },
                notify: { _ in }, frameSource: { _, _ in frames ?? NoFrames() }, agentCommand: { command }, agentTimeout: { 5 },
                agentRunner: runner, notifyFailure: { failures.values.append($0) },
                isEnabled: { enabled.isOn }, enabledChanges: enabled.changes.eraseToAnyPublisher()
            ),
            recorder: recorder
        )
        return ProcessingFixture(
            processor: processor, recorder: recorder, store: store, id: manifest.id, copied: copied, failures: failures,
            enabled: enabled
        )
    }

    private func waitUntil(timeout: Duration = .seconds(2), _ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else { return XCTFail("Condition not met in time") }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

private struct NoFrames: AnnotationFrameSource {
    func images(at times: [TimeInterval]) async throws -> [CGImage?] { throw CocoaError(.fileReadNoSuchFile) }
}

/// Lets the first annotation through, then holds the next one's decoding until opened.
private final class GatedFrames: AnnotationFrameSource, @unchecked Sendable {
    private var calls = 0
    private var waiter: CheckedContinuation<Void, Never>?
    var isWaiting: Bool { waiter != nil }

    func images(at times: [TimeInterval]) async throws -> [CGImage?] {
        calls += 1
        if calls > 1 { await withCheckedContinuation { waiter = $0 } }
        throw CocoaError(.fileReadNoSuchFile)
    }

    func open() {
        waiter?.resume()
        waiter = nil
    }
}

@MainActor
private final class FakeAgentRunner: AnnotationAgentRunning {
    let status: Int32
    let output: String
    let holds: Bool
    var commands: [String] = []
    var inputs: [String] = []
    var environments: [[String: String]] = []
    private(set) var isHolding = false

    init(status: Int32, output: String, holds: Bool = false) {
        self.status = status
        self.output = output
        self.holds = holds
    }

    func run(
        command: String, standardInput: Data, timeout: TimeInterval, environment: [String: String]
    ) async throws -> (status: Int32, output: Data) {
        commands.append(command)
        inputs.append(String(decoding: standardInput, as: UTF8.self))
        environments.append(environment)
        if holds {
            isHolding = true
            try await Task.sleep(for: .seconds(30))
        }
        return (status, Data(output.utf8))
    }
}
