import CoreAudio
import XCTest

@testable import VoiceInk

/// Capture readiness resolves from fetched CoreAudio properties; this pins that the result matches direct
/// resolution under every routing rule and that the scoped resolution queries no property itself.
@MainActor final class RecordingDevicePrefetchTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!
    private let processor = MicrophoneApplication(bundleID: "com.example.processor", name: "Processor")

    override func setUp() {
        super.setUp()
        suiteName = "RecordingDevicePrefetchTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.audioInputModeRawValue = AudioInputMode.systemDefault.rawValue
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func testBluetoothDefaultYieldsToInternalMicrophone() {
        let manager = PrefetchDeviceManager(userDefaults: defaults)

        assertPrefetchedResolutionMatches(manager, expected: PrefetchDeviceManager.internalID)
    }

    func testClosedLidSkipsInternalMicrophoneForUSB() {
        let manager = PrefetchDeviceManager(userDefaults: defaults)
        manager.lidClosed = true

        assertPrefetchedResolutionMatches(manager, expected: PrefetchDeviceManager.usbID)
    }

    func testDisabledAvoidanceKeepsBluetoothDefault() {
        let manager = PrefetchDeviceManager(userDefaults: defaults)
        manager.setAvoidsBluetoothDefaultMicrophone(false)

        assertPrefetchedResolutionMatches(manager, expected: PrefetchDeviceManager.airPodsID)
    }

    func testClosedLidCustomInternalMicrophoneReportsTheBlockedLid() {
        let manager = PrefetchDeviceManager(userDefaults: defaults)
        defaults.selectedAudioDeviceUID = "internal"
        manager.inputMode = .custom
        manager.lidClosed = true

        let resolution = assertPrefetchedResolutionMatches(manager, expected: PrefetchDeviceManager.usbID)
        XCTAssertTrue(resolution.internalMicrophoneBlockedByClosedLid)
    }

    func testCustomSelectionFindsARenamedDeviceByItsModelUID() {
        let manager = PrefetchDeviceManager(userDefaults: defaults)
        defaults.selectedAudioDeviceUID = "usb-before-replug"
        defaults.selectedAudioDeviceModelUID = PrefetchDeviceManager.usbModelUID
        manager.inputMode = .custom

        assertPrefetchedResolutionMatches(manager, expected: PrefetchDeviceManager.usbID)
    }

    func testPrioritizedVirtualInputFollowsItsRequirements() {
        let manager = PrefetchDeviceManager(userDefaults: defaults)
        manager.inputMode = .prioritized
        manager.prioritizedDevices = [
            PrioritizedDevice(
                id: "virtual", name: "Virtual", priority: 0,
                requirements: MicrophoneRequirements(
                    microphone: MicrophoneReference(uid: "usb", name: "USB", modelUID: nil), application: processor
                )
            ),
            PrioritizedDevice(id: "airpods", name: "AirPods", priority: 1),
        ]

        assertPrefetchedResolutionMatches(manager, expected: PrefetchDeviceManager.airPodsID)
        manager.updateRunningApplications([processor.bundleID])
        assertPrefetchedResolutionMatches(manager, expected: PrefetchDeviceManager.virtualID)
        manager.lidClosed = true
        manager.availableDevices.removeAll { $0.id == PrefetchDeviceManager.usbID }
        assertPrefetchedResolutionMatches(manager, expected: PrefetchDeviceManager.airPodsID)
    }

    func testTemporaryMicrophoneTakesPrecedence() {
        let manager = PrefetchDeviceManager(userDefaults: defaults)
        manager.selectTemporaryMicrophone(id: PrefetchDeviceManager.usbID)

        assertPrefetchedResolutionMatches(manager, expected: PrefetchDeviceManager.usbID)
    }

    @discardableResult
    private func assertPrefetchedResolutionMatches(
        _ manager: PrefetchDeviceManager, expected: AudioDeviceID,
        file: StaticString = #filePath, line: UInt = #line
    ) -> RecordingDeviceResolution {
        let direct = manager.resolveCurrentRecordingDevice()
        let properties = manager.fetchRecordingDeviceProperties(for: manager.availableDevices.map(\.id))
        manager.rawQueryCount = 0

        let prefetched = manager.resolveCurrentRecordingDevice(using: properties)

        XCTAssertEqual(manager.rawQueryCount, 0, "prefetched resolution queried a device property", file: file, line: line)
        XCTAssertEqual(prefetched.deviceID, expected, file: file, line: line)
        XCTAssertEqual(prefetched.deviceID, direct.deviceID, file: file, line: line)
        XCTAssertEqual(
            prefetched.internalMicrophoneBlockedByClosedLid, direct.internalMicrophoneBlockedByClosedLid,
            file: file, line: line
        )
        XCTAssertNil(manager.prefetchedRoutingProperties, file: file, line: line)
        _ = manager.resolveCurrentRecordingDevice()
        XCTAssertGreaterThan(manager.rawQueryCount, 0, "direct resolution reused the scoped properties", file: file, line: line)
        return prefetched
    }
}

private final class PrefetchDeviceManager: AudioDeviceManager {
    static let internalID: AudioDeviceID = 1
    static let virtualID: AudioDeviceID = 2
    static let usbID: AudioDeviceID = 3
    static let airPodsID: AudioDeviceID = 4
    static let usbModelUID = "usb-model"

    var lidClosed = false
    var rawQueryCount = 0
    override var isClamshellClosed: Bool { lidClosed }

    init(userDefaults: UserDefaults) {
        super.init(userDefaults: userDefaults, notificationCenter: NotificationCenter())
    }

    override func startMonitoring() {}
    override func loadAvailableDevices(completion: (() -> Void)? = nil) {
        availableDevices = [
            (Self.internalID, "internal", "MacBook Pro Microphone"), (Self.virtualID, "virtual", "Virtual"),
            (Self.usbID, "usb", "USB Microphone"), (Self.airPodsID, "airpods", "AirPods"),
        ]
        completion?()
    }
    override func getSystemDefaultDevice() -> AudioDeviceID? {
        rawQueryCount += 1
        return Self.airPodsID
    }
    override func isInternalMicrophone(_ deviceID: AudioDeviceID) -> Bool {
        rawQueryCount += 1
        return deviceID == Self.internalID
    }
    override func getDeviceModelUID(deviceID: AudioDeviceID) -> String? {
        rawQueryCount += 1
        return deviceID == Self.usbID ? Self.usbModelUID : nil
    }
    override func inputTransport(_ deviceID: AudioDeviceID) -> AudioInputTransport {
        rawQueryCount += 1
        switch deviceID {
        case Self.internalID: return .builtIn
        case Self.virtualID: return .virtual
        case Self.airPodsID: return .bluetooth
        default: return .other
        }
    }
}
