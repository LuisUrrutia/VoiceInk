import AppKit
import AVFoundation
import Combine

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

    init(
        models: TranscriptionModelManager, devices: AudioDeviceManager,
        permissionReader: (() -> (microphone: CapturePermission, accessibility: Bool))? = nil
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
        refresh()
    }

    func refresh() {
        models.refreshLocalModelInstallation()
        models.refreshCloudProviderConfiguration()
        refreshSnapshot()
    }

    func refreshSnapshot() {
        let permissions = permissionReader?() ?? Self.readPermissions()
        snapshot = CaptureReadiness(
            microphonePermission: permissions.microphone,
            hasMicrophone: devices.resolveCurrentRecordingDevice().deviceID != nil,
            accessibilityGranted: permissions.accessibility,
            model: modelReadiness(),
            usesPaste: ModeManager.shared.currentEffectiveConfiguration?.outputMode == .paste
        )
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
