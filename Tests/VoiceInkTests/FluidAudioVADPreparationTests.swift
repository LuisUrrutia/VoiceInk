import FluidAudio
import Foundation
import XCTest
@testable import VoiceInk

final class FluidAudioVADPreparationTests: XCTestCase {
    private let model = FluidAudioModel(
        name: "parakeet-ultra", displayName: "Parakeet Ultra", description: "Fixture",
        size: "1 GB", speed: 1, accuracy: 1, ramUsage: 1, supportedLanguages: ["en": "English"]
    )

    func testDisabledVADDoesNotLoadAndPreservesFullAudio() async throws {
        let loader = VADLoaderFixture()
        let service = FluidAudioTranscriptionService(vadCache: FluidAudioVADCache(
            loader: { try await loader.load() }, isEnabled: { false }
        ))
        let samples: [Float] = [0.1, 0.2, 0.3]

        let ready = try await service.prepareVAD(recordingID: UUID(), model: model)
        let audio = try await service.preparedSpeechAudio(in: samples)
        let segments = try await service.detectedSpeechSegments(in: samples)
        let count = await loader.loadCount

        XCTAssertFalse(ready)
        XCTAssertEqual(audio, samples)
        XCTAssertNil(segments)
        XCTAssertEqual(count, 0)
    }

    func testCompatiblePreparationAndShortStopShareOneLoad() async throws {
        let loader = VADLoaderFixture(delayedLoads: 1)
        let service = makeService(loader)
        let recordingID = UUID()
        let preparation = Task { try await service.prepareVAD(recordingID: recordingID, model: model) }
        await loader.waitForLoads(1)
        let overlapping = Task { try await service.prepareVAD(recordingID: recordingID, model: model) }
        let shortStop = Task { try await service.detectedSpeechSegments(in: [0.1, 0.2]) }

        await loader.finishNextLoad()
        let ready = try await preparation.value
        let overlappingReady = try await overlapping.value
        let segments = try await shortStop.value
        let count = await loader.loadCount

        XCTAssertTrue(ready)
        XCTAssertTrue(overlappingReady)
        XCTAssertEqual(segments?.map(\.startTime), [0.25, 1.5])
        XCTAssertEqual(count, 1)
        await service.releaseVADPreparation(recordingID: recordingID)
    }

    func testFailedPreparationUsesFullAudioWithoutRepeatedLoads() async throws {
        let loader = VADLoaderFixture(fails: true)
        let service = makeService(loader)
        let samples: [Float] = [0.1, 0.2]

        let ready = try await service.prepareVAD(recordingID: UUID(), model: model)
        let audio = try await service.preparedSpeechAudio(in: samples)
        let segments = try await service.detectedSpeechSegments(in: samples)
        let count = await loader.loadCount

        XCTAssertFalse(ready)
        XCTAssertEqual(audio, samples)
        XCTAssertNil(segments)
        XCTAssertEqual(count, 1)
        await service.cleanup()
    }

    func testSegmentationFailurePreservesFullAudio() async throws {
        let loader = VADLoaderFixture(manager: VADManagerFixture(fails: true))
        let service = makeService(loader)
        let samples: [Float] = [0.1, 0.2]
        let ready = try await service.prepareVAD(recordingID: UUID(), model: model)

        let audio = try await service.preparedSpeechAudio(in: samples)
        let segments = try await service.detectedSpeechSegments(in: samples)

        XCTAssertTrue(ready)
        XCTAssertEqual(audio, samples)
        XCTAssertNil(segments)
        await service.cleanup()
    }

