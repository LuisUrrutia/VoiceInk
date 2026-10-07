import CoreAudio
import XCTest

@testable import VoiceInk

@MainActor final class RecordingDeviceRoutingTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "RecordingDeviceRoutingTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.selectedAudioDeviceUID = "internal-mic"
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func testAllInputModesSkipClosedInternalMicrophone() {
        for mode in AudioInputMode.allCases {
            let manager = makeManager(mode: mode, lidClosed: true)

            let resolution = manager.resolveCurrentRecordingDevice()

            XCTAssertEqual(resolution.deviceID, 2, "\(mode)")
            XCTAssertEqual(manager.getCurrentDevice(), 2, "\(mode)")
            XCTAssertTrue(resolution.internalMicrophoneBlockedByClosedLid, "\(mode)")
            XCTAssertTrue(resolution.fellBackFromClosedInternalMicrophone, "\(mode)")
        }
    }

    func testAllInputModesKeepOpenInternalMicrophone() {
        for mode in AudioInputMode.allCases {
            let manager = makeManager(mode: mode)

            let resolution = manager.resolveCurrentRecordingDevice()

            XCTAssertEqual(resolution.deviceID, 1, "\(mode)")
            XCTAssertFalse(resolution.internalMicrophoneBlockedByClosedLid, "\(mode)")
            XCTAssertFalse(resolution.fellBackFromClosedInternalMicrophone, "\(mode)")
        }
    }

    func testPrioritizedModeKeepsPriorityOrderAmongUsableInputs() {
        let manager = makeManager(mode: .prioritized, lidClosed: true)
        manager.prioritizedDevices = [
            PrioritizedDevice(id: "usb-mic", name: "USB", priority: 2),
            PrioritizedDevice(id: "internal-mic", name: "Internal", priority: 0),
            PrioritizedDevice(id: "headset-mic", name: "Headset", priority: 1),
        ]

        let resolution = manager.resolveCurrentRecordingDevice()

        XCTAssertEqual(resolution.deviceID, 3)
    }

    func testCustomPreferenceSurvivesCloseOpenCycle() {
        let manager = makeManager(mode: .custom)

        manager.lidClosed = true
        manager.handleClamshellChange(isClosed: true)

        XCTAssertEqual(manager.selectedDeviceID, 2)
        XCTAssertEqual(manager.getCurrentDevice(), 2)
        XCTAssertEqual(defaults.selectedAudioDeviceUID, "internal-mic")

        manager.lidClosed = false
        manager.handleClamshellChange(isClosed: false)

        XCTAssertEqual(manager.selectedDeviceID, 1)
        XCTAssertEqual(manager.getCurrentDevice(), 1)
        XCTAssertEqual(defaults.selectedAudioDeviceUID, "internal-mic")
    }

    func testPrioritizedSelectionTracksCloseOpenCycle() {
        let manager = makeManager(mode: .prioritized)

        manager.lidClosed = true
        manager.handleClamshellChange(isClosed: true)

        XCTAssertEqual(manager.selectedDeviceID, 2)

        manager.lidClosed = false
        manager.handleClamshellChange(isClosed: false)

        XCTAssertEqual(manager.selectedDeviceID, 1)
    }

    func testClosedLidStartupPublishesUsableCustomDevice() {
        let manager = makeManager(mode: .custom, lidClosed: true)

        XCTAssertEqual(manager.selectedDeviceID, 2)
        XCTAssertEqual(defaults.selectedAudioDeviceUID, "internal-mic")
    }

    func testClosedLidWithoutAlternativeDoesNotUseInternalMicrophone() {
        for mode in AudioInputMode.allCases {
            let manager = makeManager(mode: mode, lidClosed: true)
            manager.availableDevices.removeAll { $0.id != 1 }

            let resolution = manager.resolveCurrentRecordingDevice()

            XCTAssertNil(resolution.deviceID, "\(mode)")
            XCTAssertNil(manager.findBestAvailableDevice(), "\(mode)")
            XCTAssertEqual(manager.getCurrentDevice(), 0, "\(mode)")
            XCTAssertTrue(resolution.internalMicrophoneBlockedByClosedLid, "\(mode)")
        }
    }

    func testClosedLidKeepsHeadsetMicrophoneEligible() {
        let manager = makeManager(mode: .custom, lidClosed: true)
        defaults.selectedAudioDeviceUID = "headset-mic"

        let resolution = manager.resolveCurrentRecordingDevice()

        XCTAssertEqual(resolution.deviceID, 3)
        XCTAssertFalse(resolution.internalMicrophoneBlockedByClosedLid)
        XCTAssertTrue(manager.isDeviceUsableForRecording(3))
    }

    func testSystemDefaultExternalMicrophoneStaysSelected() {
        let manager = makeManager(mode: .systemDefault, lidClosed: true)
        manager.systemDefaultDeviceID = 3

        let resolution = manager.resolveCurrentRecordingDevice()

        XCTAssertEqual(resolution.deviceID, 3)
        XCTAssertFalse(resolution.fellBackFromClosedInternalMicrophone)
        XCTAssertEqual(manager.systemDefaultDeviceID, 3)
    }

    func testExcludedAndUnavailableInputsAreNeverResolved() {
        let manager = makeManager(mode: .systemDefault)
        manager.systemDefaultDeviceID = 99
        manager.availableDevices.removeAll { $0.id == 3 }

        let resolution = manager.resolveCurrentRecordingDevice(excluding: 1)

        XCTAssertEqual(resolution.deviceID, 2)
    }

    func testClosingLidRequestsOneSwitchForActiveInternalMicrophone() {
        let manager = makeManager(mode: .prioritized)
        manager.recordingDidStart(deviceID: 1)
        var requests: [RecordingDeviceChangeRequest] = []
        let observer = manager.notificationCenter.addObserver(
            forName: .recordingDeviceChangeRequired, object: nil, queue: nil
        ) { notification in
            if let request = notification.object as? RecordingDeviceChangeRequest {
                requests.append(request)
            }
        }
        defer { manager.notificationCenter.removeObserver(observer) }

        manager.lidClosed = true
        manager.handleClamshellChange(isClosed: true)
        manager.handleClamshellChange(isClosed: true)

        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.fallbackDeviceID, 2)
        XCTAssertEqual(requests.first?.reason, .closedLid)
        XCTAssertTrue(manager.isRecordingActive)
        XCTAssertEqual(manager.activeRecordingDeviceID, 1)

        manager.recordingDeviceChangeFinished(activeDeviceID: 2)
        manager.recordingDidStop()

        XCTAssertFalse(manager.isRecordingActive)
        XCTAssertEqual(manager.selectedDeviceID, 2)
    }

    func testClosingLidDoesNotSwitchActiveExternalMicrophone() {
        let manager = makeManager(mode: .custom)
        manager.recordingDidStart(deviceID: 2)

        manager.lidClosed = true
        manager.handleClamshellChange(isClosed: true)

        XCTAssertFalse(manager.recordingDeviceSession.isDeviceChangePending)
        XCTAssertEqual(manager.activeRecordingDeviceID, 2)
        XCTAssertTrue(manager.isRecordingActive)
    }

    func testOpeningLidDoesNotSwitchAnActiveRecording() {
        let manager = makeManager(mode: .custom, lidClosed: true)
        manager.recordingDidStart(deviceID: 2)

        manager.lidClosed = false
        manager.handleClamshellChange(isClosed: false)

        XCTAssertEqual(manager.selectedDeviceID, 2)
        XCTAssertEqual(manager.activeRecordingDeviceID, 2)
        XCTAssertFalse(manager.recordingDeviceSession.isDeviceChangePending)

        manager.recordingDidStop()

        XCTAssertEqual(manager.selectedDeviceID, 1)
    }

    private func makeManager(
        mode: AudioInputMode, lidClosed: Bool = false
    ) -> FixtureAudioDeviceManager {
        defaults.audioInputModeRawValue = mode.rawValue
        let priorities = [
            PrioritizedDevice(id: "internal-mic", name: "Internal", priority: 0),
            PrioritizedDevice(id: "usb-mic", name: "USB", priority: 1),
        ]
        defaults.prioritizedDevicesData = try! JSONEncoder().encode(priorities)
        return FixtureAudioDeviceManager(userDefaults: defaults, lidClosed: lidClosed)
    }
}

private final class FixtureAudioDeviceManager: AudioDeviceManager {
    var lidClosed: Bool
    var systemDefaultDeviceID: AudioDeviceID? = 1

    init(userDefaults: UserDefaults, lidClosed: Bool) {
        self.lidClosed = lidClosed
        super.init(userDefaults: userDefaults, notificationCenter: NotificationCenter())
    }

    override var isClamshellClosed: Bool { lidClosed }

    override func startMonitoring() {}

    override func loadAvailableDevices(completion: (() -> Void)? = nil) {
        availableDevices = [
            (1, "internal-mic", "Internal"),
            (2, "usb-mic", "USB"),
            (3, "headset-mic", "Headset"),
        ]
        completion?()
    }

    override func getSystemDefaultDevice() -> AudioDeviceID? { systemDefaultDeviceID }

    override func isInternalMicrophone(_ deviceID: AudioDeviceID) -> Bool { deviceID == 1 }

    override func getDeviceModelUID(deviceID: AudioDeviceID) -> String? { nil }
}
