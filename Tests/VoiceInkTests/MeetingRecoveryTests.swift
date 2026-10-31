import AVFoundation
import XCTest

@testable import VoiceInk

@MainActor final class MeetingRecoveryTests: XCTestCase {
    private var root: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("MeetingRecoveryTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        suiteName = "MeetingRecoveryTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        Labs.setEnabled(true, for: .meetings, in: defaults)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
        defaults.removePersistentDomain(forName: suiteName)
    }

    // MARK: - WAV repair

    func testAWAVLeftOpenByACrashIsReadableAfterRepair() throws {
        let url = root.appendingPathComponent("track.wav")
        try writeRecordingWAV(frames: 16_000, to: url)
        try zeroSizeFields(of: url)
        XCTAssertNotEqual(try? AVAudioFile(forReading: url).length, 16_000)

        XCTAssertTrue(try MeetingWAVRepair.repair(url))

        XCTAssertEqual(try AVAudioFile(forReading: url).length, 16_000)
        XCTAssertFalse(try MeetingWAVRepair.repair(url), "a closed file is left unchanged")
    }

    func testAnOddTrailingByteIsLeftOutOfTheAudio() throws {
        let url = root.appendingPathComponent("odd.wav")
        try writeRecordingWAV(frames: 800, to: url)
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data([0x7F]))
        try handle.close()

        try MeetingWAVRepair.repair(url)