    func testPreparationPreservesSegmentationPaddingAndOriginalPositions() async throws {
        let loader = VADLoaderFixture()
        let service = makeService(loader)
        let samples: [Float] = [0.1, 0.2, 0.3, 0.4]
        let lazyAudio = try await service.preparedSpeechAudio(in: samples)
        let lazySegments = try await service.detectedSpeechSegments(in: samples)
        await service.cleanup()

        _ = try await service.prepareVAD(recordingID: UUID(), model: model)
        let preparedAudio = try await service.preparedSpeechAudio(in: samples)
        let preparedSegments = try await service.detectedSpeechSegments(in: samples)

        XCTAssertEqual(preparedAudio, lazyAudio)
        XCTAssertEqual(Array(preparedAudio.prefix(2)), [0.2, 0.4])
        XCTAssertEqual(preparedAudio.count, ASRConstants.minimumRequiredSamples(forSampleRate: ASRConstants.sampleRate))
        XCTAssertTrue(preparedAudio.dropFirst(2).allSatisfy { $0 == 0 })
        XCTAssertEqual(preparedSegments?.map(\.startTime), lazySegments?.map(\.startTime))
        XCTAssertEqual(preparedSegments?.map { $0.startSample(sampleRate: 16_000) }, [4_000, 24_000])
        XCTAssertEqual(preparedSegments?.map { $0.endSample(sampleRate: 16_000) }, [8_000, 32_000])
        await service.cleanup()
    }

    func testReleaseRejectsStaleLoadAndSerializesRestart() async throws {
        let loader = VADLoaderFixture(delayedLoads: 1)
        let cache = makeCache(loader)
        let oldID = UUID()
        let old = Task { try await cache.prepare(recordingID: oldID, modelName: "old") }
        await loader.waitForLoads(1)
        let release = Task { await cache.release(recordingID: oldID) }
        // A model change invalidates the old generation independently of task cancellation.
        let new = Task { try await cache.prepare(recordingID: UUID(), modelName: "new") }
        await loader.waitForCancellations(1)

        await loader.finishNextLoad()
        await release.value
        await assertCanceled(old)
        let ready = try await new.value
        let count = await loader.loadCount
        let maxConcurrentLoads = await loader.maxConcurrentLoads

        XCTAssertTrue(ready)
        XCTAssertEqual(count, 2)
        XCTAssertEqual(maxConcurrentLoads, 1)
        await cache.cleanup()
    }

    func testStaleReleaseDoesNotDiscardNewOwner() async throws {
        let loader = VADLoaderFixture()
        let cache = makeCache(loader)
        let oldID = UUID()
        let newID = UUID()
        _ = try await cache.prepare(recordingID: oldID, modelName: "ultra")
        _ = try await cache.prepare(recordingID: newID, modelName: "ultra")

        await cache.release(recordingID: oldID)
        _ = try await cache.prepare(recordingID: newID, modelName: "ultra")
        let count = await loader.loadCount

        XCTAssertEqual(count, 1)
        await cache.cleanup()
    }

    // MARK: - Several owners

    func testFirstOwnerReleaseKeepsManagerForSecondOwnerUntilItReleases() async throws {
        let lifetime = VADLifetimeFixture()
        let loader = VADLoaderFixture(lifetime: lifetime)
        let service = makeService(loader)
        let first = UUID()
        let second = UUID()
        _ = try await service.prepareVAD(recordingID: first, model: model)
        _ = try await service.prepareVAD(recordingID: second, model: model)

        await service.releaseVADPreparation(recordingID: first)
        let segments = try await service.detectedSpeechSegments(in: [0.1, 0.2])
        let containsSpeech = try await service.containsSpeech(in: [0.1, 0.2])
        let loadsWhileShared = await loader.loadCount
        XCTAssertEqual(lifetime.liveCount, 1)

        await service.releaseVADPreparation(recordingID: second)

        XCTAssertEqual(segments?.map(\.startTime), [0.25, 1.5])
        XCTAssertEqual(containsSpeech, true)
        XCTAssertEqual(loadsWhileShared, 1)
        XCTAssertEqual(lifetime.liveCount, 0)
    }

