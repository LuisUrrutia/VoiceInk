import CoreAudio
import Foundation

@testable import VoiceInk

/// One always-available input, so recorder lifecycle tests neither query nor depend on this Mac's audio devices.
final class FixedInputAudioDevices: AudioDeviceManager {
    static let deviceID: AudioDeviceID = 94

    init() {
        super.init(
            userDefaults: UserDefaults(suiteName: "VoiceInkTests.FixedInputAudioDevices")!,
            notificationCenter: NotificationCenter()
        )
    }

    override func startMonitoring() {}
    override func loadAvailableDevices(completion: (() -> Void)? = nil) {
        availableDevices = [(id: Self.deviceID, uid: "fixed-input", name: "Fixed input")]
        completion?()
    }
    override func getSystemDefaultDevice() -> AudioDeviceID? { Self.deviceID }
    override func getDeviceModelUID(deviceID: AudioDeviceID) -> String? { nil }
    override func isInternalMicrophone(_ deviceID: AudioDeviceID) -> Bool { false }
    override func inputTransport(_ deviceID: AudioDeviceID) -> AudioInputTransport { .other }
}
