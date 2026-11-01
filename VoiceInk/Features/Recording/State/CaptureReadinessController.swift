import AppKit
import AVFoundation
import Combine
import CoreAudio

@MainActor
final class CaptureReadinessController: ObservableObject {
    typealias Permissions = (microphone: CapturePermission, accessibility: Bool)

    @Published private(set) var snapshot = CaptureReadiness(
        microphonePermission: .notDetermined, hasMicrophone: false,
        accessibilityGranted: false, model: .checking, usesPaste: true
    )

    private let models: TranscriptionModelManager
    private let devices: AudioDeviceManager
    private let permissionReader: @Sendable () -> Permissions
    private var subscriptions: Set<AnyCancellable> = []
    /// Until the first pass answers, readiness reports a check in progress rather than missing access or input.
    private var hasResolvedSystemState = false
    private var permissions: Permissions = (.granted, true)
    private var hasMicrophone = true
    private var requestedPass = 0
    private var startedPass = 0
    private var completedPass = 0
    private var passTask: Task<Void, Never>?
    private var passWaiters: [(pass: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private nonisolated static let systemQueue = DispatchQueue(
        label: "com.prakashjoshipax.voiceink.captureReadiness", qos: .userInitiated
    )

    init(
        models: TranscriptionModelManager, devices: AudioDeviceManager,
        permissionReader: @escaping @Sendable () -> Permissions = { CaptureReadinessController.readPermissions() }
    ) {
        self.models = models
        self.devices = devices
        self.permissionReader = permissionReader
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

    /// Schedules a pass that reads permissions and device properties off the main actor. Requests made while one
    /// runs coalesce into a single further pass.
    func refreshSnapshot() {
        requestedPass += 1
        guard passTask == nil else { return }
        // Holds the controller weakly across each query, so it is released with its owner even while one runs.
        passTask = Task { [weak self] in
            while let pass = self?.beginPass() {
                let state = await Self.readSystemState(pass)
                self?.finishPass(state)
            }
        }
    }

    /// The snapshot from a pass requested by this call.
    func refreshedSnapshot() async -> CaptureReadiness {
        refreshSnapshot()
        let pass = requestedPass
        await withCheckedContinuation { passWaiters.append((pass, $0)) }
        return snapshot
    }

    /// Current model state with the last read permissions and microphone availability; schedules a pass.
    func currentSnapshot() -> CaptureReadiness {
        publishSnapshot()
        refreshSnapshot()
        return snapshot
    }

    private struct PassRequest {
        let devices: AudioDeviceManager
        let deviceIDs: [AudioDeviceID]
        let permissionReader: @Sendable () -> Permissions
    }

    private struct SystemState {
        let properties: RecordingDeviceProperties
        let permissions: Permissions
    }

    private func beginPass() -> PassRequest? {
        guard startedPass < requestedPass else {
            passTask = nil
            return nil
        }
        startedPass = requestedPass
        return PassRequest(devices: devices, deviceIDs: devices.availableDevices.map(\.id), permissionReader: permissionReader)
    }

    private func finishPass(_ state: SystemState) {
        guard state.properties.deviceIDs == devices.availableDevices.map(\.id) else {
            // The device list changed during the query, so its properties may describe other devices.
            requestedPass += 1
            return
        }
        permissions = state.permissions
        hasMicrophone = devices.resolveCurrentRecordingDevice(using: state.properties).deviceID != nil
        hasResolvedSystemState = true
        completedPass = startedPass
        publishSnapshot()
        let satisfied = passWaiters.filter { $0.pass <= completedPass }
        passWaiters.removeAll { $0.pass <= completedPass }
        satisfied.forEach { $0.continuation.resume() }
    }

    /// TCC permission checks and CoreAudio property reads are synchronous IPC that can each take over a second
    /// when the daemons are busy.
    private nonisolated static func readSystemState(_ request: PassRequest) async -> SystemState {
        // The device properties are CoreAudio reads, which are safe on any thread.
        nonisolated(unsafe) let request = request
        return await withCheckedContinuation { continuation in
            systemQueue.async {
                continuation.resume(returning: SystemState(
                    properties: request.devices.fetchRecordingDeviceProperties(for: request.deviceIDs),
                    permissions: request.permissionReader()
                ))
            }
        }
    }

    private func publishSnapshot() {
        let next = CaptureReadiness(
            microphonePermission: permissions.microphone,
            hasMicrophone: hasMicrophone,
            accessibilityGranted: permissions.accessibility,
            model: hasResolvedSystemState ? modelReadiness() : .checking,
            usesPaste: ModeManager.shared.currentEffectiveConfiguration?.outputMode == .paste
        )
        if next != snapshot { snapshot = next }
    }

    nonisolated static func readPermissions() -> Permissions {
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