    func testInterleavedPreparationsAndReleasesFreeOnlyAfterLastOwner() async throws {
        let lifetime = VADLifetimeFixture()
        let loader = VADLoaderFixture(lifetime: lifetime)
        let cache = makeCache(loader)
        let (a, b, c) = (UUID(), UUID(), UUID())

        _ = try await cache.prepare(recordingID: a, modelName: "ultra")
        _ = try await cache.prepare(recordingID: b, modelName: "ultra")
        await cache.release(recordingID: a)
        _ = try await cache.prepare(recordingID: c, modelName: "ultra")
        await cache.release(recordingID: b)
        await cache.release(recordingID: a)
        XCTAssertEqual(lifetime.liveCount, 1)
        _ = try await cache.prepare(recordingID: a, modelName: "ultra")
        await cache.release(recordingID: c)
        XCTAssertEqual(lifetime.liveCount, 1)
        await cache.release(recordingID: a)
        XCTAssertEqual(lifetime.liveCount, 0)
        _ = try await cache.prepare(recordingID: b, modelName: "ultra")
        let count = await loader.loadCount

        XCTAssertEqual(count, 2)
        XCTAssertEqual(lifetime.liveCount, 1)
        await cache.release(recordingID: b)
        XCTAssertEqual(lifetime.liveCount, 0)
    }

    func testOwnersShareOneLoadInFlight() async throws {
        let loader = VADLoaderFixture(delayedLoads: 1)
        let cache = makeCache(loader)
        let service = FluidAudioTranscriptionService(vadCache: cache)
        let first = UUID()
        let second = UUID()
        let firstPreparation = Task { try await service.prepareVAD(recordingID: first, model: model) }
        await loader.waitForLoads(1)
        let secondPreparation = Task { try await service.prepareVAD(recordingID: second, model: model) }
        await waitForLeases(2, in: cache)

        await loader.finishNextLoad()
        let firstReady = try await firstPreparation.value
        let secondReady = try await secondPreparation.value
        await service.releaseVADPreparation(recordingID: first)
        let segments = try await service.detectedSpeechSegments(in: [0.1, 0.2])
        let count = await loader.loadCount
        let maxConcurrentLoads = await loader.maxConcurrentLoads

        XCTAssertTrue(firstReady)
        XCTAssertTrue(secondReady)
        XCTAssertEqual(segments?.map(\.startTime), [0.25, 1.5])
        XCTAssertEqual(count, 1)
        XCTAssertEqual(maxConcurrentLoads, 1)
        await service.releaseVADPreparation(recordingID: second)
    }

    func testOneOwnerCancellationKeepsSharedLoadForOtherOwner() async throws {
        let lifetime = VADLifetimeFixture()
        let loader = VADLoaderFixture(delayedLoads: 1, lifetime: lifetime)
        let cache = makeCache(loader)
        let canceled = UUID()
        let kept = UUID()
        let canceledPreparation = Task { try await cache.prepare(recordingID: canceled, modelName: "ultra") }
        await loader.waitForLoads(1)
        let keptPreparation = Task { try await cache.prepare(recordingID: kept, modelName: "ultra") }
        await waitForLeases(2, in: cache)

        canceledPreparation.cancel()
        await loader.finishNextLoad()
        await assertCanceled(canceledPreparation)
        let ready = try await keptPreparation.value
        _ = try await cache.manager()
        let count = await loader.loadCount

        XCTAssertTrue(ready)
        XCTAssertEqual(count, 1)
        XCTAssertEqual(lifetime.liveCount, 1)
        await cache.release(recordingID: kept)
        XCTAssertEqual(lifetime.liveCount, 0)
    }

    func testModelChangeInvalidatesEveryOwnerAndTheirReleasesBecomeHarmless() async throws {
        let lifetime = VADLifetimeFixture()
        let loader = VADLoaderFixture(lifetime: lifetime)
        let cache = makeCache(loader)
        let (a, b, c) = (UUID(), UUID(), UUID())
        _ = try await cache.prepare(recordingID: a, modelName: "ultra")
        _ = try await cache.prepare(recordingID: b, modelName: "ultra")

        _ = try await cache.prepare(recordingID: c, modelName: "v3")
        await cache.release(recordingID: a)
        await cache.release(recordingID: b)
        let count = await loader.loadCount
        XCTAssertEqual(lifetime.liveCount, 1)

        await cache.release(recordingID: c)

        XCTAssertEqual(count, 2)
        XCTAssertEqual(lifetime.liveCount, 0)
    }

