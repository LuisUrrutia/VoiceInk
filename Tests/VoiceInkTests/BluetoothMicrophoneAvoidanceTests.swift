import CoreAudio
import XCTest

@testable import VoiceInk

@MainActor final class BluetoothMicrophoneAvoidanceTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!
    private let processor = MicrophoneApplication(bundleID: "com.example.processor", name: "Processor")

    override func setUp() {
        super.setUp()
        suiteName = "BluetoothMicrophoneAvoidanceTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.audioInputModeRawValue = AudioInputMode.systemDefault.rawValue
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func testBluetoothDefaultRecordsFromInternalMicrophoneAndNamesTheSubstitution() {
        let manager = BluetoothDeviceManager(userDefaults: defaults)

        XCTAssertTrue(manager.avoidsBluetoothDefaultMicrophone)
        XCTAssertEqual(manager.getCurrentDevice(), BluetoothDeviceManager.internalID)
        XCTAssertEqual(manager.selectedDeviceID, BluetoothDeviceManager.internalID)
        XCTAssertEqual(
            manager.bluetoothDefaultSubstitution,
            BluetoothMicrophoneSubstitution(bluetoothName: "AirPods", standInName: "MacBook Pro Microphone")
        )
        XCTAssertEqual(
            manager.bluetoothDefaultSubstitution?.message,
            "AirPods is Bluetooth, so VoiceInk listens to MacBook Pro Microphone"
        )
    }

    func testClosedLidUsesFirstOtherRealInputRatherThanUnconfiguredVirtualInput() {
        let manager = BluetoothDeviceManager(userDefaults: defaults)

        manager.lidClosed = true
        manager.handleClamshellChange(isClosed: true)

        let resolution = manager.resolveCurrentRecordingDevice()
        XCTAssertEqual(resolution.deviceID, BluetoothDeviceManager.usbID)
        XCTAssertFalse(resolution.internalMicrophoneBlockedByClosedLid)
        XCTAssertEqual(manager.bluetoothDefaultSubstitution?.standInName, "USB Microphone")
    }

    func testBluetoothDefaultIsKeptWhenNoOtherRealInputIsUsable() {
        let manager = BluetoothDeviceManager(userDefaults: defaults)
        manager.availableDevices.removeAll { $0.id == BluetoothDeviceManager.usbID }
        manager.lidClosed = true

        manager.handleClamshellChange(isClosed: true)

        XCTAssertEqual(manager.getCurrentDevice(), BluetoothDeviceManager.airPodsID)
        XCTAssertNil(manager.bluetoothDefaultSubstitution)
    }

    func testDisabledSettingFollowsBluetoothDefaultAndPersists() {
        let manager = BluetoothDeviceManager(userDefaults: defaults)

        manager.setAvoidsBluetoothDefaultMicrophone(false)

        XCTAssertEqual(manager.getCurrentDevice(), BluetoothDeviceManager.airPodsID)
        XCTAssertNil(manager.bluetoothDefaultSubstitution)
        XCTAssertFalse(defaults.avoidsBluetoothDefaultMicrophone)
        XCTAssertFalse(BluetoothDeviceManager(userDefaults: defaults).avoidsBluetoothDefaultMicrophone)
    }

    func testNonBluetoothDefaultIsUnchanged() {
        let manager = BluetoothDeviceManager(userDefaults: defaults)

        manager.systemDefaultDeviceID = BluetoothDeviceManager.usbID
        manager.reconcileInputAvailability()

        XCTAssertEqual(manager.getCurrentDevice(), BluetoothDeviceManager.usbID)
        XCTAssertNil(manager.bluetoothDefaultSubstitution)
    }

    func testExplicitCustomPriorityAndTemporaryBluetoothChoicesAreHonored() {
        defaults.audioInputModeRawValue = AudioInputMode.custom.rawValue
        defaults.selectedAudioDeviceUID = "airpods"
        XCTAssertEqual(BluetoothDeviceManager(userDefaults: defaults).getCurrentDevice(), BluetoothDeviceManager.airPodsID)

        defaults.audioInputModeRawValue = AudioInputMode.prioritized.rawValue
        defaults.prioritizedDevicesData = try! JSONEncoder().encode([
            PrioritizedDevice(id: "airpods", name: "AirPods", priority: 0),
            PrioritizedDevice(id: "internal", name: "MacBook Pro Microphone", priority: 1),
        ])
        XCTAssertEqual(BluetoothDeviceManager(userDefaults: defaults).getCurrentDevice(), BluetoothDeviceManager.airPodsID)

        defaults.audioInputModeRawValue = AudioInputMode.systemDefault.rawValue
        let manager = BluetoothDeviceManager(userDefaults: defaults)
        manager.selectTemporaryMicrophone(id: BluetoothDeviceManager.airPodsID)
        manager.reconcileInputAvailability()
        XCTAssertEqual(manager.temporaryMicrophone?.uid, "airpods")
        XCTAssertEqual(manager.getCurrentDevice(), BluetoothDeviceManager.airPodsID)
        XCTAssertNil(manager.bluetoothDefaultSubstitution)
    }

    func testImplicitFallbackPrefersRealInputsBeforeBluetoothAndUnconfiguredVirtualInputs() {
        defaults.audioInputModeRawValue = AudioInputMode.custom.rawValue
        defaults.selectedAudioDeviceUID = "missing"
        let manager = BluetoothDeviceManager(userDefaults: defaults)
        manager.lidClosed = true

        manager.handleClamshellChange(isClosed: true)
        XCTAssertEqual(manager.findBestAvailableDevice(), BluetoothDeviceManager.usbID)
        XCTAssertEqual(manager.getCurrentDevice(), BluetoothDeviceManager.usbID)

        manager.availableDevices.removeAll { $0.id == BluetoothDeviceManager.usbID }
        manager.reconcileInputAvailability()
        XCTAssertEqual(manager.getCurrentDevice(), BluetoothDeviceManager.beatsID)

        manager.setAvoidsBluetoothDefaultMicrophone(false)
        XCTAssertEqual(manager.getCurrentDevice(), BluetoothDeviceManager.teamsID)
    }

    func testVirtualInputConfiguredWithMetRequirementsCanStandIn() {
        defaults.prioritizedDevicesData = try! JSONEncoder().encode([
            PrioritizedDevice(
                id: "teams", name: "Teams Audio", priority: 0,
                requirements: MicrophoneRequirements(application: processor)
            )
        ])
        let manager = BluetoothDeviceManager(userDefaults: defaults)
        manager.availableDevices.removeAll { $0.id == BluetoothDeviceManager.usbID }
        manager.lidClosed = true
        manager.handleClamshellChange(isClosed: true)
        XCTAssertEqual(manager.getCurrentDevice(), BluetoothDeviceManager.airPodsID)

        manager.updateRunningApplications([processor.bundleID])

        XCTAssertEqual(manager.getCurrentDevice(), BluetoothDeviceManager.teamsID)
        XCTAssertEqual(manager.bluetoothDefaultSubstitution?.standInName, "Teams Audio")
    }

    func testActiveRecordingKeepsItsDeviceAndReconcilesAfterStop() {
        let manager = BluetoothDeviceManager(userDefaults: defaults)
        manager.availableDevices.removeAll { $0.id == BluetoothDeviceManager.usbID }
        manager.lidClosed = true
        manager.handleClamshellChange(isClosed: true)
        manager.recordingDidStart(deviceID: BluetoothDeviceManager.airPodsID)
        var requests = 0
        let observer = manager.notificationCenter.addObserver(
            forName: .recordingDeviceChangeRequired, object: nil, queue: nil
        ) { _ in requests += 1 }
        defer { manager.notificationCenter.removeObserver(observer) }

        manager.availableDevices.append((BluetoothDeviceManager.usbID, "usb", "USB Microphone"))
        manager.reconcileInputAvailability()
        manager.systemDefaultDeviceID = BluetoothDeviceManager.beatsID
        manager.reconcileInputAvailability()

        XCTAssertEqual(requests, 0)
        XCTAssertEqual(manager.getCurrentDevice(), BluetoothDeviceManager.airPodsID)
        manager.recordingDidStop()
        XCTAssertEqual(manager.getCurrentDevice(), BluetoothDeviceManager.usbID)
    }

    func testClosingLidDuringStandInRecordingRequestsOneUsableSwitch() {
        let manager = BluetoothDeviceManager(userDefaults: defaults)
        manager.availableDevices.removeAll { $0.id == BluetoothDeviceManager.usbID }
        manager.recordingDidStart(deviceID: BluetoothDeviceManager.internalID)
        var requests: [RecordingDeviceChangeRequest] = []
        let observer = manager.notificationCenter.addObserver(
            forName: .recordingDeviceChangeRequired, object: nil, queue: nil
        ) { notification in
            if let request = notification.object as? RecordingDeviceChangeRequest { requests.append(request) }
        }
        defer { manager.notificationCenter.removeObserver(observer) }

        manager.lidClosed = true
        manager.handleClamshellChange(isClosed: true)

        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.fallbackDeviceID, BluetoothDeviceManager.airPodsID)
        XCTAssertEqual(requests.first?.reason, .closedLid)
    }

    func testGeneralBackupRestoresSettingAndLegacyBackupKeepsCurrentValue() throws {
        let manager = BluetoothDeviceManager(userDefaults: defaults)
        let legacy = try JSONDecoder().decode(GeneralBackup.self, from: Data("{}".utf8))

        legacy.restoreMicrophonePreferences(in: manager)
        XCTAssertTrue(manager.avoidsBluetoothDefaultMicrophone)

        let backup = try JSONDecoder().decode(
            GeneralBackup.self, from: Data(#"{"avoidsBluetoothDefaultMicrophone":false}"#.utf8))
        let restored = try JSONDecoder().decode(GeneralBackup.self, from: JSONEncoder().encode(backup))
        restored.restoreMicrophonePreferences(in: manager)

        XCTAssertFalse(manager.avoidsBluetoothDefaultMicrophone)
        XCTAssertFalse(defaults.avoidsBluetoothDefaultMicrophone)
        XCTAssertEqual(manager.getCurrentDevice(), BluetoothDeviceManager.airPodsID)
    }

    func testConfigurationFileValidatesAppliesAndCapturesSetting() throws {
        let key = UserDefaults.Keys.avoidsBluetoothDefaultMicrophone
        XCTAssertThrowsError(try ConfigurationPreferences.validate([key: .string("off")], defaults: defaults))

        try ConfigurationPreferences.validate([key: .bool(false)], defaults: defaults)
        try ConfigurationPreferences.apply([key: .bool(false)], to: defaults)

        XCTAssertFalse(defaults.avoidsBluetoothDefaultMicrophone)
        XCTAssertEqual(try ConfigurationPreferences.capture(from: defaults)[key], .bool(false))
        XCTAssertFalse(BluetoothDeviceManager(userDefaults: defaults).avoidsBluetoothDefaultMicrophone)
    }
}

private final class BluetoothDeviceManager: AudioDeviceManager {
    static let internalID: AudioDeviceID = 1
    static let teamsID: AudioDeviceID = 2
    static let beatsID: AudioDeviceID = 3
    static let usbID: AudioDeviceID = 4
    static let airPodsID: AudioDeviceID = 5

    var lidClosed = false
    var systemDefaultDeviceID: AudioDeviceID? = airPodsID
    override var isClamshellClosed: Bool { lidClosed }

    init(userDefaults: UserDefaults) {
        super.init(userDefaults: userDefaults, notificationCenter: NotificationCenter())
    }

    override func startMonitoring() {}
    override func loadAvailableDevices(completion: (() -> Void)? = nil) {
        availableDevices = [
            (Self.internalID, "internal", "MacBook Pro Microphone"), (Self.teamsID, "teams", "Teams Audio"),
            (Self.beatsID, "beats", "Beats"), (Self.usbID, "usb", "USB Microphone"),
            (Self.airPodsID, "airpods", "AirPods"),
        ]
        completion?()
    }
    override func getSystemDefaultDevice() -> AudioDeviceID? { systemDefaultDeviceID }
    override func isInternalMicrophone(_ deviceID: AudioDeviceID) -> Bool { deviceID == Self.internalID }
    override func getDeviceModelUID(deviceID: AudioDeviceID) -> String? { nil }
    override func inputTransport(_ deviceID: AudioDeviceID) -> AudioInputTransport {
        switch deviceID {
        case Self.internalID: return .builtIn
        case Self.teamsID: return .virtual
        case Self.beatsID, Self.airPodsID: return .bluetooth
        default: return .other
        }
    }
}
