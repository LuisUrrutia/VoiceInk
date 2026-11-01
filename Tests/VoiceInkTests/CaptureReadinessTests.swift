import XCTest
import AppKit
import Combine
import CoreAudio
import SwiftData
import os
@testable import VoiceInk

@MainActor
final class CaptureReadinessTests: XCTestCase {
    func testMicrophonePermissionMatrix() {
        for permission in [CapturePermission.notDetermined, .denied, .restricted, .granted] {
            let readiness = snapshot(permission: permission)

            for operation in [CaptureReadiness.Operation.microphoneTest, .onScreenDictation] {
                let issues = readiness.issues(for: operation)

                XCTAssertEqual(issues, permission == .granted ? [] : [.microphonePermission(permission)])
            }
        }
    }

    func testMissingMicrophoneBlocksCaptureWithOtherwiseCompleteSetup() {
        var readiness = snapshot()
        readiness.hasMicrophone = false

        XCTAssertEqual(readiness.issues(for: .microphoneTest), [.microphoneUnavailable])
        XCTAssertEqual(readiness.issues(for: .onScreenDictation), [.microphoneUnavailable])
    }

    func testEveryModelSetupFailureLeavesMicrophoneTestAvailable() {
        for state in [CaptureModelReadiness.noMode, .noSelection, .notInstalled, .unavailable,
                      .providerMissing, .checking, .invalidCustomModel] {
            var readiness = snapshot()
            readiness.model = state

            XCTAssertEqual(readiness.issues(for: .onScreenDictation), [.model(state)])
            XCTAssertTrue(readiness.issues(for: .microphoneTest).isEmpty)
        }
    }

    func testHotkeyAndAccessibilityNeverBlockOnScreenCapture() {
        var readiness = snapshot()
        readiness.accessibilityGranted = false

        for hotkey in [RecordingHotkeyAvailability.unconfigured, .unavailable, .needsAccessibility, .available] {
            XCTAssertTrue(readiness.issues(for: .onScreenDictation, hotkey: hotkey).isEmpty)
            XCTAssertEqual(
                readiness.issues(for: .shortcutDictation, hotkey: hotkey),
                hotkey == .available ? [] : [.hotkey(hotkey)]
            )
        }
        XCTAssertTrue(readiness.issues(for: .microphoneTest).isEmpty)
        XCTAssertEqual(readiness.issues(for: .paste), [.accessibility])
        readiness.usesPaste = false
        XCTAssertTrue(readiness.issues(for: .paste).isEmpty)
    }

    func testLocalModelsUseInstallationSnapshotWithoutProviderKeys() throws {
        for provider in [ModelProvider.whisper, .fluidAudio, .transcribeCpp] {
            let model = try XCTUnwrap(TranscriptionModelRegistry.models.first { $0.provider == provider })

            XCTAssertEqual(evaluate(model, installed: [model.name]), .ready)
            XCTAssertEqual(evaluate(model, installed: []), .notInstalled)
            XCTAssertEqual(evaluate(model, installed: nil), .checking)
        }
        let apple = try XCTUnwrap(TranscriptionModelRegistry.models.first { $0.provider == .nativeApple })
        XCTAssertEqual(evaluate(apple, installed: [], supported: true), .ready)
        XCTAssertEqual(evaluate(apple, installed: [], supported: false), .unavailable)
    }

    func testCloudProviderMissingPresentAndPendingConfiguration() throws {
        let model = try XCTUnwrap(TranscriptionModelRegistry.models.first { $0.provider == .groq })
        let key = try XCTUnwrap(CloudProviderRegistry.provider(for: model.provider)?.providerKey.lowercased())

        XCTAssertEqual(evaluate(model, keys: nil), .checking)
        XCTAssertEqual(evaluate(model, keys: []), .providerMissing)
        XCTAssertEqual(evaluate(model, keys: [key]), .ready)
        XCTAssertEqual(evaluate(model, keys: ["unrelated-provider"]), .providerMissing)
    }