    func testModelChangeRejectsEveryOwnerOfALoadInFlight() async throws {
        let loader = VADLoaderFixture(delayedLoads: 1)
        let cache = makeCache(loader)
        let first = Task { try await cache.prepare(recordingID: UUID(), modelName: "ultra") }
        await loader.waitForLoads(1)
        let second = Task { try await cache.prepare(recordingID: UUID(), modelName: "ultra") }
        await waitForLeases(2, in: cache)
        let changed = Task { try await cache.prepare(recordingID: UUID(), modelName: "v3") }
        await loader.waitForCancellations(1)

        await loader.finishNextLoad()
        await assertCanceled(first)
        await assertCanceled(second)
        let ready = try await changed.value
        let maxConcurrentLoads = await loader.maxConcurrentLoads

        XCTAssertTrue(ready)
        XCTAssertEqual(maxConcurrentLoads, 1)
        await cache.cleanup()
    }

    func testDisablingVADReleasesEveryOwner() async throws {
        let lifetime = VADLifetimeFixture()
        let setting = VADSettingFixture()
        let loader = VADLoaderFixture(lifetime: lifetime)
        let cache = FluidAudioVADCache(loader: { try await loader.load() }, isEnabled: { setting.isEnabled })
        let (a, b) = (UUID(), UUID())
        _ = try await cache.prepare(recordingID: a, modelName: "ultra")
        _ = try await cache.prepare(recordingID: b, modelName: "ultra")

        setting.setEnabled(false)
        let disabled = try await cache.manager()
        XCTAssertEqual(lifetime.liveCount, 0)
        setting.setEnabled(true)
        let c = UUID()
        _ = try await cache.prepare(recordingID: c, modelName: "ultra")
        await cache.release(recordingID: a)
        await cache.release(recordingID: b)
        let count = await loader.loadCount

        XCTAssertNil(disabled)
        XCTAssertEqual(count, 2)
        XCTAssertEqual(lifetime.liveCount, 1)
        await cache.release(recordingID: c)
        XCTAssertEqual(lifetime.liveCount, 0)
    }

    func testCleanupWithSeveralOwnersAwaitsLoadAndReleasesManager() async throws {
        let lifetime = VADLifetimeFixture()
        let loader = VADLoaderFixture(delayedLoads: 1, lifetime: lifetime)
        let cache = makeCache(loader)
        let service = FluidAudioTranscriptionService(vadCache: cache)
        let (a, b) = (UUID(), UUID())
        let first = Task { try await service.prepareVAD(recordingID: a, model: model) }
        await loader.waitForLoads(1)
        let second = Task { try await service.prepareVAD(recordingID: b, model: model) }
        await waitForLeases(2, in: cache)

        let cleanup = Task { await service.cleanup() }
        await loader.waitForCancellations(1)
        await loader.finishNextLoad()
        await cleanup.value
        await assertCanceled(first)
        await assertCanceled(second)
        XCTAssertEqual(lifetime.liveCount, 0)
        await service.releaseVADPreparation(recordingID: a)
        _ = try await service.prepareVAD(recordingID: UUID(), model: model)
        await service.releaseVADPreparation(recordingID: b)
        let count = await loader.loadCount

        XCTAssertEqual(count, 2)
        XCTAssertEqual(lifetime.liveCount, 1)
        await service.cleanup()
        XCTAssertEqual(lifetime.liveCount, 0)
    }

    func testCanceledPreparationDoesNotRetainLoadedManager() async throws {
        let loader = VADLoaderFixture(delayedLoads: 1)
        let cache = makeCache(loader)
        let recordingID = UUID()
        let preparation = Task { try await cache.prepare(recordingID: recordingID, modelName: "ultra") }
        await loader.waitForLoads(1)

        preparation.cancel()
        await loader.finishNextLoad()
        await assertCanceled(preparation)
        _ = try await cache.prepare(recordingID: recordingID, modelName: "ultra")
        let count = await loader.loadCount

        XCTAssertEqual(count, 2)
        await cache.cleanup()
    }

    func testCleanupAllowsFailureRetryAndFreshRecording() async throws {
        let loader = VADLoaderFixture(fails: true)
        let service = makeService(loader)
        let old = try await service.prepareVAD(recordingID: UUID(), model: model)

        await service.cleanup()
        await loader.setFailure(false)
        let ready = try await service.prepareVAD(recordingID: UUID(), model: model)
        let count = await loader.loadCount

        XCTAssertFalse(old)
        XCTAssertTrue(ready)
        XCTAssertEqual(count, 2)
        await service.cleanup()
    }

