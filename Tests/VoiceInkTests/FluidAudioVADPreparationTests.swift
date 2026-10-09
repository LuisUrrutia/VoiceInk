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
        // A new identity invalidates the old generation independently of task cancellation.
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

        XCTAssertEqual(count, 2)
        await cache.cleanup()
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
    func segmentSpeech(_ samples: [Float]) async throws -> [VadSegment] { [] }
    func segmentSpeechAudio(_ samples: [Float]) async throws -> [[Float]] { [] }
}

private struct VADManagerFixture: FluidAudioVADManaging {
    var fails = false

    func segmentSpeech(_ samples: [Float]) async throws -> [VadSegment] {
        if fails { throw VADFixtureError.unavailable }
        return [VadSegment(startTime: 0.25, endTime: 0.5), VadSegment(startTime: 1.5, endTime: 2)]
    }

    func segmentSpeechAudio(_ samples: [Float]) async throws -> [[Float]] {
        if fails { throw VADFixtureError.unavailable }
        return samples.isEmpty ? [] : [[samples[1]], [samples.last!]]
    }
}

private actor VADLoaderFixture {
    private let delayedLoads: Int
    private let manager: VADManagerFixture
    private var fails: Bool
    private var pending: [CheckedContinuation<any FluidAudioVADManaging, Error>] = []
    private var waiting: [(Int, CheckedContinuation<Void, Never>)] = []
    private var cancellationWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var cancellationCount = 0
    private var activeLoads = 0
    private(set) var loadCount = 0
    private(set) var maxConcurrentLoads = 0

    init(delayedLoads: Int = 0, fails: Bool = false, manager: VADManagerFixture = VADManagerFixture()) {
        self.delayedLoads = delayedLoads
        self.fails = fails
        self.manager = manager
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
        return manager
    }

    func waitForLoads(_ count: Int) async {
        guard loadCount < count else { return }
        await withCheckedContinuation { waiting.append((count, $0)) }
    }

    func finishNextLoad() {
        let continuation = pending.removeFirst()
        if fails { continuation.resume(throwing: VADFixtureError.unavailable) }
        else { continuation.resume(returning: manager) }
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
