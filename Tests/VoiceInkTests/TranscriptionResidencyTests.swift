import CoreML
import FluidAudio
import SwiftData
import XCTest
@testable import VoiceInk

@MainActor
final class TranscriptionResidencyTests: XCTestCase {
    // MARK: - Residency

    func testFinishingOneOwnerKeepsTheOtherOwnersModelAndVADLease() async throws {
        let probe = ResidencyRuntimeProbe()
        let vad = CountingVADLoader()
        let service = probe.makeService(vadCache: FluidAudioVADCache(loader: { try await vad.load() }, isEnabled: { true }))
        let registry = try makeRegistry(fluidAudioService: service)
        var releases = 0
        let residency = TranscriptionResidency {
            releases += 1
            await registry.cleanup()
        }
        let a = UUID()
        let b = UUID()
        residency.acquire(a)
        try await registry.prepareForRecording(parakeetBatch, recordingID: a, whisperModelManager: whisper)
        residency.acquire(b)
        try await registry.prepareForRecording(parakeetBatch, recordingID: b, whisperModelManager: whisper)
        let loadsWhileBothOwn = await vad.loadCount

        await registry.releaseRecordingPreparation(recordingID: a, configuration: parakeetBatch)
        await residency.release([a])
        _ = try await service.detectedSpeechSegments(in: [0.1, 0.2])

        XCTAssertEqual(releases, 0, "A is not the last owner")
        let loadsAfterA = await vad.loadCount
        XCTAssertEqual(loadsAfterA, loadsWhileBothOwn, "B's VAD lease survives A's finish")
        XCTAssertNotNil(probe.asrModel, "B's model survives A's finish")
        XCTAssertEqual(probe.log.events, ["load asr"])

        await registry.releaseRecordingPreparation(recordingID: b, configuration: parakeetBatch)
        await residency.release([b])
        _ = try await service.detectedSpeechSegments(in: [0.1, 0.2])

        XCTAssertEqual(releases, 1)
        XCTAssertFalse(residency.isOwned)
        let loadsAfterB = await vad.loadCount
        XCTAssertEqual(loadsAfterB, loadsWhileBothOwn + 1, "the last owner's release frees the VAD")
    }

    func testOnlyTheLastOwnerReleasesAndRelinquishedOwnersDoNotRelease() async {
        var releases = 0
        let residency = TranscriptionResidency { releases += 1 }
        let a = UUID()
        let b = UUID()
        let superseded = UUID()
        residency.acquire(a)
        residency.acquire(b)
        residency.acquire(superseded)

        residency.relinquish(superseded)
        await residency.release([a])
        XCTAssertEqual(releases, 0)
        XCTAssertEqual(residency.ownerCount, 1)
        await residency.release([b])
        XCTAssertEqual(releases, 1)
        await residency.release([b])

        XCTAssertEqual(releases, 2, "a release with no owner left still frees resources, as cleanup always did")
        XCTAssertFalse(residency.isOwned)
    }

    func testNewOwnerWaitsForAReleaseInProgressBeforeLoading() async {
        let gate = ResidencyGate()
        var events: [String] = []
        let residency = TranscriptionResidency {
            events.append("release started")
            await gate.wait()
            events.append("release finished")
        }
        let first = UUID()
        residency.acquire(first)
        let release = Task { @MainActor in await residency.release([first]) }
        await waitUntil { events == ["release started"] }

        residency.acquire(UUID())
        let load = Task { @MainActor in
            await residency.waitForPendingRelease()
            events.append("loaded")
        }
        await waitUntil(timeout: .milliseconds(200)) { events.count > 1 }
        XCTAssertEqual(events, ["release started"])
        gate.open()
        await release.value
        await load.value

        XCTAssertEqual(events, ["release started", "release finished", "loaded"])
        XCTAssertTrue(residency.isOwned)
    }

    // MARK: - Single-flight loads