    func testModelChangeRejectsPriorPreparation() async throws {
        let loader = VADLoaderFixture(delayedLoads: 1)
        let cache = makeCache(loader)
        let id = UUID()
        let old = Task { try await cache.prepare(recordingID: id, modelName: "v3") }
        await loader.waitForLoads(1)
        let new = Task { try await cache.prepare(recordingID: id, modelName: "ultra") }
        await loader.waitForCancellations(1)

        await loader.finishNextLoad()
        await assertCanceled(old)
        let ready = try await new.value
        let maxConcurrentLoads = await loader.maxConcurrentLoads

        XCTAssertTrue(ready)
        XCTAssertEqual(maxConcurrentLoads, 1)
        await cache.cleanup()
    }

    func testDisablingVADWhileLoadingDiscardsPreparationAndCanRestart() async throws {
        let loader = VADLoaderFixture(delayedLoads: 1)
        let setting = VADSettingFixture()
        let cache = FluidAudioVADCache(loader: { try await loader.load() }, isEnabled: { setting.isEnabled })
        let preparation = Task { try await cache.prepare(recordingID: UUID(), modelName: "ultra") }
        await loader.waitForLoads(1)

        setting.setEnabled(false)
        await loader.finishNextLoad()
        let ready = try await preparation.value
        setting.setEnabled(true)
        let restarted = try await cache.prepare(recordingID: UUID(), modelName: "ultra")
        let count = await loader.loadCount

        XCTAssertFalse(ready)
        XCTAssertTrue(restarted)
        XCTAssertEqual(count, 2)
        await cache.cleanup()
    }

    func testOtherProviderDoesNotPrepareVAD() async throws {
        let loader = VADLoaderFixture()
        let service = makeService(loader)
        let apple = NativeAppleModel(name: "apple", displayName: "Apple", description: "Fixture",
                                     isMultilingualModel: false, supportedLanguages: ["en": "English"])

        let ready = try await service.prepareVAD(recordingID: UUID(), model: apple)
        let count = await loader.loadCount

        XCTAssertFalse(ready)
        XCTAssertEqual(count, 0)
    }

    func testLeaseReleaseAndCleanupReleaseManagerReferences() async throws {
        let lifetime = VADLifetimeFixture()
        let cache = FluidAudioVADCache(loader: { LifetimeVAD(lifetime: lifetime) }, isEnabled: { true })
        let id = UUID()
        _ = try await cache.prepare(recordingID: id, modelName: "ultra")
        XCTAssertEqual(lifetime.liveCount, 1)

        await cache.release(recordingID: id)
        XCTAssertEqual(lifetime.liveCount, 0)
        _ = try await cache.prepare(recordingID: UUID(), modelName: "ultra")
        XCTAssertEqual(lifetime.liveCount, 1)
        await cache.cleanup()

        XCTAssertEqual(lifetime.liveCount, 0)
    }

    private func waitForLeases(_ count: Int, in cache: FluidAudioVADCache) async {
        while await cache.leaseCount < count {
            await Task.yield()
        }
    }

    private func makeCache(_ loader: VADLoaderFixture) -> FluidAudioVADCache {
        FluidAudioVADCache(loader: { try await loader.load() }, isEnabled: { true })
    }

    private func makeService(_ loader: VADLoaderFixture) -> FluidAudioTranscriptionService {
        FluidAudioTranscriptionService(vadCache: makeCache(loader))
    }

    private func assertCanceled(_ task: Task<Bool, Error>, file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await task.value
            XCTFail("Invalidated preparation returned successfully", file: file, line: line)
        } catch is CancellationError {
        } catch {
            XCTFail("Expected CancellationError, got \(error)", file: file, line: line)
        }
    }
}

private enum VADFixtureError: Error { case unavailable }

private final class VADSettingFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var enabled = true
    var isEnabled: Bool { lock.withLock { enabled } }
    func setEnabled(_ value: Bool) { lock.withLock { enabled = value } }
}

private final class VADLifetimeFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var liveCount: Int { lock.withLock { count } }
    func changed(by delta: Int) { lock.withLock { count += delta } }
}

