import XCTest
import AppKit
import Combine
import CoreAudio
import SwiftData
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
}

private final class ReadinessAudioHardware: RecordingHardware, @unchecked Sendable {
    var onAudioChunk: ((Data) -> Void)?
    var averagePower: Float { -60 }
    var peakPower: Float { -60 }
    func prepare(deviceID: AudioDeviceID) throws {}
    func startRecording(toOutputFile url: URL, deviceID: AudioDeviceID) throws {}
    func stopRecording() {}
    func switchDevice(to deviceID: AudioDeviceID) throws {}
    func invalidatePreparation() {}
    func teardown() {}
}