    func testConcurrentWhisperPreparationsShareOneLoad() async throws {
        let whisper = GatedWhisperModelManager()
        let registry = try makeRegistry(whisper: whisper)
        let configuration = TranscriptionRuntimeConfiguration(
            mode: ModeConfig(name: "Residency fixture", isAIEnhancementEnabled: false),
            model: ImportedWhisperModel(fileBaseName: whisper.fixture.name), languages: ["en"], isRealtimeEnabled: false
        )

        let first = Task { @MainActor in
            try await registry.prepareForRecording(configuration, recordingID: UUID(), whisperModelManager: whisper)
        }
        await waitUntil { whisper.loadCount == 1 }
        let second = Task { @MainActor in
            try await registry.prepareForRecording(configuration, recordingID: UUID(), whisperModelManager: whisper)
        }
        let canceled = Task { @MainActor in
            try await registry.prepareForRecording(configuration, recordingID: UUID(), whisperModelManager: whisper)
        }
        await settle()
        canceled.cancel()
        await settle()
        XCTAssertEqual(whisper.loadCount, 1)
        whisper.gate.open()
        try await first.value
        try await second.value
        let canceledResult = await canceled.result

        XCTAssertEqual(whisper.loadCount, 1, "concurrent preparations never load twice")
        XCTAssertEqual(whisper.canceledLoads, 0, "one canceled waiter does not cancel the shared load")
        XCTAssertThrowsError(try canceledResult.get()) { XCTAssertTrue($0 is CancellationError) }
        try await registry.prepareForRecording(configuration, recordingID: UUID(), whisperModelManager: whisper)
        XCTAssertEqual(whisper.loadCount, 2, "a finished load does not satisfy a later preparation")
    }

    func testCancelingTheLoadingPreparationLetsAWaitingOneLoadAfterIt() async throws {
        let whisper = GatedWhisperModelManager()
        let registry = try makeRegistry(whisper: whisper)
        let configuration = TranscriptionRuntimeConfiguration(
            mode: ModeConfig(name: "Residency fixture", isAIEnhancementEnabled: false),
            model: ImportedWhisperModel(fileBaseName: whisper.fixture.name), languages: ["en"], isRealtimeEnabled: false
        )
        let canceled = Task { @MainActor in
            try await registry.prepareForRecording(configuration, recordingID: UUID(), whisperModelManager: whisper)
        }
        await waitUntil { whisper.loadCount == 1 }

        canceled.cancel()
        let later = Task { @MainActor in
            try await registry.prepareForRecording(configuration, recordingID: UUID(), whisperModelManager: whisper)
        }
        await settle()
        XCTAssertEqual(whisper.loadCount, 1, "the later load waits for the canceled one to exit")
        whisper.gate.open()
        let canceledResult = await canceled.result
        try await later.value

        XCTAssertThrowsError(try canceledResult.get())
        XCTAssertEqual(whisper.canceledLoads, 1)
        XCTAssertEqual(whisper.loadCount, 2)
    }

    func testConcurrentFluidAudioPreparationsShareOneLoad() async throws {
        let service = GatedFluidAudioService(vadCache: FluidAudioVADCache(isEnabled: { false }))
        let registry = try makeRegistry(fluidAudioService: service)

        let first = Task { @MainActor in
            try await registry.prepareForRecording(self.parakeetBatch, recordingID: UUID(), whisperModelManager: self.whisper)
        }
        await waitUntil { service.loadCount == 1 }
        let second = Task { @MainActor in
            try await registry.prepareForRecording(self.parakeetBatch, recordingID: UUID(), whisperModelManager: self.whisper)
        }
        await settle()
        service.gate.open()
        try await first.value
        try await second.value

        XCTAssertEqual(service.loadCount, 1)
    }

    // MARK: - Lane

