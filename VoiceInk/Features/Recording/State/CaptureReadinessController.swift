import AppKit
import AVFoundation
import Combine
import CoreAudio

@MainActor
final class CaptureReadinessController: ObservableObject {
    @Published private(set) var snapshot = CaptureReadiness(
        microphonePermission: .notDetermined, hasMicrophone: false,
        accessibilityGranted: false, model: .checking, usesPaste: true
    )

    private let models: TranscriptionModelManager
    private let devices: AudioDeviceManager
    private let permissionReader: (() -> (microphone: CapturePermission, accessibility: Bool))?
    private var subscriptions: Set<AnyCancellable> = []
    private var hasMicrophone: Bool
    private var requestedDevicePass = 0
    private var startedDevicePass = 0
    private var completedDevicePass = 0
    private var devicePassTask: Task<Void, Never>?
    private var devicePassWaiters: [(pass: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private nonisolated static let deviceQueue = DispatchQueue(
        label: "com.prakashjoshipax.voiceink.captureReadiness", qos: .userInitiated
    )

    init(
        models: TranscriptionModelManager, devices: AudioDeviceManager,
        permissionReader: (() -> (microphone: CapturePermission, accessibility: Bool))? = nil
    ) {
        self.models = models
        self.devices = devices
        self.permissionReader = permissionReader
        // The manager's last resolution stands in until the first device pass completes.
        hasMicrophone = devices.selectedDeviceID != nil
        for publisher in [models.objectWillChange, devices.objectWillChange, ModeManager.shared.objectWillChange] {
            publisher.sink { [weak self] in
                Task { @MainActor in self?.refreshSnapshot() }
            }.store(in: &subscriptions)
        }
        LifecycleObserver.shared.publisher(for: .applicationDidBecomeActive).sink { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: .aiProviderKeyChanged).sink { [weak self] _ in
            Task { @MainActor in self?.models.refreshCloudProviderConfiguration() }
        }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: .AppSettingsDidChange).sink { [weak self] _ in
            Task { @MainActor in self?.refreshSnapshot() }
        }.store(in: &subscriptions)
        LifecycleObserver.shared.publisher(for: .audioDeviceChanged).sink { [weak self] _ in
            Task { @MainActor in self?.refreshSnapshot() }
        }.store(in: &subscriptions)
        publishSnapshot()
        refresh()
    }

    func refresh() {
        models.refreshLocalModelInstallation()
        models.refreshCloudProviderConfiguration()
        refreshSnapshot()
    }

    /// Schedules a device pass. Requests made while one runs coalesce into a single further pass.
    func refreshSnapshot() {
        requestedDevicePass += 1
        guard devicePassTask == nil else { return }
        // Holds the controller weakly across each query, so it is released with its owner even while one runs.
        devicePassTask = Task { [weak self] in
            while let pass = self?.beginDevicePass() {
                let properties = await Self.fetchProperties(of: pass.devices, for: pass.deviceIDs)
                self?.finishDevicePass(properties)
            }
        }
    }

    /// The snapshot from a device pass requested by this call.
    func refreshedSnapshot() async -> CaptureReadiness {
        refreshSnapshot()
        let pass = requestedDevicePass
        await withCheckedContinuation { devicePassWaiters.append((pass, $0)) }
        return snapshot
    }

    /// Current permissions and model state with the last resolved microphone availability; schedules a device pass.
    func currentSnapshot() -> CaptureReadiness {
        publishSnapshot()
        refreshSnapshot()
        return snapshot
    }

    private func beginDevicePass() -> (devices: AudioDeviceManager, deviceIDs: [AudioDeviceID])? {
        guard startedDevicePass < requestedDevicePass else {
            devicePassTask = nil
            return nil
        }
        startedDevicePass = requestedDevicePass
        return (devices, devices.availableDevices.map(\.id))
    }

    private func finishDevicePass(_ properties: RecordingDeviceProperties) {
        guard properties.deviceIDs == devices.availableDevices.map(\.id) else {
            // The device list changed during the query, so its properties may describe other devices.
            requestedDevicePass += 1
            return
        }
        hasMicrophone = devices.resolveCurrentRecordingDevice(using: properties).deviceID != nil
        completedDevicePass = startedDevicePass
        publishSnapshot()
        let satisfied = devicePassWaiters.filter { $0.pass <= completedDevicePass }
        devicePassWaiters.removeAll { $0.pass <= completedDevicePass }
        satisfied.forEach { $0.continuation.resume() }
    }

    private nonisolated static func fetchProperties(
        of devices: AudioDeviceManager, for deviceIDs: [AudioDeviceID]
    ) async -> RecordingDeviceProperties {
        // The queried properties are CoreAudio reads, which are safe on any thread.
        nonisolated(unsafe) let devices = devices
        return await withCheckedContinuation { continuation in
            deviceQueue.async { continuation.resume(returning: devices.fetchRecordingDeviceProperties(for: deviceIDs)) }
        }
    }

    private func publishSnapshot() {
        let permissions = permissionReader?() ?? Self.readPermissions()
        let next = CaptureReadiness(
            microphonePermission: permissions.microphone,
            hasMicrophone: hasMicrophone,
            accessibilityGranted: permissions.accessibility,
            model: modelReadiness(),
            usesPaste: ModeManager.shared.currentEffectiveConfiguration?.outputMode == .paste
        )
        if next != snapshot { snapshot = next }
    }

    private static func readPermissions() -> (microphone: CapturePermission, accessibility: Bool) {
        let permission: CapturePermission
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: permission = .granted
        case .notDetermined: permission = .notDetermined
        case .denied: permission = .denied
        case .restricted: permission = .restricted
        @unknown default: permission = .restricted
        }
        return (permission, AXIsProcessTrusted())
    }

    private func modelReadiness() -> CaptureModelReadiness {
        guard let mode = ModeManager.shared.currentEffectiveConfiguration else { return .noMode }
        guard let selection = mode.selectedTranscriptionModelName, !selection.isEmpty else { return .noSelection }
        guard let model = TranscriptionModelRegistry.model(forSelectionKey: selection, in: models.allAvailableModels)
        else { return .unavailable }
        return CaptureModelReadiness.evaluate(
            model: model,
            supportedOnOS: models.isAvailableOnCurrentOS(model),
            installedNames: models.hasLoadedInstallationSnapshot ? models.installedLocalModelNames : nil,
            configuredProviderKeys: models.configuredCloudProviderKeys,
            configuredCustomModelIDs: models.configuredCustomModelIDs
        )
    }

    func requestMicrophoneAccess() async {
        if snapshot.microphonePermission == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        } else {
            openPrivacySettings(.microphone)
        }
        refreshSnapshot()
    }

    func openPrivacySettings(_ pane: PrivacySettingsPane) {
        guard let url = URL(string: pane.urlString) else { return }
        NSWorkspace.shared.open(url)
    }
}
