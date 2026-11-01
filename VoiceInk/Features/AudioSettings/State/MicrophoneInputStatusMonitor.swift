import Combine
import CoreAudio
import Foundation

/// Publishes `MicrophoneInputStatus` for the Audio settings and the toolbar microphone menu. Routing reads
/// CoreAudio synchronously, so the properties are fetched off the main thread when devices, routing or the
/// recording change; rendering only reads the last snapshot. Changes during a fetch coalesce into one more pass.
@MainActor
final class MicrophoneInputStatusMonitor: ObservableObject {
    typealias PropertyFetcher = @Sendable (AudioDeviceManager, [AudioDeviceID]) async -> RecordingDeviceProperties

    static let shared = MicrophoneInputStatusMonitor(devices: .shared)

    /// Nil until the first pass completes.
    @Published private(set) var status: MicrophoneInputStatus?

    private let devices: AudioDeviceManager
    private let fetchProperties: PropertyFetcher
    private var subscriptions = Set<AnyCancellable>()
    private var passTask: Task<Void, Never>?
    private var needsPass = false

    init(devices: AudioDeviceManager, fetchProperties: @escaping PropertyFetcher = MicrophoneInputStatusMonitor.fetchOffMain) {
        self.devices = devices
        self.fetchProperties = fetchProperties
        // objectWillChange fires before the change lands; the pass runs on a later main-actor turn.
        devices.objectWillChange
            .sink { [weak self] in self?.setNeedsRefresh() }
            .store(in: &subscriptions)
        devices.notificationCenter.publisher(for: NSNotification.Name("AudioDeviceChanged"))
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.setNeedsRefresh() }
            .store(in: &subscriptions)
        setNeedsRefresh()
    }

    func setNeedsRefresh() {
        needsPass = true
        guard passTask == nil else { return }
        passTask = Task { [weak self] in await self?.runPasses() }
    }

    private func runPasses() async {
        while needsPass {
            needsPass = false
            let deviceIDs = devices.availableDevices.map(\.id)
            let properties = await fetchProperties(devices, deviceIDs)
            // A device list changed during the fetch may describe other devices.
            guard properties.deviceIDs == devices.availableDevices.map(\.id) else {
                needsPass = true
                continue
            }
            let next = devices.microphoneInputStatus(using: properties)
            if next != status { status = next }
        }
        passTask = nil
    }

    private static let queue = DispatchQueue(label: "com.prakashjoshipax.voiceink.microphoneInputStatus", qos: .utility)

    nonisolated static func fetchOffMain(
        _ devices: AudioDeviceManager, _ deviceIDs: [AudioDeviceID]
    ) async -> RecordingDeviceProperties {
        // `fetchRecordingDeviceProperties` only reads CoreAudio, which is safe on any thread.
        nonisolated(unsafe) let devices = devices
        return await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: devices.fetchRecordingDeviceProperties(for: deviceIDs)) }
        }
    }

    deinit {
        passTask?.cancel()
    }
}