    func testLocalTranscriptionsRunOneAtATimeInSequenceOrder() async throws {
        let lane = TranscriptionLane()
        let gate = ResidencyGate()
        var order: [UInt64] = []
        let first = Task { @MainActor in
            try await lane.run(sequence: 1, provider: .fluidAudio) {
                order.append(1)
                await gate.wait()
            }
        }
        await waitUntil { order == [1] }
        let third = Task { @MainActor in try await lane.run(sequence: 3, provider: .whisper) { order.append(3) } }
        await waitUntil { lane.waitingCount(local: true) == 1 }
        let second = Task { @MainActor in try await lane.run(sequence: 2, provider: .transcribeCpp) { order.append(2) } }
        await waitUntil { lane.waitingCount(local: true) == 2 }
        XCTAssertEqual(lane.runningCount(local: true), 1)

        gate.open()
        try await first.value
        try await second.value
        try await third.value

        XCTAssertEqual(order, [1, 2, 3])
        XCTAssertEqual(lane.runningCount(local: true), 0)
    }

    func testCloudTranscriptionsRunConcurrentlyUpToTheLimitAndBesideLocalWork() async throws {
        let lane = TranscriptionLane()
        let gates = (0..<3).map { _ in ResidencyGate() }
        let localGate = ResidencyGate()
        var started: [String] = []
        let cloud = (0..<3).map { index in
            Task { @MainActor in
                try await lane.run(sequence: UInt64(index + 1), provider: .groq) {
                    started.append("cloud \(index + 1)")
                    await gates[index].wait()
                }
            }
        }
        let local = Task { @MainActor in
            try await lane.run(sequence: 4, provider: .whisper) {
                started.append("local")
                await localGate.wait()
            }
        }
        await waitUntil { started.count == 3 }

        XCTAssertEqual(TranscriptionLane.cloudConcurrency, 2)
        XCTAssertEqual(Set(started), ["cloud 1", "cloud 2", "local"])
        XCTAssertEqual(lane.runningCount(local: false), 2)
        XCTAssertEqual(lane.waitingCount(local: false), 1)
        gates[1].open()
        await waitUntil { started.count == 4 }
        XCTAssertEqual(started.last, "cloud 3")
        gates.forEach { $0.open() }
        localGate.open()
        for task in cloud { try await task.value }
        try await local.value
    }

    func testCanceledQueuedEntryLeavesWithoutBlockingLaterEntries() async throws {
        let lane = TranscriptionLane()
        let gate = ResidencyGate()
        var ran: [UInt64] = []
        let first = Task { @MainActor in
            try await lane.run(sequence: 1, provider: .fluidAudio) {
                ran.append(1)
                await gate.wait()
            }
        }
        await waitUntil { ran == [1] }
        let canceled = Task { @MainActor in try await lane.run(sequence: 2, provider: .fluidAudio) { ran.append(2) } }
        let later = Task { @MainActor in try await lane.run(sequence: 3, provider: .fluidAudio) { ran.append(3) } }
        await waitUntil { lane.waitingCount(local: true) == 2 }

        canceled.cancel()
        let canceledResult = await canceled.result
        XCTAssertThrowsError(try canceledResult.get()) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertEqual(lane.waitingCount(local: true), 1, "the canceled entry leaves while the first still runs")
        gate.open()
        try await first.value
        try await later.value

        XCTAssertEqual(ran, [1, 3])
    }

    func testCanceledRecordingEndsItsLaneWaitThroughThePreparation() async throws {
        let lane = TranscriptionLane()
        let gate = ResidencyGate()
        let blocker = Task { @MainActor in try await lane.run(sequence: 1, provider: .whisper) { await gate.wait() } }
        await waitUntil { lane.runningCount(local: true) == 1 }
        let preparation = RecordingTranscriptionPreparation(timing: RecordingTimingTrace())
        var transcribed = false
        let transcription = Task { @MainActor in
            try await preparation.performTranscription {
                try await lane.run(sequence: 2, provider: .whisper) {
                    transcribed = true
                    return "text"
                }
            }
        }
        await waitUntil { lane.waitingCount(local: true) == 1 }

        preparation.cancel()
        let result = await transcription.result

        XCTAssertThrowsError(try result.get())
        XCTAssertEqual(lane.waitingCount(local: true), 0)
        XCTAssertFalse(transcribed)
        gate.open()
        try await blocker.value
    }