    func testCustomProviderChecksEndpointModelAndItsOwnConfiguration() {
        let model = CustomCloudModel(
            name: "fixture", displayName: "Fixture", description: "", apiEndpoint: "https://example.test/transcribe",
            modelName: "speech"
        )
        let invalid = CustomCloudModel(
            name: "invalid", displayName: "Invalid", description: "", apiEndpoint: "file:///tmp/audio",
            modelName: ""
        )

        XCTAssertEqual(evaluate(model, customIDs: nil), .checking)
        XCTAssertEqual(evaluate(model, customIDs: []), .providerMissing)
        XCTAssertEqual(evaluate(model, customIDs: [UUID()]), .providerMissing)
        XCTAssertEqual(evaluate(model, customIDs: [model.id]), .ready)
        XCTAssertEqual(evaluate(invalid, customIDs: [invalid.id]), .invalidCustomModel)
    }

    func testFeedbackNeverInfersCaptureFromReadinessOrAudioLevels() {
        XCTAssertEqual(CaptureFeedback.resolve(state: .idle, hasSetupIssues: false, hasError: false), .idle)
        XCTAssertEqual(CaptureFeedback.resolve(state: .idle, hasSetupIssues: true, hasError: false), .setupBlocked)
        XCTAssertEqual(CaptureFeedback.resolve(state: .idle, hasSetupIssues: false, hasError: true), .error)
        XCTAssertEqual(CaptureFeedback.resolve(state: .starting, hasSetupIssues: false, hasError: false), .starting)
        XCTAssertEqual(CaptureFeedback.resolve(state: .recording, hasSetupIssues: true, hasError: false), .recording)
        for state in [RecordingState.transcribing, .enhancing, .busy] {
            XCTAssertEqual(CaptureFeedback.resolve(state: state, hasSetupIssues: false, hasError: false), .transcribing)
        }
    }

