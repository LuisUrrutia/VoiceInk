import AVFoundation
import CoreAudio
import CoreML
import Darwin
import FluidAudio
import IOKit.pwr_mgt
import SwiftData
import XCTest
import os
@testable import VoiceInk

@MainActor
final class IdleModelUnloadTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var clock: FakeIdleClock!
    private var unloadCount = 0
    private var busy = false

    override func setUp() async throws {
        suiteName = "IdleModelUnloadTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        clock = FakeIdleClock()
        unloadCount = 0
        busy = false
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testDisabledByDefaultNeverUnloads() async {
        let coordinator = makeCoordinator(enabled: nil)

        await advance(coordinator, by: .seconds(4 * 3_600))

        XCTAssertFalse(IdleModelUnloadSettings.isEnabled(in: defaults))
        XCTAssertEqual(IdleModelUnloadSettings.minutes(in: defaults), 15)
        XCTAssertFalse(coordinator.isEnabled)
        XCTAssertEqual(unloadCount, 0)
        XCTAssertTrue(clock.pendingDelays.isEmpty)
        XCTAssertTrue(coordinator.allowsPrewarm)
    }

    func testUnloadsOnceAfterConfiguredMinutesWithoutUse() async {
        let coordinator = makeCoordinator(minutes: 15)

        await advance(coordinator, by: .seconds(15 * 60 - 1))
        XCTAssertEqual(unloadCount, 0)
        await advance(coordinator, by: .seconds(1))
        XCTAssertEqual(unloadCount, 1)
        await advance(coordinator, by: .seconds(4 * 3_600))

        XCTAssertEqual(unloadCount, 1)
        XCTAssertTrue(coordinator.hasUnloadedModels)
    }

    func testUseRestartsTheIdlePeriod() async {
        let coordinator = makeCoordinator(minutes: 15)
        await advance(coordinator, by: .seconds(10 * 60))

        coordinator.begin(.use).release()
        await advance(coordinator, by: .seconds(14 * 60))
        XCTAssertEqual(unloadCount, 0)
        await advance(coordinator, by: .seconds(60))

        XCTAssertEqual(unloadCount, 1)
    }

    func testHeldUseBlocksUnloadUntilReleasedAndIdleAgain() async {
        let coordinator = makeCoordinator(minutes: 5)
        let lease = coordinator.begin(.use)

        await advance(coordinator, by: .seconds(3_600))
        XCTAssertEqual(unloadCount, 0)
        lease.release()
        lease.release()
        await advance(coordinator, by: .seconds(5 * 60 - 1))
        XCTAssertEqual(unloadCount, 0)
        await advance(coordinator, by: .seconds(1))

        XCTAssertEqual(unloadCount, 1)
        XCTAssertEqual(coordinator.activeUseCount, 0)
    }

    func testBusyCaptureDefersUnloadAndRechecksUntilIdle() async {
        let coordinator = makeCoordinator(minutes: 5)
        busy = true

        await advance(coordinator, by: .seconds(5 * 60))
        XCTAssertEqual(unloadCount, 0)
        XCTAssertEqual(clock.pendingDelays, [IdleModelUnloadCoordinator.busyRecheckInterval])
        await advance(coordinator, by: .seconds(30))
        XCTAssertEqual(unloadCount, 0)
        busy = false
        await advance(coordinator, by: .seconds(30))

        XCTAssertEqual(unloadCount, 1)
    }

    func testChangingMinutesReschedulesFromTheLastUse() async {
        let coordinator = makeCoordinator(minutes: 15)
        await advance(coordinator, by: .seconds(3 * 60))

        defaults.set(5, forKey: IdleModelUnloadSettings.minutesKey)
        coordinator.reloadSettings()
        await advance(coordinator, by: .seconds(2 * 60 - 1))
        XCTAssertEqual(unloadCount, 0)
        await advance(coordinator, by: .seconds(1))
        XCTAssertEqual(unloadCount, 1)

        coordinator.begin(.use).release()
        defaults.set(60, forKey: IdleModelUnloadSettings.minutesKey)
        coordinator.reloadSettings()
        await advance(coordinator, by: .seconds(59 * 60))
        XCTAssertEqual(unloadCount, 1)
        await advance(coordinator, by: .seconds(60))
        XCTAssertEqual(unloadCount, 2)
    }

    func testDisablingCancelsThePendingUnload() async {
        let coordinator = makeCoordinator(minutes: 15)
        await advance(coordinator, by: .seconds(10 * 60))

        defaults.set(false, forKey: IdleModelUnloadSettings.isEnabledKey)
        coordinator.reloadSettings()
        await advance(coordinator, by: .seconds(4 * 3_600))

        XCTAssertEqual(unloadCount, 0)
        XCTAssertTrue(clock.pendingDelays.isEmpty)
    }

    func testSettingsChangesAreObservedFromUserDefaults() async {
        let coordinator = makeCoordinator(enabled: nil)
        XCTAssertFalse(coordinator.isEnabled)

        defaults.set(true, forKey: IdleModelUnloadSettings.isEnabledKey)
        defaults.set(30, forKey: IdleModelUnloadSettings.minutesKey)
        await waitUntil { coordinator.isEnabled && coordinator.idleInterval == .seconds(30 * 60) }

        XCTAssertTrue(coordinator.isEnabled)
        XCTAssertEqual(coordinator.idleInterval, .seconds(30 * 60))
    }

    func testMaintenanceBlocksUnloadWithoutCountingAsUse() async {
        let coordinator = makeCoordinator(minutes: 15)
        await advance(coordinator, by: .seconds(10 * 60))
        let maintenance = coordinator.begin(.maintenance)

        await advance(coordinator, by: .seconds(10 * 60))
        XCTAssertEqual(unloadCount, 0)
        maintenance.release()
        await advance(coordinator, by: .zero)

        XCTAssertEqual(unloadCount, 1)
    }

    func testUseThatBeginsDuringAnUnloadRunsAfterItFinishes() async {
        let gate = AsyncGate()
        let log = EventLog()
        let coordinator = makeCoordinator(minutes: 5) {
            log.events.append("unload started")
            await gate.wait()
            log.events.append("unload finished")
        }
        clock.advanceWithoutAwaiting(by: .seconds(5 * 60))
        await waitUntil { log.events == ["unload started"] }

        let use = Task { @MainActor in
            await coordinator.perform(.use) { log.events.append("transcribed") }
        }
        await waitUntil { coordinator.activeUseCount == 1 }
        XCTAssertEqual(log.events, ["unload started"])
        gate.open()
        await use.value

        XCTAssertEqual(log.events, ["unload started", "unload finished", "transcribed"])
        XCTAssertFalse(coordinator.hasUnloadedModels)
        XCTAssertEqual(clock.pendingDelays, [.seconds(5 * 60)])
    }

    func testPrewarmIsSkippedOnceTheIdlePeriodHasElapsedUntilTheNextUse() async {
        let coordinator = makeCoordinator(minutes: 15)
        XCTAssertTrue(coordinator.allowsPrewarm)

        clock.now += .seconds(16 * 60)
        XCTAssertFalse(coordinator.allowsPrewarm, "a wake that precedes the timer must not reload")
        await advance(coordinator, by: .zero)
        XCTAssertEqual(unloadCount, 1)
        XCTAssertFalse(coordinator.allowsPrewarm)

        coordinator.begin(.maintenance).release()
        XCTAssertFalse(coordinator.allowsPrewarm, "a prewarm is not a use")
        coordinator.begin(.use).release()
        XCTAssertTrue(coordinator.allowsPrewarm)

        defaults.set(false, forKey: IdleModelUnloadSettings.isEnabledKey)
        coordinator.reloadSettings()
        clock.now += .seconds(4 * 3_600)
        XCTAssertTrue(coordinator.allowsPrewarm)
    }

    func testRegistryTranscriptionCountsAsUseEvenWhenItFails() async throws {
        let coordinator = makeCoordinator(minutes: 15)
        let registry = try makeRegistry(coordinator: coordinator, activity: .use)
        await advance(coordinator, by: .seconds(10 * 60))

        await XCTAssertThrowsAsync(try await registry.transcribe(
            audioURL: URL(fileURLWithPath: "/nonexistent.wav"), model: missingWhisperModel, context: emptyContext
        ))
        await advance(coordinator, by: .seconds(14 * 60))
        XCTAssertEqual(unloadCount, 0)
        await advance(coordinator, by: .seconds(60))

        XCTAssertEqual(unloadCount, 1)
    }

    func testPrewarmRegistryTranscriptionDoesNotCountAsUse() async throws {
        let coordinator = makeCoordinator(minutes: 15)
        let registry = try makeRegistry(coordinator: coordinator, activity: .maintenance)
        await advance(coordinator, by: .seconds(10 * 60))

        await XCTAssertThrowsAsync(try await registry.transcribe(
            audioURL: URL(fileURLWithPath: "/nonexistent.wav"), model: missingWhisperModel, context: emptyContext
        ))
        await advance(coordinator, by: .seconds(5 * 60))

        XCTAssertEqual(unloadCount, 1)
    }

    func testRecordingHoldsModelUseFromCaptureUntilItsSessionEnds() async throws {
        let modes = ModeManager.shared
        let originalModes = modes.configurations
        let originalActiveMode = modes.activeConfiguration
        modes.configurations = [ModeConfig(name: "Idle Unload Fixture", isAIEnhancementEnabled: false)]
        modes.activeConfiguration = nil
        defer {
            modes.configurations = originalModes
            modes.activeConfiguration = originalActiveMode
        }
        let coordinator = makeCoordinator(minutes: 5)
        let hardware = FailingStartHardware()
        let (engine, panel) = try makeEngine(hardware: hardware, coordinator: coordinator)
        await advance(coordinator, by: .seconds(4 * 60))

        let start = Task { await engine.toggleRecord() }
        await fulfillment(of: [hardware.startEntered], timeout: 5)
        XCTAssertEqual(coordinator.activeUseCount, 1)
        XCTAssertTrue(engine.isUsingTranscriptionModels)
        await advance(coordinator, by: .seconds(3_600))
        XCTAssertEqual(unloadCount, 0)
        hardware.releaseStart()
        await start.value

        XCTAssertEqual(coordinator.activeUseCount, 0)
        XCTAssertFalse(engine.isUsingTranscriptionModels)
        await advance(coordinator, by: .seconds(5 * 60))
        XCTAssertEqual(unloadCount, 1)
        withExtendedLifetime(panel) {}
    }

    func testDeliverySessionReleasesItsModelUseOnceItEnds() {
        let coordinator = makeCoordinator(minutes: 5)
        let session = RecordingDeliverySession(destination: .currentApplication, playFeedback: { _ in })

        session.holdModelUse(coordinator.begin(.use))
        XCTAssertEqual(coordinator.activeUseCount, 1)
        session.completePipeline()
        XCTAssertEqual(coordinator.activeUseCount, 0)
        session.holdModelUse(coordinator.begin(.use))

        XCTAssertEqual(coordinator.activeUseCount, 0, "a lease handed to an ended session releases at once")
    }

    func testUnifiedModelReloadsAfterAnIdleUnloadButNotWhileHeld() async throws {
        let cache = UnifiedModelCache { FakeUnifiedModel() }

        let first = try await cache.withModel { $0 }
        let held = try await cache.acquire()
        let unloadedWhileHeld = await cache.unloadIfIdle()
        await cache.release(held)
        let unloaded = await cache.unloadIfIdle()
        let unloadedTwice = await cache.unloadIfIdle()
        let second = try await cache.withModel { $0 }

        XCTAssertFalse(unloadedWhileHeld)
        XCTAssertTrue(unloaded)
        XCTAssertFalse(unloadedTwice)
        XCTAssertTrue(first === held)
        XCTAssertFalse(first === second)
        XCTAssertEqual(first.events, ["load", "reset", "reset", "reset", "reset", "cleanup"])
        XCTAssertEqual(second.events, ["load", "reset", "reset"])
    }

    func testUnifiedModelLoadInFlightIsNotUnloaded() async throws {
        let gate = AsyncGate()
        let cache = UnifiedModelCache { FakeUnifiedModel(loadGate: gate) }
        let load = Task { @MainActor in try await cache.getOrLoad() }
        await waitUntil { gate.isWaiting }
        XCTAssertTrue(gate.isWaiting)

        let unloadedDuringLoad = await cache.unloadIfIdle()
        gate.open()
        let loaded = try await load.value

        XCTAssertFalse(unloadedDuringLoad)
        XCTAssertEqual(loaded.events, ["load"])
    }

    func testSettingsRoundTripThroughConfigurationAndValidateMinutes() throws {
        defaults.set(true, forKey: IdleModelUnloadSettings.isEnabledKey)
        defaults.set(30, forKey: IdleModelUnloadSettings.minutesKey)

        let captured = try ConfigurationPreferences.capture(from: defaults)
        XCTAssertEqual(captured[IdleModelUnloadSettings.isEnabledKey], .bool(true))
        XCTAssertEqual(captured[IdleModelUnloadSettings.minutesKey], .number(30))
        try ConfigurationPreferences.apply(
            [IdleModelUnloadSettings.isEnabledKey: .bool(false), IdleModelUnloadSettings.minutesKey: .number(60)],
            to: defaults
        )
        XCTAssertFalse(IdleModelUnloadSettings.isEnabled(in: defaults))
        XCTAssertEqual(IdleModelUnloadSettings.minutes(in: defaults), 60)

        for minutes in IdleModelUnloadSettings.minuteChoices {
            XCTAssertNoThrow(try ConfigurationPreferences.validate([IdleModelUnloadSettings.minutesKey: .number(Double(minutes))]))
        }
        for invalid: ConfigurationValue in [.number(10), .number(0), .number(15.5), .string("15"), .bool(true)] {
            XCTAssertThrowsError(try ConfigurationPreferences.validate([IdleModelUnloadSettings.minutesKey: invalid]))
        }
        XCTAssertThrowsError(try ConfigurationPreferences.validate([IdleModelUnloadSettings.isEnabledKey: .number(1)]))

        defaults.set(7, forKey: IdleModelUnloadSettings.minutesKey)
        XCTAssertEqual(IdleModelUnloadSettings.minutes(in: defaults), 15, "a hand-edited default falls back")
    }

    func testGeneralBackupRestoresPresentFieldsAndKeepsMissingOnes() throws {
        defaults.set(true, forKey: IdleModelUnloadSettings.isEnabledKey)
        defaults.set(30, forKey: IdleModelUnloadSettings.minutesKey)

        try JSONDecoder().decode(GeneralBackup.self, from: Data("{}".utf8)).restoreIdleModelUnload(in: defaults)
        XCTAssertTrue(IdleModelUnloadSettings.isEnabled(in: defaults))
        XCTAssertEqual(IdleModelUnloadSettings.minutes(in: defaults), 30)

        let backup = try JSONDecoder().decode(
            GeneralBackup.self, from: Data(#"{"unloadsModelWhenIdle":false,"modelIdleUnloadMinutes":5}"#.utf8)
        )
        try JSONDecoder().decode(GeneralBackup.self, from: JSONEncoder().encode(backup)).restoreIdleModelUnload(in: defaults)
        XCTAssertFalse(IdleModelUnloadSettings.isEnabled(in: defaults))
        XCTAssertEqual(IdleModelUnloadSettings.minutes(in: defaults), 5)

        try JSONDecoder().decode(GeneralBackup.self, from: Data(#"{"modelIdleUnloadMinutes":45}"#.utf8))
            .restoreIdleModelUnload(in: defaults)
        XCTAssertEqual(IdleModelUnloadSettings.minutes(in: defaults), 5)
    }

    /// Opt-in measurement, not a pass/fail memory check: `VOICEINK_IDLE_UNLOAD_MEMORY=1` with FluidAudio's
    /// Parakeet v3 installed (and Unified with `VOICEINK_IDLE_UNLOAD_MEMORY_UNIFIED=1`);
    /// `VOICEINK_IDLE_UNLOAD_MEMORY_RESULT=<path>` writes the footprints. The test host app's own launch
    /// prewarm and Core ML's asynchronous compile buffers share this process footprint.
    func testIdleUnloadReleasesInstalledParakeetMemory() async throws {
        guard ProcessInfo.processInfo.environment["VOICEINK_IDLE_UNLOAD_MEMORY"] == "1" else {
            throw XCTSkip("Set VOICEINK_IDLE_UNLOAD_MEMORY=1 to measure memory released by an idle unload")
        }
        let service = FluidAudioTranscriptionService()
        let v3 = FluidAudioModel(
            name: "parakeet-tdt-0.6b-v3", displayName: "Parakeet V3", description: "Measurement", size: "",
            speed: 1, accuracy: 1, ramUsage: 1, supportedLanguages: ["en": "English"]
        )
        let includesUnified = ProcessInfo.processInfo.environment["VOICEINK_IDLE_UNLOAD_MEMORY_UNIFIED"] == "1"
        let baseline = try await settledFootprints()

        try await service.loadModel(for: v3)
        if includesUnified { try await service.prewarmUnifiedModel(isRealtime: false) }
        // Pipeline cleanup releases managers but keeps the cached models resident between dictations.
        await service.cleanup()
        let resident = try await settledFootprints()
        await service.unloadIdleModels()
        let unloaded = try await settledFootprints()
        try await service.loadModel(for: v3)
        let reloaded = try await settledFootprints()

        let report = "unified=\(includesUnified) baseline=\(baseline) resident=\(resident) unloaded=\(unloaded) reloaded=\(reloaded) MB, sampled each second for 10 s"
        if let path = ProcessInfo.processInfo.environment["VOICEINK_IDLE_UNLOAD_MEMORY_RESULT"] {
            try Data((report + "\n").utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }


    // MARK: - Production unload and reuse boundaries

    func testFluidAudioIdleUnloadReleasesModelsThatPipelineCleanupKeeps() async throws {
        let probe = ModelRuntimeProbe()
        let service = probe.makeService()
        _ = try await service.getOrLoadModels(for: .v3)
        try await service.prewarmUnifiedModel(isRealtime: false)
        try await service.prewarmUnifiedModel(isRealtime: true)

        await service.cleanup()
        XCTAssertNotNil(probe.asrModel, "pipeline cleanup keeps the cached Parakeet models")
        XCTAssertNotNil(probe.batchManager)
        XCTAssertNotNil(probe.streamingManager)
        await service.unloadIdleModels()
        XCTAssertNil(probe.asrModel)
        XCTAssertNil(probe.batchManager)
        XCTAssertNil(probe.streamingManager)
        _ = try await service.getOrLoadModels(for: .v3)
        try await service.prewarmUnifiedModel(isRealtime: false)

        XCTAssertEqual(probe.log.events, ["load asr", "load batch", "load streaming", "load asr", "load batch"])
    }

    func testFluidAudioIdleUnloadReleasesTheParakeetManagerThatPrewarmLeavesLoaded() async throws {
        let probe = ModelRuntimeProbe()
        let service = probe.makeService()
        let v3 = FluidAudioModel(
            name: "parakeet-tdt-0.6b-v3", displayName: "Parakeet V3", description: "Fixture", size: "",
            speed: 1, accuracy: 1, ramUsage: 1, supportedLanguages: ["en": "English"]
        )
        try await service.loadModel(for: v3)
        try await service.loadModel(for: v3)
        XCTAssertNotNil(probe.asrModel)

        await service.unloadIdleModels()
        XCTAssertNil(probe.asrModel, "the loaded AsrManager must not keep the models alive")
        try await service.loadModel(for: v3)

        XCTAssertNotNil(probe.asrModel)
        XCTAssertEqual(probe.log.events, ["load asr", "load asr"])
    }

    func testAppDispatchUnloadsEngineAndPrewarmModelsOnceTheEngineIsIdle() async throws {
        let coordinator = makeProductionCoordinator(minutes: 15)
        let engineProbe = ModelRuntimeProbe()
        let prewarmProbe = ModelRuntimeProbe()
        let (engine, panel) = try makeEngine(
            hardware: FailingStartHardware(), coordinator: coordinator, fluidAudioService: engineProbe.makeService()
        )
        let unusedProbe = ModelRuntimeProbe()
        let prewarm = try makePrewarmService(
            coordinator: coordinator, fluidAudioService: unusedProbe.makeService(),
            registryFluidAudioService: prewarmProbe.makeService(), configuration: nil
        )
        coordinator.configure(engine: engine, prewarmService: prewarm)
        _ = try await engine.serviceRegistry.fluidAudioTranscriptionService.getOrLoadModels(for: .v3)
        _ = try await prewarmProbe.lastService?.getOrLoadModels(for: .v3)
        XCTAssertNotNil(engineProbe.asrModel)
        XCTAssertNotNil(prewarmProbe.asrModel)

        engine.recordingState = .recording
        await advance(coordinator, by: .seconds(15 * 60))
        XCTAssertNotNil(engineProbe.asrModel, "a recording without a lease still counts as busy")
        engine.recordingState = .idle
        await advance(coordinator, by: IdleModelUnloadCoordinator.busyRecheckInterval)

        XCTAssertNil(engineProbe.asrModel)
        XCTAssertNil(prewarmProbe.asrModel)
        withExtendedLifetime((panel, prewarm)) {}
    }

    func testPrewarmIsSkippedAfterAnIdleUnloadUntilTheNextUse() async throws {
        let coordinator = makeProductionCoordinator(minutes: 15)
        let probe = ModelRuntimeProbe()
        let service = probe.makeService()
        coordinator.configure(isBusy: { false }, unload: { await service.unloadIdleModels() })
        let prewarm = try makePrewarmService(
            coordinator: coordinator, fluidAudioService: service, registryFluidAudioService: nil,
            configuration: unifiedConfiguration(realtime: false)
        )

        await prewarm.prewarm()
        XCTAssertNotNil(probe.batchManager)
        await advance(coordinator, by: .seconds(15 * 60))
        XCTAssertNil(probe.batchManager)
        await prewarm.prewarm()
        XCTAssertEqual(probe.log.events, ["load batch"], "wake prewarm must not reload an idle-unloaded model")
        XCTAssertNil(probe.batchManager)
        coordinator.begin(.use).release()
        await prewarm.prewarm()

        XCTAssertEqual(probe.log.events, ["load batch", "load batch"])
        XCTAssertNotNil(probe.batchManager)
    }

    func testBatchPreparationWaitsForAnUnloadInProgressThenTranscribesTheWholeRecording() async throws {
        let probe = ModelRuntimeProbe()
        let service = probe.makeService()
        let coordinator = makeProductionCoordinator(minutes: 15)
        let registry = try makeRegistry(coordinator: coordinator, activity: .use, fluidAudioService: service)
        let gate = AsyncGate()
        coordinator.configure(isBusy: { false }, unload: {
            probe.log.events.append("unload started")
            await gate.wait()
            await registry.unloadIdleModels()
            probe.log.events.append("unload finished")
        })
        let configuration = unifiedConfiguration(realtime: false)
        let recordingID = UUID()
        try await registry.prepareForRecording(configuration, recordingID: recordingID, whisperModelManager: whisper)
        let firstManager = try XCTUnwrap(probe.batchManager)
        clock.advanceWithoutAwaiting(by: .seconds(15 * 60))
        await waitUntil { probe.log.events.last == "unload started" }

        let recording = coordinator.begin(.use)
        let preparation = Task { @MainActor in
            try await registry.prepareForRecording(configuration, recordingID: recordingID, whisperModelManager: self.whisper)
            probe.log.events.append("prepared")
        }
        await waitUntil(timeout: .milliseconds(500)) { probe.log.events.last == "prepared" }
        XCTAssertEqual(probe.log.events.last, "unload started", "preparation must wait for the unload in progress")
        gate.open()
        try await preparation.value
        let audio = try writeRecording(frames: 16_000)
        let text = try await registry.transcribe(audioURL: audio, model: configuration.model, context: emptyContext)
        recording.release()

        XCTAssertEqual(probe.log.events, ["load batch", "unload started", "unload finished", "load batch", "prepared", "transcribe 16000"])
        XCTAssertEqual(text, "samples:16000")
        XCTAssertFalse(probe.batchManager === firstManager)
        withExtendedLifetime(firstManager) {}
    }

    func testRealtimeSessionWaitsForAnUnloadInProgressAndFallsBackWithTheWholeRecording() async throws {
        let probe = ModelRuntimeProbe()
        let service = probe.makeService()
        let coordinator = makeProductionCoordinator(minutes: 15)
        let registry = try makeRegistry(coordinator: coordinator, activity: .use, fluidAudioService: service)
        let gate = AsyncGate()
        coordinator.configure(isBusy: { false }, unload: {
            probe.log.events.append("unload started")
            await gate.wait()
            await registry.unloadIdleModels()
            probe.log.events.append("unload finished")
        })
        let configuration = unifiedConfiguration(realtime: true)
        try await service.prewarmUnifiedModel(isRealtime: true)
        let firstManager = WeakReference(probe.streamingManager)
        clock.advanceWithoutAwaiting(by: .seconds(15 * 60))
        await waitUntil { probe.log.events.last == "unload started" }

        let recording = coordinator.begin(.use)
        let setup = Task { @MainActor () -> TranscriptionSession? in
            let session = await registry.makeRealtimeSession(for: configuration)
            probe.log.events.append("session created")
            return session
        }
        await waitUntil(timeout: .milliseconds(500)) { probe.log.events.last == "session created" }
        XCTAssertEqual(probe.log.events.last, "unload started", "session setup must wait for the unload in progress")
        gate.open()
        let createdSession = await setup.value
        let session = try XCTUnwrap(createdSession)
        let prepared = try await session.prepare(configuration: configuration, vocabulary: RecordingVocabulary())
        let callback = try XCTUnwrap(prepared)
        let samples = Self.tone(frames: 16_000)
        for start in stride(from: 0, to: samples.count, by: 1_600) {
            callback(Self.pcm16(samples[start..<min(start + 1_600, samples.count)]))
        }
        let audio = try writeRecording(frames: 16_000)
        let text = try await session.transcribe(audioURL: audio, vocabulary: RecordingVocabulary())
        await session.finishPreparation()
        recording.release()

        XCTAssertNil(firstManager.value, "the unload released the streaming model the session would have reused")
        XCTAssertEqual(
            probe.log.events,
            ["load streaming", "unload started", "unload finished", "session created", "load streaming", "load batch", "transcribe 16000"]
        )
        XCTAssertEqual(text, "samples:16000", "batch fallback transcribes the complete recording")
    }

    // MARK: - Helpers

    private var whisper: WhisperModelManager { WhisperModelManager(modelsDirectory: URL(fileURLWithPath: "/unused-models")) }

    /// A coordinator on the fake clock whose unload targets each test configures itself.
    private func makeProductionCoordinator(minutes: Int) -> IdleModelUnloadCoordinator {
        defaults.set(true, forKey: IdleModelUnloadSettings.isEnabledKey)
        defaults.set(minutes, forKey: IdleModelUnloadSettings.minutesKey)
        let clock = clock!
        return IdleModelUnloadCoordinator(defaults: defaults, now: { clock.now }, schedule: clock.schedule)
    }

    private func makePrewarmService(
        coordinator: IdleModelUnloadCoordinator, fluidAudioService: FluidAudioTranscriptionService,
        registryFluidAudioService: FluidAudioTranscriptionService?, configuration: TranscriptionRuntimeConfiguration?
    ) throws -> ModelPrewarmService {
        defaults.set(true, forKey: "PrewarmModelOnWake")
        let container = try ModelContainer(
            for: Transcription.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let whisper = self.whisper
        return ModelPrewarmService(
            transcriptionModelManager: TranscriptionModelManager(
                whisperModelManager: whisper, fluidAudioModelManager: FluidAudioModelManager()
            ),
            whisperModelManager: whisper, modelContext: ModelContext(container), fluidAudioService: fluidAudioService,
            idleUnload: coordinator, defaults: defaults, registryFluidAudioService: registryFluidAudioService,
            resolveConfiguration: { configuration }, schedulesPrewarm: false
        )
    }

    private func unifiedConfiguration(realtime: Bool) -> TranscriptionRuntimeConfiguration {
        TranscriptionRuntimeConfiguration(
            mode: ModeConfig(name: "Idle unload fixture", isAIEnhancementEnabled: false),
            model: FluidAudioModel(
                name: "parakeet-unified-0.6b", displayName: "Parakeet Unified", description: "Fixture", size: "",
                speed: 1, accuracy: 1, ramUsage: 1, supportedLanguages: ["en": "English"]
            ), languages: ["en"], isRealtimeEnabled: realtime
        )
    }

    private static func tone(frames: Int) -> [Int16] {
        (0..<frames).map { Int16(8_000 * sin(Double($0) * 2 * .pi * 440 / 16_000)) }
    }

    private static func pcm16(_ samples: ArraySlice<Int16>) -> Data {
        samples.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    private func writeRecording(frames: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).wav")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true))
        let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatInt16, interleaved: true)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
        buffer.frameLength = AVAudioFrameCount(frames)
        let samples = Self.tone(frames: frames)
        buffer.int16ChannelData?[0].update(from: samples, count: frames)
        try file.write(from: buffer)
        return url
    }

    private func makeCoordinator(
        enabled: Bool? = true, minutes: Int? = nil, unload: (@MainActor () async -> Void)? = nil
    ) -> IdleModelUnloadCoordinator {
        if let enabled { defaults.set(enabled, forKey: IdleModelUnloadSettings.isEnabledKey) }
        if let minutes { defaults.set(minutes, forKey: IdleModelUnloadSettings.minutesKey) }
        let clock = clock!
        let coordinator = IdleModelUnloadCoordinator(
            defaults: defaults, now: { clock.now }, schedule: clock.schedule
        )
        coordinator.configure(
            isBusy: { [unowned self] in self.busy },
            unload: { [unowned self] in
                self.unloadCount += 1
                await unload?()
            }
        )
        return coordinator
    }

    private func advance(_ coordinator: IdleModelUnloadCoordinator, by duration: Duration) async {
        clock.advanceWithoutAwaiting(by: duration)
        await coordinator.waitForPendingUnload()
    }

    private func waitUntil(timeout: Duration = .seconds(5), _ condition: @MainActor () -> Bool) async {
        let deadline = ContinuousClock.now + timeout
        while !condition(), ContinuousClock.now < deadline { await Task.yield() }
    }

    private var missingWhisperModel: ImportedWhisperModel { ImportedWhisperModel(fileBaseName: "missing-idle-unload") }

    private var emptyContext: TranscriptionRequestContext {
        TranscriptionRequestContext(languages: ["en"]).withVocabulary(RecordingVocabulary())
    }

    private func makeRegistry(
        coordinator: IdleModelUnloadCoordinator, activity: IdleModelUnloadCoordinator.Activity,
        fluidAudioService: FluidAudioTranscriptionService? = nil
    ) throws -> TranscriptionServiceRegistry {
        let container = try ModelContainer(
            for: Transcription.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let whisper = WhisperModelManager(modelsDirectory: URL(fileURLWithPath: "/unused-models"))
        return TranscriptionServiceRegistry(
            modelProvider: whisper, modelsDirectory: whisper.modelsDirectory, modelContext: ModelContext(container),
            fluidAudioService: fluidAudioService, idleUnload: coordinator, activity: activity
        )
    }

    private func makeEngine(
        hardware: FailingStartHardware, coordinator: IdleModelUnloadCoordinator,
        fluidAudioService: FluidAudioTranscriptionService? = nil
    ) throws -> (VoiceInkEngine, IdleUnloadRecorderPanel) {
        let devices = IdleUnloadAudioDevices(userDefaults: try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString)))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let whisper = WhisperModelManager(modelsDirectory: directory)
        let models = TranscriptionModelManager(whisperModelManager: whisper, fluidAudioModelManager: FluidAudioModelManager())
        let readiness = CaptureReadinessController(models: models, devices: devices, permissionReader: { (.granted, false) })
        let container = try ModelContainer(
            for: Transcription.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let prevention = IdleSleepPrevention(client: NoPowerAssertions(), queue: DispatchQueue(label: UUID().uuidString))
        let engine = VoiceInkEngine(
            modelContext: ModelContext(container), whisperModelManager: whisper,
            transcriptionModelManager: models, recorder: Recorder(hardware: hardware, deviceManager: devices),
            captureReadiness: readiness, idleSleepPrevention: prevention, idleModelUnload: coordinator,
            fluidAudioService: fluidAudioService
        )
        let panel = IdleUnloadRecorderPanel()
        engine.recorderUIManager = panel
        return (engine, panel)
    }

    /// Core ML releases and maps memory asynchronously, so one sample is not representative.
    private func settledFootprints() async throws -> [UInt64] {
        var samples: [UInt64] = []
        for _ in 0..<10 {
            try await Task.sleep(for: .seconds(1))
            samples.append(try physicalFootprint() / 1_048_576)
        }
        return samples
    }

    private func physicalFootprint() throws -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { throw XCTSkip("task_info failed: \(result)") }
        return info.phys_footprint
    }
}

private func XCTAssertThrowsAsync<T>(
    _ expression: @autoclosure () async throws -> T, file: StaticString = #filePath, line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected an error", file: file, line: line)
    } catch {}
}

@MainActor
private final class FakeIdleClock {
    private final class Timer: IdleModelUnloadTimer {
        let deadline: ContinuousClock.Instant
        let delay: Duration
        let action: @MainActor () -> Void
        var isCancelled = false

        init(deadline: ContinuousClock.Instant, delay: Duration, action: @escaping @MainActor () -> Void) {
            self.deadline = deadline
            self.delay = delay
            self.action = action
        }

        func cancel() { isCancelled = true }
    }

    var now = ContinuousClock.now
    private var timers: [Timer] = []

    var pendingDelays: [Duration] { timers.filter { !$0.isCancelled }.map(\.delay) }

    func schedule(_ delay: Duration, _ action: @escaping @MainActor () -> Void) -> any IdleModelUnloadTimer {
        let timer = Timer(deadline: now + delay, delay: delay, action: action)
        timers.append(timer)
        return timer
    }

    /// Fires due timers in deadline order, including timers they schedule within the window.
    func advanceWithoutAwaiting(by duration: Duration) {
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

private final class FakeMLModel: MLModel {}

private final class WeakReference<Value: AnyObject> {
    weak var value: Value?
    init(_ value: Value?) { self.value = value }
}

/// Replaces FluidAudio's model file access, recording loads and keeping only weak references to loaded models.
@MainActor
private final class ModelRuntimeProbe {
    let log = EventLog()
    weak var asrModel: MLModel?
    weak var batchManager: UnifiedAsrManager?
    weak var streamingManager: StreamingUnifiedAsrManager?
    private(set) weak var lastService: FluidAudioTranscriptionService?

    func makeService() -> FluidAudioTranscriptionService {
        let runtime = FluidAudioTranscriptionService.ModelRuntime(
            loadAsrModels: { version in
                let preprocessor = FakeMLModel()
                await MainActor.run {
                    self.asrModel = preprocessor
                    self.log.events.append("load asr")
                }
                return AsrModels(
                    encoder: FakeMLModel(), preprocessor: preprocessor, decoder: FakeMLModel(), joint: FakeMLModel(),
                    configuration: MLModelConfiguration(), vocabulary: [:], version: version
                )
            },
            loadUnifiedModel: { model in
                if let batch = model as? UnifiedAsrManager {
                    self.batchManager = batch
                    self.log.events.append("load batch")
                } else if let streaming = model as? StreamingUnifiedAsrManager {
                    self.streamingManager = streaming
                    self.log.events.append("load streaming")
                }
            },
            transcribeUnified: { _, samples in
                await MainActor.run { self.log.events.append("transcribe \(samples.count)") }
                return "samples:\(samples.count)"
            }
        )
        let service = FluidAudioTranscriptionService(vadCache: FluidAudioVADCache(isEnabled: { false }), runtime: runtime)
        lastService = service
        return service
    }
}

@MainActor
private final class EventLog {
    var events: [String] = []
}

@MainActor
private final class AsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    var isWaiting: Bool { !waiters.isEmpty }

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

private final class FakeUnifiedModel: UnifiedModel, @unchecked Sendable {
    private let state = OSAllocatedUnfairLock(initialState: [String]())
    private let loadGate: AsyncGate?

    init(loadGate: AsyncGate? = nil) {
        self.loadGate = loadGate
    }

    var events: [String] { state.withLock { $0 } }

    func loadModels(from directory: URL) async throws {
        if let loadGate { await loadGate.wait() }
        state.withLock { $0.append("load") }
    }

    func reset() async throws { state.withLock { $0.append("reset") } }
    func cleanup() async { state.withLock { $0.append("cleanup") } }
}

@MainActor
private final class IdleUnloadRecorderPanel: RecorderPanelPresenting {
    var isRecorderPanelVisible = true
    func dismissRecorderPanel() async {}
}

private final class NoPowerAssertions: PowerAssertionClient, @unchecked Sendable {
    func createIdleSleepAssertion(named name: String) -> Result<IOPMAssertionID, IdleSleepPreventionError> {
        .success(1)
    }
    func releaseAssertion(_ id: IOPMAssertionID) -> IOReturn { kIOReturnSuccess }
}

private final class IdleUnloadAudioDevices: AudioDeviceManager {
    override func startMonitoring() {}
    override func loadAvailableDevices(completion: (() -> Void)? = nil) {
        availableDevices = [(id: 93, uid: "idle-unload-mic", name: "Idle unload microphone")]
        completion?()
    }
    override func getSystemDefaultDevice() -> AudioDeviceID? { 93 }
    override func getDeviceModelUID(deviceID: AudioDeviceID) -> String? { nil }
    override func isInternalMicrophone(_ deviceID: AudioDeviceID) -> Bool { false }
}

/// Holds its start until released, then fails it, so the recording's session ends without a pipeline.
private final class FailingStartHardware: RecordingHardware, @unchecked Sendable {
    private let gate = DispatchSemaphore(value: 0)
    private let callback = OSAllocatedUnfairLock<((Data) -> Void)?>(initialState: nil)
    let startEntered = XCTestExpectation(description: "hardware start entered")
    let averagePower: Float = -60
    let peakPower: Float = -60
    let recordingError: Error? = nil

    var onAudioChunk: ((Data) -> Void)? {
        get { callback.withLock { $0 } }
        set { callback.withLock { $0 = newValue } }
    }

    func releaseStart() { gate.signal() }

    func startRecording(toOutputFile url: URL, deviceID: AudioDeviceID, selectedInputChannels: [UInt32]?) throws {
        startEntered.fulfill()
        _ = gate.wait(timeout: .now() + 10)
        throw Recorder.RecorderError.couldNotStartRecording
    }

    func stopRecording() {}
    func prepare(deviceID: AudioDeviceID, selectedInputChannels: [UInt32]?) throws {}
    func switchDevice(to deviceID: AudioDeviceID, selectedInputChannels: [UInt32]?) throws {}
    func invalidatePreparation() {}
    func teardown() {}
}