        XCTAssertEqual(try AVAudioFile(forReading: url).length, 800)
    }

    func testRepairAtThe32BitLimitKeepsWholeFramesInsideRIFF() throws {
        let url = root.appendingPathComponent("huge.wav")
        try writeRecordingWAV(frames: 16, to: url)
        let handle = try FileHandle(forWritingTo: url)
        // A sparse file just past what a 32-bit RIFF size can describe.
        try handle.truncate(atOffset: UInt64(UInt32.max) + 1_001)
        try handle.close()
        defer { try? FileManager.default.removeItem(at: url) }

        try MeetingWAVRepair.repair(url)

        let header = try XCTUnwrap(FileHandle(forReadingFrom: url).read(upToCount: 4_200))
        let dataOffset = try XCTUnwrap(header.range(of: Data("data".utf8))).lowerBound
        func field(_ offset: Int) -> UInt64 {
            UInt64(header.subdata(in: offset..<(offset + 4)).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).littleEndian })
        }
        let dataSize = field(dataOffset + 4)
        XCTAssertEqual(dataSize % 2, 0)
        XCTAssertEqual(field(4), UInt64(dataOffset) + dataSize)
        XCTAssertLessThanOrEqual(UInt64(dataOffset) + 8 + dataSize, UInt64(UInt32.max) + 8)
    }

    func testFilesThatAreNotWAVAreRejected() throws {
        let url = root.appendingPathComponent("text.wav")
        try Data("not audio at all".utf8).write(to: url)

        XCTAssertThrowsError(try MeetingWAVRepair.repair(url))
    }

    // MARK: - Recovery

    func testAMeetingLeftRecordingByACrashIsRepairedInterruptedAndTranscribed() async throws {
        let store = MeetingStore(rootURL: root.appendingPathComponent("store"), movesToTrash: false)
        let crashed = MeetingManifest(title: "Crashed")
        _ = try store.createDirectory(for: crashed.id)
        try store.save(crashed)
        for kind in MeetingManifest.TrackKind.allCases {
            let url = store.audioURL(for: crashed.id, track: kind)
            try writeRecordingWAV(frames: 48_000, to: url)
            try zeroSizeFields(of: url)
        }
        let recorder = makeRecorder(store: store)
        var interrupted: [UUID] = []
        recorder.onInterrupted = { interrupted += $0.map(\.id) }

        recorder.startMaintenance()

        XCTAssertEqual(interrupted, [crashed.id])
        let manifest = try store.load(id: crashed.id)
        XCTAssertEqual(manifest.status, .interrupted)
        XCTAssertEqual(manifest.duration, 3, accuracy: 0.05)
        XCTAssertEqual(try AVAudioFile(forReading: store.audioURL(for: crashed.id, track: .microphone)).length, 48_000)
    }

    func testRecoveredMeetingsAreTranscribedThroughTheCoordinator() async throws {
        let store = MeetingStore(rootURL: root.appendingPathComponent("store"), movesToTrash: false)
        let crashed = MeetingManifest(title: "Crashed")
        _ = try store.createDirectory(for: crashed.id)
        try store.save(crashed)
        let url = store.audioURL(for: crashed.id, track: .microphone)
        try writeRecordingWAV(frames: 32_000, to: url)
        try zeroSizeFields(of: url)
        let recorder = makeRecorder(store: store)
        let transcriber = RecoveryTranscriber()
        let coordinator = makeCoordinator(recorder: recorder, transcriber: transcriber)

        recorder.startMaintenance()
        await coordinator.waitUntilIdle()

        let manifest = try store.load(id: crashed.id)
        XCTAssertEqual(manifest.status, .transcribed)
        let transcript = try String(contentsOfFile: try XCTUnwrap(manifest.transcriptPath), encoding: .utf8)
        XCTAssertTrue(transcript.contains("recovered"))
    }

    func testTurningMeetingsOffAndOnWhileAStartIsPendingLeavesItsFilesAlone() async throws {
        let store = MeetingStore(rootURL: root.appendingPathComponent("store"), movesToTrash: false)
        let hardware = FakeMeetingMicrophoneHardware()
        hardware.holdStart = true
        let recorder = makeRecorder(store: store, microphone: hardware)
        let transcriber = RecoveryTranscriber()
        let coordinator = makeCoordinator(recorder: recorder, transcriber: transcriber)
        recorder.startMaintenance()
        let start = Task { try await recorder.start(title: "Pending") }
        try await waitUntil { !store.loadAll().isEmpty }

        Labs.setEnabled(false, for: .meetings, in: defaults)
        Labs.setEnabled(true, for: .meetings, in: defaults)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(store.loadAll().map(\.status), [.recording])
        hardware.releaseStart()

        await XCTAssertThrowsErrorAsync(try await start.value, MeetingRecorderError.featureDisabled)
        await coordinator.waitUntilIdle()
        XCTAssertEqual(transcriber.calls, 0)
        XCTAssertTrue(store.loadAll().isEmpty)
    }

    func testRetentionRunsPeriodicallyOnlyWhileMeetingsIsOn() async throws {
        let store = MeetingStore(rootURL: root.appendingPathComponent("store"), movesToTrash: false)
        let recorder = makeRecorder(store: store, maintenance: .milliseconds(10))
        recorder.startMaintenance()
        func addExpired() throws -> UUID {
            var manifest = MeetingManifest(createdAt: Date().addingTimeInterval(-40 * 86_400), title: "Old")
            manifest.status = .transcribed
            _ = try store.createDirectory(for: manifest.id)
            try store.save(manifest)
            return manifest.id
        }

        let first = try addExpired()
        try await waitUntil { !FileManager.default.fileExists(atPath: store.directory(for: first).path) }
        Labs.setEnabled(false, for: .meetings, in: defaults)
        let second = try addExpired()
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.directory(for: second).path))

        Labs.setEnabled(true, for: .meetings, in: defaults)
        try await waitUntil { !FileManager.default.fileExists(atPath: store.directory(for: second).path) }
    }

    func testCheckpointsExcludeADictationStillInProgress() async throws {
        let store = MeetingStore(rootURL: root.appendingPathComponent("store"), movesToTrash: false)
        let recorder = makeRecorder(store: store, checkpoint: .milliseconds(10))
        try await recorder.start(title: "Dictating")
        let id = try XCTUnwrap(recorder.activeMeeting?.id)
        recorder.dictationCaptureBegan()
        try await Task.sleep(for: .milliseconds(30))

        try await waitUntil { (try? store.load(id: id).dictationIntervals.isEmpty) == false }
        let saved = try store.load(id: id)
        XCTAssertEqual(saved.dictationIntervals.count, 1)
        XCTAssertTrue(recorder.activeMeeting?.dictationIntervals.isEmpty ?? true, "in-memory intervals close only at the end")
        recorder.dictationCaptureEnded()
        let stopped = await recorder.stop()
        XCTAssertEqual(stopped?.dictationIntervals.count, 1)
    }

    func testNothingIsRecoveredWhileMeetingsIsOff() throws {
        Labs.setEnabled(false, for: .meetings, in: defaults)
        let store = MeetingStore(rootURL: root.appendingPathComponent("store"), movesToTrash: false)
        let crashed = MeetingManifest(title: "Crashed")
        _ = try store.createDirectory(for: crashed.id)
        try store.save(crashed)
        let recorder = makeRecorder(store: store)

        recorder.startMaintenance()

        XCTAssertEqual(try store.load(id: crashed.id).status, .recording)
    }

    func testARecordingMeetingCheckpointsItsTimelines() async throws {
        let store = MeetingStore(rootURL: root.appendingPathComponent("store"), movesToTrash: false)
        let hardware = FakeMeetingMicrophoneHardware()
        let recorder = makeRecorder(store: store, microphone: hardware, checkpoint: .milliseconds(10))
        try await recorder.start(title: "Long")
        let id = try XCTUnwrap(recorder.activeMeeting?.id)

        hardware.emit(frames: 16_000, capturedThrough: DispatchTime.now().uptimeNanoseconds)
        try await waitUntil { (try? store.load(id: id).track(.microphone)?.timeline.anchors.isEmpty) == false }

        let checkpointed = try store.load(id: id)
        XCTAssertEqual(checkpointed.status, .recording)
        XCTAssertGreaterThan(checkpointed.duration, 0)
        _ = await recorder.stop()
    }

    // MARK: - Retention

    func testOnlyTranscribedMeetingsPastThePeriodExpire() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func meeting(_ status: MeetingManifest.Status, daysAgo: Double) -> MeetingManifest {
            var manifest = MeetingManifest(createdAt: now.addingTimeInterval(-daysAgo * 86_400), title: "\(status)")
            manifest.status = status
            return manifest
        }
        let meetings = [
            meeting(.transcribed, daysAgo: 31), meeting(.transcribed, daysAgo: 29), meeting(.failed, daysAgo: 90),
            meeting(.interrupted, daysAgo: 90), meeting(.recorded, daysAgo: 90), meeting(.transcribed, daysAgo: 8),
        ]

        XCTAssertEqual(MeetingAudioRetention.month.expired(meetings, now: now).map(\.createdAt), [meetings[0].createdAt])
        XCTAssertEqual(MeetingAudioRetention.week.expired(meetings, now: now).count, 3)
        XCTAssertTrue(MeetingAudioRetention.forever.expired(meetings, now: now).isEmpty)
    }

    func testRetentionRemovesExpiredMeetingAudioButNotTranscripts() throws {
        let store = MeetingStore(rootURL: root.appendingPathComponent("store"), movesToTrash: false)
        let transcript = root.appendingPathComponent("Old.md")
        try Data("# Old\n".utf8).write(to: transcript)
        var old = MeetingManifest(createdAt: Date().addingTimeInterval(-40 * 86_400), title: "Old")
        old.status = .transcribed
        old.transcriptPath = transcript.path
        var recent = MeetingManifest(title: "Recent")
        recent.status = .transcribed
        for manifest in [old, recent] {
            _ = try store.createDirectory(for: manifest.id)
            try store.save(manifest)
        }
        let recorder = makeRecorder(store: store)

        recorder.applyRetention()

        XCTAssertEqual(recorder.meetings.map(\.id), [recent.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.directory(for: old.id).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: transcript.path))
    }

    func testRetentionRoundTripsThroughBackupsAndTheConfigurationFile() throws {
        defaults.set(MeetingAudioRetention.week.rawValue, forKey: MeetingAudioRetention.key)
        let restoredName = "\(suiteName!).restored"
        let restored = UserDefaults(suiteName: restoredName)!
        defer { restored.removePersistentDomain(forName: restoredName) }

        MeetingSettings.Backup.capture(from: defaults).restore(in: restored)
        XCTAssertEqual(MeetingAudioRetention.current(in: restored), .week)
        MeetingSettings.Backup(audioRetentionDays: 12).restore(in: restored)
        XCTAssertEqual(MeetingAudioRetention.current(in: restored), .week)

        let captured = try ConfigurationPreferences.capture(from: defaults)
        XCTAssertEqual(captured[MeetingAudioRetention.key], .number(7))

        defaults.set(MeetingAudioRetention.forever.rawValue, forKey: MeetingAudioRetention.key)
        try ConfigurationPreferences.apply([MeetingAudioRetention.key: .number(12)], to: defaults)
        XCTAssertEqual(MeetingAudioRetention.current(in: defaults), .forever)
        try ConfigurationPreferences.apply([MeetingAudioRetention.key: .number(7)], to: defaults)
        XCTAssertEqual(MeetingAudioRetention.current(in: defaults), .week)
        try ConfigurationPreferences.apply([MeetingAudioRetention.key: .null], to: defaults)
        XCTAssertNil(defaults.persistentDomain(forName: suiteName)?[MeetingAudioRetention.key])
        XCTAssertEqual(MeetingAudioRetention.current(in: defaults), .month)
    }

    // MARK: - Fixtures

    private func makeCoordinator(recorder: MeetingRecorder, transcriber: RecoveryTranscriber) -> MeetingTranscriptionCoordinator {
        let model = TranscriptionModelRegistry.models.first { $0.name == "parakeet-tdt-0.6b-v3" }!
        let folder = root.appendingPathComponent("Transcripts", isDirectory: true)
        let coordinator = MeetingTranscriptionCoordinator()
        coordinator.configure(
            environment: .init(
                chooseModel: { model }, makeTranscriber: { _ in transcriber },
                requestContext: { _ in TranscriptionRequestContext(languages: ["en"]) }, isDictating: { false },
                outputFolder: { folder }
            ),
            recorder: recorder
        )
        return coordinator
    }

    private func makeRecorder(
        store: MeetingStore, microphone: FakeMeetingMicrophoneHardware = FakeMeetingMicrophoneHardware(),
        checkpoint: Duration = .seconds(30), maintenance: Duration = .seconds(3_600)
    ) -> MeetingRecorder {
        let devices = MeetingAudioDevices(userDefaults: defaults)
        var dependencies = MeetingRecorder.Dependencies()
        dependencies.store = store
        dependencies.permission = RecoveryGrantedSystemAudio()
        dependencies.makeSystemAudio = { RecoveryQuietSystemAudio() }
        dependencies.makeMicrophone = { MeetingMicrophoneCapture(deviceManager: devices, makeHardware: { microphone }) }
        dependencies.isMicrophoneAuthorized = { true }
        dependencies.defaults = defaults
        dependencies.checkpointInterval = checkpoint
        dependencies.maintenanceInterval = maintenance
        return MeetingRecorder(dependencies: dependencies)
    }

    /// A PCM16 WAV with the same writer the recorder uses.
    private func writeRecordingWAV(frames: Int, to url: URL) throws {
        let writer = try RecordingAudioWriter(url: url, sampleRate: 16_000, channelCount: 1)
        let samples = [Float](repeating: 0.25, count: frames)
        try samples.withUnsafeBufferPointer { try writer.append($0, frameCount: UInt32(frames), sampleRate: 16_000, channelCount: 1) }
        try writer.finish()
    }

    /// The RIFF and data sizes a writer that never closed leaves behind.
    private func zeroSizeFields(of url: URL) throws {
        let data = try Data(contentsOf: url)
        let dataChunk = try XCTUnwrap(data.range(of: Data("data".utf8)))
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        for offset in [UInt64(4), UInt64(dataChunk.upperBound)] {
            try handle.seek(toOffset: offset)
            try handle.write(contentsOf: Data(count: 4))
        }
    }

    private func waitUntil(timeout: Duration = .seconds(2), _ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else { return XCTFail("Condition not met in time") }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

private final class RecoveryGrantedSystemAudio: SystemAudioAuthorizing {
    func status() -> SystemAudioAuthorization { .granted }
    func request() async -> SystemAudioAuthorization { .granted }
}

private final class RecoveryQuietSystemAudio: SystemAudioCapturing, @unchecked Sendable {
    var lastDeliveryNanoseconds: UInt64? { DispatchTime.now().uptimeNanoseconds }
    func start(writingTo url: URL, meetingStartNanoseconds: UInt64) throws {}
    func restart() throws {}
    func stop() -> MeetingTrackCaptureResult { MeetingTrackCaptureResult() }
}

private final class RecoveryTranscriber: TimedSpeechTranscribing {
    var calls = 0

    func transcribeTimed(
        samples: [Float], model: any TranscriptionModel, context: TranscriptionRequestContext
    ) async throws -> [TimedTranscriptSegment] {
        calls += 1
        return TimedTranscriptSegment.untimed("recovered", sampleCount: samples.count)
    }

    func speechRegions(in samples: [Float]) async throws -> [Range<Int>]? { nil }
    func releaseResources() async {}
}