private final class LifetimeVAD: FluidAudioVADManaging {
    private let lifetime: VADLifetimeFixture
    init(lifetime: VADLifetimeFixture) {
        self.lifetime = lifetime
        lifetime.changed(by: 1)
    }
    deinit { lifetime.changed(by: -1) }
    func segmentSpeech(_ samples: [Float]) async throws -> [VadSegment] {
        try await VADManagerFixture().segmentSpeech(samples)
    }
    func segmentSpeech(_ samples: [Float], config: VadSegmentationConfig) async throws -> [VadSegment] {
        try await VADManagerFixture().segmentSpeech(samples, config: config)
    }
    func segmentSpeechAudio(_ samples: [Float]) async throws -> [[Float]] {
        try await VADManagerFixture().segmentSpeechAudio(samples)
    }
}

private struct VADManagerFixture: FluidAudioVADManaging {
    var fails = false

    func segmentSpeech(_ samples: [Float]) async throws -> [VadSegment] {
        if fails { throw VADFixtureError.unavailable }
        return [VadSegment(startTime: 0.25, endTime: 0.5), VadSegment(startTime: 1.5, endTime: 2)]
    }

    func segmentSpeech(_ samples: [Float], config: VadSegmentationConfig) async throws -> [VadSegment] {
        try await segmentSpeech(samples)
    }

    func segmentSpeechAudio(_ samples: [Float]) async throws -> [[Float]] {
        if fails { throw VADFixtureError.unavailable }
        return samples.isEmpty ? [] : [[samples[1]], [samples.last!]]
    }
}

private actor VADLoaderFixture {
    private let delayedLoads: Int
    private let manager: VADManagerFixture
    private let lifetime: VADLifetimeFixture?
    private var fails: Bool
    private var pending: [CheckedContinuation<any FluidAudioVADManaging, Error>] = []
    private var waiting: [(Int, CheckedContinuation<Void, Never>)] = []
    private var cancellationWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var cancellationCount = 0
    private var activeLoads = 0
    private(set) var loadCount = 0
    private(set) var maxConcurrentLoads = 0

    init(delayedLoads: Int = 0, fails: Bool = false, manager: VADManagerFixture = VADManagerFixture(),
         lifetime: VADLifetimeFixture? = nil) {
        self.delayedLoads = delayedLoads
        self.fails = fails
        self.manager = manager
        self.lifetime = lifetime
    }

    private func makeManager() -> any FluidAudioVADManaging {
        lifetime.map { LifetimeVAD(lifetime: $0) } ?? manager
    }

    func load() async throws -> any FluidAudioVADManaging {
        loadCount += 1
        activeLoads += 1
        maxConcurrentLoads = max(maxConcurrentLoads, activeLoads)
        defer { activeLoads -= 1 }
        if loadCount <= delayedLoads {
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    pending.append(continuation)
                    resumeWaiters()
                }
            } onCancel: {
                Task { await self.recordCancellation() }
            }
        }
        resumeWaiters()
        if fails { throw VADFixtureError.unavailable }
        return makeManager()
    }

    func waitForLoads(_ count: Int) async {
        guard loadCount < count else { return }
        await withCheckedContinuation { waiting.append((count, $0)) }
    }

    func finishNextLoad() {
        let continuation = pending.removeFirst()
        if fails { continuation.resume(throwing: VADFixtureError.unavailable) }
        else { continuation.resume(returning: makeManager()) }
    }

    func setFailure(_ value: Bool) { fails = value }

    func waitForCancellations(_ count: Int) async {
        guard cancellationCount < count else { return }
        await withCheckedContinuation { cancellationWaiters.append((count, $0)) }
    }

    private func recordCancellation() {
        cancellationCount += 1
        let ready = cancellationWaiters.filter { $0.0 <= cancellationCount }
        cancellationWaiters.removeAll { $0.0 <= cancellationCount }
        ready.forEach { $0.1.resume() }
    }

    private func resumeWaiters() {
        let ready = waiting.filter { $0.0 <= loadCount }
        waiting.removeAll { $0.0 <= loadCount }
        ready.forEach { $0.1.resume() }
    }
}