    func testActivationRefreshesPermissionsAndNotifiesRecorderPresentation() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let directory = root.appendingPathComponent(".tmp/capture-readiness-tests/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "ReadinessActivationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let devices = ReadinessAudioDevices(userDefaults: defaults, notificationCenter: NotificationCenter())
        let whisper = WhisperModelManager(modelsDirectory: directory)
        let models = TranscriptionModelManager(whisperModelManager: whisper, fluidAudioModelManager: FluidAudioModelManager())
        var permissions: (microphone: CapturePermission, accessibility: Bool) = (.granted, false)
        let readiness = CaptureReadinessController(models: models, devices: devices, permissionReader: { permissions })
        let container = try ModelContainer(
            for: Transcription.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let engine = VoiceInkEngine(
            modelContext: ModelContext(container), whisperModelManager: whisper,
            transcriptionModelManager: models,
            recorder: Recorder(hardware: ReadinessAudioHardware(), deviceManager: devices), captureReadiness: readiness
        )
        var presentationChanges = 0
        let presentation = engine.objectWillChange.sink { presentationChanges += 1 }
        defer { presentation.cancel() }
        let refreshed = expectation(description: "permissions refreshed on activation")
        let subscription = readiness.$snapshot.dropFirst().prefix(1).sink { snapshot in
            XCTAssertEqual(snapshot.microphonePermission, .denied)
            XCTAssertTrue(snapshot.accessibilityGranted)
            refreshed.fulfill()
        }
        defer { subscription.cancel() }

        permissions = (.denied, true)
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        await fulfillment(of: [refreshed], timeout: 3)

        XCTAssertGreaterThan(presentationChanges, 0)
        XCTAssertEqual(readiness.snapshot.issues(for: .microphoneTest), [.microphonePermission(.denied)])
        XCTAssertEqual(engine.recordingState, .idle)
    }

    func testSlowDeviceQueryLeavesTheMainActorResponsive() async throws {
        let devices = SlowQueryAudioDevices()
        devices.lidClosed = true
        devices.hold()
        defer { devices.release() }
        let readiness = makeReadiness(devices: devices)

        await fulfillment(of: [devices.queryEntered], timeout: 3)
        let mainActorTurn = expectation(description: "main actor ran while the device query was held")
        Task { @MainActor in mainActorTurn.fulfill() }
        await fulfillment(of: [mainActorTurn], timeout: 1)

        XCTAssertFalse(devices.queriedOnMainThread)
        XCTAssertTrue(readiness.snapshot.hasMicrophone, "the previous resolution stands until the query returns")
        let published = expectation(description: "closed-lid resolution published")
        let subscription = readiness.$snapshot.first { !$0.hasMicrophone }.sink { _ in published.fulfill() }
        defer { subscription.cancel() }
        devices.release()
        await fulfillment(of: [published], timeout: 3)
        XCTAssertEqual(readiness.snapshot.issues(for: .microphoneTest), [.microphoneUnavailable])
    }

    func testDeviceChangeBurstCoalescesIntoOneFurtherPass() async throws {
        let devices = SlowQueryAudioDevices()
        defer { devices.release() }
        let models = makeModels()
        let readiness = CaptureReadinessController(models: models, devices: devices, permissionReader: { (.granted, true) })
        // Model scans finishing later would request passes of their own.
        let deadline = ContinuousClock.now + .seconds(3)
        while !models.hasLoadedInstallationSnapshot || models.configuredCloudProviderKeys == nil {
            guard ContinuousClock.now < deadline else { return XCTFail("Model state did not load") }
            try await Task.sleep(for: .milliseconds(1))
        }
        _ = await readiness.refreshedSnapshot()
        devices.hold()
        let queriesBefore = devices.queryCount
        readiness.refreshSnapshot()
        await fulfillment(of: [devices.queryEntered], timeout: 3)

        for _ in 0..<20 {
            NotificationCenter.default.post(name: Notification.Name("AudioDeviceChanged"), object: nil)
            devices.objectWillChange.send()
            readiness.refreshSnapshot()
        }
        await drainMainActor()
        devices.release()
        _ = await readiness.refreshedSnapshot()

        XCTAssertEqual(devices.queryCount - queriesBefore, 2)
    }

    func testControllerReleasesItsObserversWithItsOwnerDuringAQuery() async throws {
        let devices = SlowQueryAudioDevices()
        devices.hold()
        defer { devices.release() }
        weak var released: CaptureReadinessController?
        do {
            let readiness = makeReadiness(devices: devices)
            released = readiness
            await fulfillment(of: [devices.queryEntered], timeout: 3)
        }

        XCTAssertNil(released)
        devices.release()
        await drainMainActor()
        let queriesAfterRelease = devices.queryCount
        NotificationCenter.default.post(name: Notification.Name("AudioDeviceChanged"), object: nil)
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        devices.objectWillChange.send()
        await drainMainActor()
        XCTAssertEqual(devices.queryCount, queriesAfterRelease)
    }

    private func makeReadiness(devices: AudioDeviceManager) -> CaptureReadinessController {
        CaptureReadinessController(models: makeModels(), devices: devices, permissionReader: { (.granted, true) })
    }

    private func makeModels() -> TranscriptionModelManager {
        let whisper = WhisperModelManager(
            modelsDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        )
        return TranscriptionModelManager(whisperModelManager: whisper, fluidAudioModelManager: FluidAudioModelManager())
    }

    /// Lets notification deliveries and the tasks they schedule on the main actor run.
    private func drainMainActor() async {
        for _ in 0..<20 { await Task.yield() }
    }

    private func snapshot(permission: CapturePermission = .granted) -> CaptureReadiness {
        CaptureReadiness(
            microphonePermission: permission, hasMicrophone: true, accessibilityGranted: true,
            model: .ready, usesPaste: true
        )
    }

    private func evaluate(
        _ model: any TranscriptionModel, installed: Set<String>? = [], keys: Set<String>? = [],
        customIDs: Set<UUID>? = [], supported: Bool = true
    ) -> CaptureModelReadiness {
        CaptureModelReadiness.evaluate(
            model: model, supportedOnOS: supported, installedNames: installed,
            configuredProviderKeys: keys, configuredCustomModelIDs: customIDs
        )
    }
}

private final class ReadinessAudioDevices: AudioDeviceManager {
    override func startMonitoring() {}
    override func loadAvailableDevices(completion: (() -> Void)? = nil) {
        availableDevices = [(id: 91, uid: "readiness-mic", name: "Readiness microphone")]
        completion?()
    }
    override func getSystemDefaultDevice() -> AudioDeviceID? { 91 }
    override func getDeviceModelUID(deviceID: AudioDeviceID) -> String? { nil }
    override func isInternalMicrophone(_ deviceID: AudioDeviceID) -> Bool { false }
    override func inputTransport(_ deviceID: AudioDeviceID) -> AudioInputTransport { .other }
}

/// An internal microphone whose default-input query can be held, standing in for a stalled coreaudiod.
private final class SlowQueryAudioDevices: AudioDeviceManager {
    private struct State {
        var isHeld = false
        var queryCount = 0
        var queriedOnMainThread = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let gate = DispatchSemaphore(value: 0)
    let queryEntered: XCTestExpectation = {
        let expectation = XCTestExpectation(description: "held device query entered")
        expectation.assertForOverFulfill = false
        return expectation
    }()
    var lidClosed = false