    // MARK: - Idle unload

    func testResidencyNeitherBlocksAnIdleUnloadNorReloadsAfterIt() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "TranscriptionResidencyTests.\(UUID().uuidString)"))
        defaults.set(true, forKey: IdleModelUnloadSettings.isEnabledKey)
        defaults.set(5, forKey: IdleModelUnloadSettings.minutesKey)
        let clock = ManualIdleClock()
        let coordinator = IdleModelUnloadCoordinator(defaults: defaults, now: { clock.now }, schedule: clock.schedule)
        let probe = ResidencyRuntimeProbe()
        let service = probe.makeService(vadCache: FluidAudioVADCache(isEnabled: { false }))
        let registry = try makeRegistry(fluidAudioService: service, idleUnload: coordinator)
        coordinator.configure(isBusy: { false }, unload: { await registry.unloadIdleModels() })
        let residency = TranscriptionResidency { await registry.cleanup() }
        let owner = UUID()
        residency.acquire(owner)
        let use = registry.beginModelUse()
        try await registry.prepareForRecording(parakeetBatch, recordingID: owner, whisperModelManager: whisper)

        clock.advance(by: .seconds(10 * 60))
        await coordinator.waitForPendingUnload()
        XCTAssertNotNil(probe.asrModel, "the dictation's use lease, not the residency, blocks the unload")
        use.release()
        clock.advance(by: .seconds(5 * 60))
        await coordinator.waitForPendingUnload()

        XCTAssertTrue(coordinator.hasUnloadedModels, "a residency owner does not keep models alive")
        await waitUntil { probe.asrModel == nil }
        XCTAssertNil(probe.asrModel)
        await residency.release([owner])
        XCTAssertEqual(probe.log.events, ["load asr"], "the last owner's release after an unload loads nothing")
        try await registry.prepareForRecording(parakeetBatch, recordingID: UUID(), whisperModelManager: whisper)
        XCTAssertEqual(probe.log.events, ["load asr", "load asr"], "the next preparation reloads on demand")
    }

    // MARK: - Helpers

    private let whisper = WhisperModelManager(modelsDirectory: URL(fileURLWithPath: "/unused-models"))

    private var parakeetBatch: TranscriptionRuntimeConfiguration {
        TranscriptionRuntimeConfiguration(
            mode: ModeConfig(name: "Residency fixture", isAIEnhancementEnabled: false),
            model: FluidAudioModel(
                name: "parakeet-tdt-0.6b-v3", displayName: "Parakeet V3", description: "Fixture", size: "",
                speed: 1, accuracy: 1, ramUsage: 1, supportedLanguages: ["en": "English"]
            ), languages: ["en"], isRealtimeEnabled: false
        )
    }

    private func makeRegistry(
        whisper: WhisperModelManager? = nil, fluidAudioService: FluidAudioTranscriptionService? = nil,
        idleUnload: IdleModelUnloadCoordinator? = nil
    ) throws -> TranscriptionServiceRegistry {
        let container = try ModelContainer(
            for: Transcription.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let whisper = whisper ?? self.whisper
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "TranscriptionResidencyTests.\(UUID().uuidString)"))
        let coordinator = idleUnload ?? IdleModelUnloadCoordinator(defaults: defaults)
        return TranscriptionServiceRegistry(
            modelProvider: whisper, modelsDirectory: whisper.modelsDirectory, modelContext: ModelContext(container),
            fluidAudioService: fluidAudioService, idleUnload: coordinator
        )
    }

    private func settle() async {
        for _ in 0..<50 { await Task.yield() }
    }

    private func waitUntil(timeout: Duration = .seconds(5), _ condition: @MainActor () -> Bool) async {
        let deadline = ContinuousClock.now + timeout
        while !condition(), ContinuousClock.now < deadline { await Task.yield() }
    }
}

