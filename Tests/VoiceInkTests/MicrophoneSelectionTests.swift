import CoreAudio
import XCTest

@testable import VoiceInk

@MainActor final class MicrophoneSelectionTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!
    private let processor = MicrophoneApplication(bundleID: "com.example.processor", name: "Processor")
    private let source = MicrophoneReference(uid: "usb", name: "USB Input", modelUID: nil)

    override func setUp() {
        super.setUp()
        suiteName = "MicrophoneSelectionTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.audioInputModeRawValue = AudioInputMode.prioritized.rawValue
        defaults.selectedAudioDeviceUID = "virtual"
        defaults.prioritizedDevicesData = try! JSONEncoder().encode([
            PrioritizedDevice(
                id: "virtual", name: "Virtual Input", priority: 0,
                requirements: MicrophoneRequirements(microphone: source, application: processor)
            ),
            PrioritizedDevice(id: "usb", name: "USB Input", priority: 1),
            PrioritizedDevice(id: "wireless", name: "Wireless Input", priority: 2),
            PrioritizedDevice(id: "internal", name: "Internal Input", priority: 3),
        ])
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func testApplicationLaunchAndTerminationChangeEligibilityWithoutRemovingVirtualDevice() {
        let manager = SelectionDeviceManager(userDefaults: defaults)
        XCTAssertEqual(manager.getCurrentDevice(), 2)

        manager.updateRunningApplications([processor.bundleID])
        XCTAssertEqual(manager.getCurrentDevice(), 4)

        manager.updateRunningApplications([])
        XCTAssertEqual(manager.getCurrentDevice(), 2)
        XCTAssertTrue(manager.availableDevices.contains(where: { $0.id == 4 }))
    }

    func testBothRequirementsMustBeMetAndSourceReconnectRestoresPriority() {
        let manager = SelectionDeviceManager(userDefaults: defaults)
        manager.availableDevices.removeAll { $0.id == 2 }

        manager.updateRunningApplications([processor.bundleID])

        XCTAssertEqual(manager.getCurrentDevice(), 3)
        manager.availableDevices.append((2, "usb", "USB Input"))
        manager.reconcileInputAvailability()
        XCTAssertEqual(manager.getCurrentDevice(), 4)
    }

    func testRequirementsAlsoApplyToCustomSystemDefaultAndFallbackRoutes() {
        for mode in AudioInputMode.allCases {
            defaults.audioInputModeRawValue = mode.rawValue
            let manager = SelectionDeviceManager(userDefaults: defaults)
            manager.availableDevices.removeAll { $0.id != 4 }

            manager.reconcileInputAvailability()

            XCTAssertNil(manager.resolveCurrentRecordingDevice().deviceID, "\(mode)")
            XCTAssertNil(manager.findBestAvailableDevice(), "\(mode)")
        }
    }

    func testRequiredInternalMicrophoneIsUnavailableWithClosedLid() {
        let manager = SelectionDeviceManager(userDefaults: defaults)
        manager.updateRunningApplications([processor.bundleID])
        manager.lidClosed = true

        manager.updateMicrophoneRequirements(
            MicrophoneRequirements(microphone: MicrophoneReference(uid: "internal", name: "Internal", modelUID: nil)),
            for: "virtual"
        )

        XCTAssertEqual(manager.getCurrentDevice(), 2)
        XCTAssertFalse(manager.isDeviceUsableForRecording(4))
    }

    func testTemporarySelectionPreservesPreferencesAndSurvivesUnrelatedChanges() {
        let manager = SelectionDeviceManager(userDefaults: defaults)
        manager.updateRunningApplications([processor.bundleID])
        let savedPriorities = defaults.prioritizedDevicesData

        manager.selectTemporaryMicrophone(id: 1)
        manager.updateRunningApplications([processor.bundleID, "com.example.unrelated"])
        manager.reconcileInputAvailability()

        XCTAssertEqual(manager.getCurrentDevice(), 1)
        XCTAssertEqual(manager.temporaryMicrophone?.uid, "internal")
        XCTAssertEqual(manager.inputMode, .prioritized)
        XCTAssertEqual(defaults.audioInputModeRawValue, AudioInputMode.prioritized.rawValue)
        XCTAssertEqual(defaults.selectedAudioDeviceUID, "virtual")
        XCTAssertEqual(defaults.prioritizedDevicesData, savedPriorities)
    }

    func testReturningHigherPriorityInputClearsTemporarySelectionEvenWhenSelectedInputStaysConnected() {
        let manager = SelectionDeviceManager(userDefaults: defaults)
        manager.updateRunningApplications([processor.bundleID])
        manager.availableDevices.removeAll { $0.id == 2 }
        manager.reconcileInputAvailability()
        manager.selectTemporaryMicrophone(id: 1)

        manager.availableDevices.append((2, "usb", "USB Input"))
        manager.reconcileInputAvailability()

        XCTAssertNil(manager.temporaryMicrophone)
        XCTAssertEqual(manager.getCurrentDevice(), 4)
        XCTAssertTrue(manager.availableDevices.contains(where: { $0.id == 1 }))
    }

    func testReturningLowerPriorityInputDoesNotClearTemporarySelection() {
        let manager = SelectionDeviceManager(userDefaults: defaults)
        manager.availableDevices.removeAll { $0.id == 3 }
        manager.reconcileInputAvailability()
        manager.selectTemporaryMicrophone(id: 2)

        manager.availableDevices.append((3, "wireless", "Wireless Input"))
        manager.reconcileInputAvailability()

        XCTAssertEqual(manager.temporaryMicrophone?.uid, "usb")
        XCTAssertEqual(manager.getCurrentDevice(), 2)
    }

    func testReturningApplicationRestoresPreferredVirtualInput() {
        let manager = SelectionDeviceManager(userDefaults: defaults)
        manager.selectTemporaryMicrophone(id: 1)

        manager.updateRunningApplications([processor.bundleID])

        XCTAssertNil(manager.temporaryMicrophone)
        XCTAssertEqual(manager.getCurrentDevice(), 4)
    }

    func testUnavailableTemporaryInputFallsBackAndCannotBeReselected() {
        let manager = SelectionDeviceManager(userDefaults: defaults)
        manager.selectTemporaryMicrophone(id: 3)

        manager.availableDevices.removeAll { $0.id == 3 }
        manager.reconcileInputAvailability()
        manager.selectTemporaryMicrophone(id: 4)

        XCTAssertNil(manager.temporaryMicrophone)
        XCTAssertEqual(manager.getCurrentDevice(), 2)
    }

    func testExplicitAutomaticSelectionAndRelaunchClearTemporaryChoice() {
        let manager = SelectionDeviceManager(userDefaults: defaults)
        manager.selectTemporaryMicrophone(id: 1)

        let relaunched = SelectionDeviceManager(userDefaults: defaults)
        manager.resumeAutomaticMicrophoneSelection()

        XCTAssertNil(relaunched.temporaryMicrophone)
        XCTAssertEqual(relaunched.getCurrentDevice(), 2)
        XCTAssertNil(manager.temporaryMicrophone)
        XCTAssertEqual(manager.getCurrentDevice(), 2)
    }

    func testCustomPreferenceSurvivesTemporarySelectionAndDeviceReturn() {
        defaults.audioInputModeRawValue = AudioInputMode.custom.rawValue
        let manager = SelectionDeviceManager(userDefaults: defaults)
        manager.selectTemporaryMicrophone(id: 3)

        manager.updateRunningApplications([processor.bundleID])

        XCTAssertNil(manager.temporaryMicrophone)
        XCTAssertEqual(manager.getCurrentDevice(), 4)
        XCTAssertEqual(defaults.selectedAudioDeviceUID, "virtual")
        XCTAssertEqual(defaults.audioInputModeRawValue, AudioInputMode.custom.rawValue)
    }

    func testPreferredReturnWaitsForRecordingStopAndTemporaryChoiceOtherwiseSurvivesStop() {
        let manager = SelectionDeviceManager(userDefaults: defaults)
        manager.selectTemporaryMicrophone(id: 1)
        manager.recordingDidStart(deviceID: 1)
        manager.recordingDidStop()
        XCTAssertEqual(manager.temporaryMicrophone?.uid, "internal")
        manager.recordingDidStart(deviceID: 1)
        var requests = 0
        let observer = manager.notificationCenter.addObserver(
            forName: .recordingDeviceChangeRequired, object: nil, queue: nil
        ) { _ in requests += 1 }
        defer { manager.notificationCenter.removeObserver(observer) }

        manager.updateRunningApplications([processor.bundleID])

        XCTAssertEqual(requests, 0)
        XCTAssertEqual(manager.getCurrentDevice(), 1)
        XCTAssertNil(manager.temporaryMicrophone)
        manager.recordingDidStop()
        XCTAssertEqual(manager.getCurrentDevice(), 4)
    }

    func testLosingARequirementRequestsOneRecordingSwitchWithOriginalPreferencesIntact() {
        let manager = SelectionDeviceManager(userDefaults: defaults)
        manager.updateRunningApplications([processor.bundleID])
        manager.recordingDidStart(deviceID: 4)
        var requests: [RecordingDeviceChangeRequest] = []
        let observer = manager.notificationCenter.addObserver(
            forName: .recordingDeviceChangeRequired, object: nil, queue: nil
        ) { notification in
            if let request = notification.object as? RecordingDeviceChangeRequest { requests.append(request) }
        }
        defer { manager.notificationCenter.removeObserver(observer) }

        manager.updateRunningApplications([])
        manager.reconcileInputAvailability()

        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.fallbackDeviceID, 2)
        XCTAssertEqual(requests.first?.reason, .deviceUnavailable)
        XCTAssertEqual(manager.activeRecordingDeviceID, 4)
        XCTAssertEqual(defaults.selectedAudioDeviceUID, "virtual")
    }

    func testRequirementsPersistThroughReorderingAndRemovalOfAnotherEntry() throws {
        let manager = SelectionDeviceManager(userDefaults: defaults)
        var reordered = manager.prioritizedDevices.reversed().map { $0 }
        for index in reordered.indices { reordered[index].priority = index }

        manager.updatePriorities(devices: reordered)
        manager.removePrioritizedDevice(id: "wireless")

        let saved = try JSONDecoder().decode([PrioritizedDevice].self, from: XCTUnwrap(defaults.prioritizedDevicesData))
        let requirements = saved.first(where: { $0.id == "virtual" })?.requirements
        XCTAssertEqual(requirements?.microphone, source)
        XCTAssertEqual(requirements?.application, processor)
        XCTAssertEqual(SelectionDeviceManager(userDefaults: defaults).prioritizedDevices.count, 3)
    }

    func testLegacyPrioritiesDecodeWithoutRequirements() throws {
        let data = Data("[{\"id\":\"usb\",\"name\":\"USB Input\",\"priority\":0}]".utf8)

        let legacy = try JSONDecoder().decode([PrioritizedDevice].self, from: data)

        XCTAssertEqual(legacy.count, 1)
        XCTAssertNil(legacy[0].requirements)
    }

    func testPermanentSelectionClearsOverrideAndPersistsNewPreference() async {
        let manager = SelectionDeviceManager(userDefaults: defaults)
        manager.selectTemporaryMicrophone(id: 1)

        manager.selectDeviceAndSwitchToCustomMode(id: 3)
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }

        XCTAssertNil(manager.temporaryMicrophone)
        XCTAssertEqual(manager.inputMode, .custom)
        XCTAssertEqual(defaults.selectedAudioDeviceUID, "wireless")
        XCTAssertEqual(manager.getCurrentDevice(), 3)
    }

    func testSystemDefaultChangeRestoresAutomaticSelectionWithoutADeviceListChange() {
        defaults.audioInputModeRawValue = AudioInputMode.systemDefault.rawValue
        let manager = SelectionDeviceManager(userDefaults: defaults)
        manager.systemDefaultDeviceID = 2
        manager.selectTemporaryMicrophone(id: 1)

        manager.systemDefaultDeviceID = 3
        manager.reconcileInputAvailability()

        XCTAssertNil(manager.temporaryMicrophone)
        XCTAssertEqual(manager.getCurrentDevice(), 3)
        XCTAssertEqual(defaults.audioInputModeRawValue, AudioInputMode.systemDefault.rawValue)
    }
}

private final class SelectionDeviceManager: AudioDeviceManager {
    var lidClosed = false
    var systemDefaultDeviceID: AudioDeviceID? = 4
    override var isClamshellClosed: Bool { lidClosed }
    override func startMonitoring() {}
    override func loadAvailableDevices(completion: (() -> Void)? = nil) {
        availableDevices = [
            (1, "internal", "Internal Input"), (2, "usb", "USB Input"),
            (3, "wireless", "Wireless Input"), (4, "virtual", "Virtual Input"),
        ]
        completion?()
    }
    override func getSystemDefaultDevice() -> AudioDeviceID? { systemDefaultDeviceID }
    override func isInternalMicrophone(_ deviceID: AudioDeviceID) -> Bool { deviceID == 1 }
    override func getDeviceModelUID(deviceID: AudioDeviceID) -> String? { nil }
}