    var queryCount: Int { state.withLock { $0.queryCount } }
    var queriedOnMainThread: Bool { state.withLock { $0.queriedOnMainThread } }

    init() {
        super.init(userDefaults: UserDefaults(suiteName: "SlowQueryAudioDevices")!, notificationCenter: NotificationCenter())
    }

    override var isClamshellClosed: Bool { lidClosed }
    override func startMonitoring() {}
    override func loadAvailableDevices(completion: (() -> Void)? = nil) {
        availableDevices = [(id: 91, uid: "slow-mic", name: "Slow microphone")]
        completion?()
    }
    override func getSystemDefaultDevice() -> AudioDeviceID? {
        let isHeld = state.withLock { state in
            state.queryCount += 1
            if state.isHeld && Thread.isMainThread { state.queriedOnMainThread = true }
            return state.isHeld
        }
        if isHeld {
            queryEntered.fulfill()
            // Bounded so that a query on the main thread fails the test instead of hanging it.
            _ = gate.wait(timeout: .now() + 2)
        }
        return 91
    }
    override func getDeviceModelUID(deviceID: AudioDeviceID) -> String? { nil }
    override func isInternalMicrophone(_ deviceID: AudioDeviceID) -> Bool { true }
    override func inputTransport(_ deviceID: AudioDeviceID) -> AudioInputTransport { .builtIn }

    func hold() { state.withLock { $0.isHeld = true } }

    func release() {
        let wasHeld = state.withLock { state in
            defer { state.isHeld = false }
            return state.isHeld
        }
        if wasHeld { gate.signal() }
    }
}

private final class ReadinessAudioHardware: RecordingHardware, @unchecked Sendable {
    var onAudioChunk: ((Data) -> Void)?
    var averagePower: Float { -60 }
    var peakPower: Float { -60 }
    func prepare(deviceID: AudioDeviceID, selectedInputChannels: [UInt32]?) throws {}
    func startRecording(toOutputFile url: URL, deviceID: AudioDeviceID, selectedInputChannels: [UInt32]?) throws {}
    func stopRecording() {}
    func switchDevice(to deviceID: AudioDeviceID, selectedInputChannels: [UInt32]?) throws {}
    func invalidatePreparation() {}
    func teardown() {}
}