@MainActor
private final class ResidencyGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}

@MainActor
private final class EventLog {
    var events: [String] = []
}

private final class ResidencyMLModel: MLModel {}

/// Replaces FluidAudio's model file access, keeping only a weak reference to the loaded model.
@MainActor
private final class ResidencyRuntimeProbe {
    let log = EventLog()
    weak var asrModel: MLModel?

    func makeService(vadCache: FluidAudioVADCache) -> FluidAudioTranscriptionService {
        let runtime = FluidAudioTranscriptionService.ModelRuntime(
            loadAsrModels: { version in
                let preprocessor = ResidencyMLModel()
                await MainActor.run {
                    self.asrModel = preprocessor
                    self.log.events.append("load asr")
                }
                return AsrModels(
                    encoder: ResidencyMLModel(), preprocessor: preprocessor, decoder: ResidencyMLModel(),
                    joint: ResidencyMLModel(), configuration: MLModelConfiguration(), vocabulary: [:], version: version
                )
            },
            loadUnifiedModel: { _ in },
            transcribeUnified: { _, _ in "" }
        )
        return FluidAudioTranscriptionService(vadCache: vadCache, runtime: runtime)
    }
}

private struct SilentVAD: FluidAudioVADManaging {
    func segmentSpeech(_ samples: [Float]) async throws -> [VadSegment] { [] }
    func segmentSpeech(_ samples: [Float], config: VadSegmentationConfig) async throws -> [VadSegment] { [] }
    func segmentSpeechAudio(_ samples: [Float]) async throws -> [[Float]] { [] }
}

private actor CountingVADLoader {
    private(set) var loadCount = 0

    func load() -> any FluidAudioVADManaging {
        loadCount += 1
        return SilentVAD()
    }
}

/// Counts Whisper loads and holds each until the gate opens; it never creates a context.
@MainActor
private final class GatedWhisperModelManager: WhisperModelManager {
    let fixture = WhisperModelFile(name: "residency-fixture", url: URL(fileURLWithPath: "/unused-models/residency-fixture.bin"))
    let gate = ResidencyGate()
    private(set) var loadCount = 0
    private(set) var canceledLoads = 0

    init() {
        super.init(modelsDirectory: URL(fileURLWithPath: "/unused-models"))
        availableModels = [fixture]
    }

    override func loadModel(_ model: WhisperModelFile) async throws {
        loadCount += 1
        await gate.wait()
        if Task.isCancelled {
            canceledLoads += 1
            throw CancellationError()
        }
    }
}

@MainActor
private final class GatedFluidAudioService: FluidAudioTranscriptionService {
    let gate = ResidencyGate()
    private(set) var loadCount = 0

    override func loadModel(for model: FluidAudioModel) async throws {
        loadCount += 1
        await gate.wait()
    }
}

@MainActor
private final class ManualIdleClock {
    private final class Timer: IdleModelUnloadTimer {
        let deadline: ContinuousClock.Instant
        let action: @MainActor () -> Void
        var isCancelled = false

        init(deadline: ContinuousClock.Instant, action: @escaping @MainActor () -> Void) {
            self.deadline = deadline
            self.action = action
        }

        func cancel() { isCancelled = true }
    }

    var now = ContinuousClock.now
    private var timers: [Timer] = []

    func schedule(_ delay: Duration, _ action: @escaping @MainActor () -> Void) -> any IdleModelUnloadTimer {
        let timer = Timer(deadline: now + delay, action: action)
        timers.append(timer)
        return timer
    }

    func advance(by duration: Duration) {
        let target = now + duration
        while true {
            timers.removeAll(where: \.isCancelled)
            guard let next = timers.filter({ $0.deadline <= target }).min(by: { $0.deadline < $1.deadline }) else { break }
            timers.removeAll { $0 === next }
            now = max(now, next.deadline)
            next.action()
        }
        now = target
    }
}
