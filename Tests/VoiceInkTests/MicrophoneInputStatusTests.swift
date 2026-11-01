import Combine
import CoreAudio
import XCTest
import os

@testable import VoiceInk

@MainActor final class MicrophoneInputStatusTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "MicrophoneInputStatusTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.audioInputModeRawValue = AudioInputMode.custom.rawValue
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func testMissingCustomMicrophoneNamesItsStandInAndStaysListedAsNotConnected() {
        saveCustomMicrophone(uid: "shure", name: "SHURE MV7")
        let manager = StatusDeviceManager(userDefaults: defaults)

        let status = manager.microphoneInputStatus

        XCTAssertEqual(status.inputName, "MacBook Pro Microphone")
        XCTAssertEqual(status.note, .notConnected(savedName: "SHURE MV7"))
        XCTAssertEqual(status.message, "SHURE MV7 isn't connected; using MacBook Pro Microphone")
        XCTAssertEqual(notConnectedNames(manager), ["SHURE MV7"])
        XCTAssertEqual(defaults.selectedAudioDeviceUID, "shure")
    }

    func testMissingMicrophoneWithoutARecordedNameAndWithoutAStandIn() {
        defaults.selectedAudioDeviceUID = "legacy"
        let manager = StatusDeviceManager(userDefaults: defaults)
        XCTAssertEqual(
            manager.microphoneInputStatus.message, "The selected microphone isn't connected; using MacBook Pro Microphone"
        )
        XCTAssertEqual(notConnectedNames(manager), [String(localized: "Selected Microphone")])

        saveCustomMicrophone(uid: "shure", name: "SHURE MV7")
        manager.connected = []
        manager.loadAvailableDevices()

        XCTAssertNil(manager.microphoneInputStatus.inputName)
        XCTAssertEqual(
            manager.microphoneInputStatus.message, "SHURE MV7 isn't connected, and no other microphone is available"
        )
    }

    func testPriorityEntriesRankedAboveTheInputInUseAreReportedAndLowerOnesAreNot() {
        defaults.audioInputModeRawValue = AudioInputMode.prioritized.rawValue
        defaults.prioritizedDevicesData = try! JSONEncoder().encode([
            PrioritizedDevice(id: "shure", name: "SHURE MV7", priority: 0),
            PrioritizedDevice(id: "usb", name: "USB Microphone", priority: 1),
            PrioritizedDevice(id: "rode", name: "RØDE NT-USB", priority: 2),
        ])
        let manager = StatusDeviceManager(userDefaults: defaults)

        XCTAssertEqual(manager.getCurrentDevice(), StatusDeviceManager.usbID)
        XCTAssertEqual(manager.microphoneInputStatus.message, "SHURE MV7 isn't connected; using USB Microphone")
        XCTAssertEqual(notConnectedNames(manager), ["SHURE MV7", "RØDE NT-USB"])

        manager.connected.append(StatusDeviceManager.shure)
        manager.loadAvailableDevices()

        XCTAssertEqual(manager.getCurrentDevice(), StatusDeviceManager.shureID)
        XCTAssertNil(manager.microphoneInputStatus.note)
        XCTAssertEqual(notConnectedNames(manager), ["RØDE NT-USB"])
    }

    func testClosedLidNamesTheStandInForTheInternalMicrophone() {
        saveCustomMicrophone(uid: "internal", name: "MacBook Pro Microphone")
        let manager = StatusDeviceManager(userDefaults: defaults)

        manager.lidClosed = true
        manager.handleClamshellChange(isClosed: true)

        XCTAssertEqual(manager.microphoneInputStatus.message, "The lid is closed, so VoiceInk listens to USB Microphone")

        manager.connected.removeAll { $0.id == StatusDeviceManager.usbID }
        manager.loadAvailableDevices()
        XCTAssertNil(manager.microphoneInputStatus.inputName)
        XCTAssertEqual(manager.microphoneInputStatus.message, "The lid is closed, and no other microphone is available")
    }

    func testBluetoothSubstitutionIsTheOnlyNoteForABluetoothSystemDefault() {
        defaults.audioInputModeRawValue = AudioInputMode.systemDefault.rawValue
        let manager = StatusDeviceManager(userDefaults: defaults)
        manager.connected.append(StatusDeviceManager.airPods)
        manager.systemDefaultDeviceID = StatusDeviceManager.airPodsID
        manager.loadAvailableDevices()
        XCTAssertEqual(
            manager.microphoneInputStatus.message, "AirPods is Bluetooth, so VoiceInk listens to MacBook Pro Microphone"
        )

        manager.lidClosed = true
        manager.handleClamshellChange(isClosed: true)

        XCTAssertEqual(manager.microphoneInputStatus.inputName, "USB Microphone")
        XCTAssertEqual(manager.microphoneInputStatus.message, "AirPods is Bluetooth, so VoiceInk listens to USB Microphone")
    }

    func testMissingSavedMicrophoneTakesPrecedenceOverBluetoothRanking() {
        saveCustomMicrophone(uid: "shure", name: "SHURE MV7")
        let manager = StatusDeviceManager(userDefaults: defaults)
        manager.connected = [StatusDeviceManager.airPods, StatusDeviceManager.usb]
        manager.systemDefaultDeviceID = StatusDeviceManager.airPodsID

        manager.loadAvailableDevices()

        XCTAssertEqual(manager.microphoneInputStatus.message, "SHURE MV7 isn't connected; using USB Microphone")
    }

    func testTemporarySelectionShowsNoSavedSettingNote() {
        saveCustomMicrophone(uid: "shure", name: "SHURE MV7")
        let manager = StatusDeviceManager(userDefaults: defaults)

        manager.selectTemporaryMicrophone(id: StatusDeviceManager.usbID)

        XCTAssertEqual(manager.microphoneInputStatus, MicrophoneInputStatus(
            inputName: "USB Microphone", standInName: "USB Microphone", note: nil,
            notConnected: [SavedMicrophone(id: "shure", name: "SHURE MV7")]
        ))
    }

    func testReturningMicrophoneIsUsedAgainWhileIdleWithoutChangingTheSetting() {
        saveCustomMicrophone(uid: "shure", name: "SHURE MV7")
        let manager = StatusDeviceManager(userDefaults: defaults)
        XCTAssertEqual(manager.getCurrentDevice(), StatusDeviceManager.internalID)

        manager.connected.append(StatusDeviceManager.shure)
        manager.loadAvailableDevices()

        XCTAssertEqual(manager.getCurrentDevice(), StatusDeviceManager.shureID)
        XCTAssertEqual(manager.selectedDeviceID, StatusDeviceManager.shureID)
        XCTAssertEqual(
            manager.microphoneInputStatus,
            MicrophoneInputStatus(inputName: "SHURE MV7", standInName: "SHURE MV7", note: nil)
        )
        XCTAssertEqual(defaults.audioInputModeRawValue, AudioInputMode.custom.rawValue)
        XCTAssertEqual(defaults.selectedAudioDeviceUID, "shure")
    }

    func testReturningMicrophoneWaitsForTheRecordingToStop() {
        saveCustomMicrophone(uid: "shure", name: "SHURE MV7")
        let manager = StatusDeviceManager(userDefaults: defaults)
        var changeRequests = 0
        let observer = manager.notificationCenter.addObserver(
            forName: .recordingDeviceChangeRequired, object: nil, queue: nil
        ) { _ in changeRequests += 1 }
        defer { manager.notificationCenter.removeObserver(observer) }
        manager.recordingDidStart(deviceID: StatusDeviceManager.internalID)

        manager.connected.append(StatusDeviceManager.shure)
        manager.loadAvailableDevices()

        XCTAssertEqual(manager.getCurrentDevice(), StatusDeviceManager.internalID)
        XCTAssertEqual(manager.microphoneInputStatus.inputName, "MacBook Pro Microphone")
        XCTAssertEqual(
            manager.microphoneInputStatus.message, "VoiceInk switches to SHURE MV7 after this recording"
        )
        XCTAssertEqual(changeRequests, 0)

        manager.recordingDidStop()

        XCTAssertEqual(manager.getCurrentDevice(), StatusDeviceManager.shureID)
        XCTAssertNil(manager.microphoneInputStatus.note)
        XCTAssertEqual(defaults.selectedAudioDeviceUID, "shure")
    }

    func testChoosingAMicrophoneRemembersItsNameAndLegacySelectionsLearnIt() async {
        let manager = StatusDeviceManager(userDefaults: defaults)
        manager.selectDeviceAndSwitchToCustomMode(id: StatusDeviceManager.usbID)
        await waitUntil { self.defaults.selectedAudioDeviceName != nil }
        XCTAssertEqual(defaults.selectedAudioDeviceName, "USB Microphone")

        defaults.audioDeviceNamesByUID = [:]
        manager.reconcileInputAvailability()

        XCTAssertEqual(defaults.selectedAudioDeviceName, "USB Microphone")
    }

    func testClosedLidDuringARecordingWithoutAnotherInputSaysNoneIsAvailable() {
        saveCustomMicrophone(uid: "internal", name: "MacBook Pro Microphone")
        let manager = StatusDeviceManager(userDefaults: defaults)
        manager.recordingDidStart(deviceID: StatusDeviceManager.internalID)
        manager.connected.removeAll { $0.id == StatusDeviceManager.usbID }
        manager.availableDevices = manager.connected

        manager.lidClosed = true
        manager.handleClamshellChange(isClosed: true)

        let status = manager.microphoneInputStatus
        XCTAssertEqual(status.inputName, "MacBook Pro Microphone")
        XCTAssertNil(status.standInName)
        XCTAssertEqual(status.message, "The lid is closed, and no other microphone is available")
    }

    func testClosedLidDuringARecordingNamesTheUsableStandIn() {
        saveCustomMicrophone(uid: "internal", name: "MacBook Pro Microphone")
        let manager = StatusDeviceManager(userDefaults: defaults)
        manager.recordingDidStart(deviceID: StatusDeviceManager.internalID)

        manager.lidClosed = true
        manager.handleClamshellChange(isClosed: true)

        XCTAssertTrue(manager.recordingDeviceSession.isDeviceChangePending)
        XCTAssertEqual(manager.microphoneInputStatus.message, "The lid is closed, so VoiceInk listens to USB Microphone")
    }

    func testStatusFromPrefetchedPropertiesQueriesNoCoreAudio() {
        defaults.audioInputModeRawValue = AudioInputMode.systemDefault.rawValue
        let manager = StatusDeviceManager(userDefaults: defaults)
        manager.connected.append(StatusDeviceManager.airPods)
        manager.systemDefaultDeviceID = StatusDeviceManager.airPodsID
        manager.loadAvailableDevices()
        let properties = manager.fetchRecordingDeviceProperties(for: manager.availableDevices.map(\.id))
        manager.resetQueries()

        let status = manager.microphoneInputStatus(using: properties)

        XCTAssertEqual(status.message, "AirPods is Bluetooth, so VoiceInk listens to MacBook Pro Microphone")
        XCTAssertEqual(manager.queries.count, 0)
    }

    func testMonitorFetchesOffTheMainThreadAndRefreshesOnDeviceChanges() async {
        saveCustomMicrophone(uid: "shure", name: "SHURE MV7")
        let manager = StatusDeviceManager(userDefaults: defaults)
        manager.resetQueries()
        let monitor = MicrophoneInputStatusMonitor(devices: manager)
        await waitUntil { monitor.status != nil }
        XCTAssertEqual(monitor.status?.message, "SHURE MV7 isn't connected; using MacBook Pro Microphone")
        XCTAssertEqual(monitor.status?.notConnected, [SavedMicrophone(id: "shure", name: "SHURE MV7")])
        XCTAssertFalse(manager.queries.isEmpty)
        XCTAssertFalse(manager.queries.contains(true), "CoreAudio was queried on the main thread")

        manager.connected.append(StatusDeviceManager.shure)
        manager.loadAvailableDevices()
        manager.resetQueries()
        await waitUntil { monitor.status?.inputName == "SHURE MV7" }

        XCTAssertEqual(monitor.status, MicrophoneInputStatus(inputName: "SHURE MV7", standInName: "SHURE MV7", note: nil))
        XCTAssertFalse(manager.queries.contains(true), "CoreAudio was queried on the main thread")
    }

    func testUIDOnlyConfigurationUpdateNeverShowsThePreviousMicrophonesName() throws {
        saveCustomMicrophone(uid: "usb", name: "USB Microphone")
        XCTAssertEqual(defaults.selectedAudioDeviceName, "USB Microphone")

        try ConfigurationPreferences.apply(["selectedAudioDeviceUID": .string("missing-mic")], to: defaults)
        let manager = StatusDeviceManager(userDefaults: defaults)

        XCTAssertNil(defaults.selectedAudioDeviceName)
        XCTAssertEqual(manager.microphoneInputStatus.note, .notConnected(savedName: nil))
        XCTAssertEqual(
            manager.microphoneInputStatus.message, "The selected microphone isn't connected; using MacBook Pro Microphone"
        )
        XCTAssertEqual(
            manager.microphoneInputStatus.notConnected,
            [SavedMicrophone(id: "missing-mic", name: String(localized: "Selected Microphone"))]
        )
    }

    func testIdenticallyNamedMissingMicrophonesKeepDistinctIdentities() {
        defaults.audioInputModeRawValue = AudioInputMode.prioritized.rawValue
        defaults.prioritizedDevicesData = try! JSONEncoder().encode([
            PrioritizedDevice(id: "usb-a", name: "USB Audio", priority: 0),
            PrioritizedDevice(id: "usb-b", name: "USB Audio", priority: 1),
        ])

        let notConnected = StatusDeviceManager(userDefaults: defaults).microphoneInputStatus.notConnected

        XCTAssertEqual(notConnected.map(\.id), ["usb-a", "usb-b"])
        XCTAssertEqual(notConnected.map(\.name), ["USB Audio", "USB Audio"])
    }

    private func saveCustomMicrophone(uid: String, name: String) {
        defaults.selectedAudioDeviceUID = uid
        defaults.audioDeviceNamesByUID[uid] = name
    }

    private func notConnectedNames(_ manager: AudioDeviceManager) -> [String] {
        manager.microphoneInputStatus.notConnected.map(\.name)
    }

    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<200 where !condition() {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
}

@MainActor final class MicrophoneLevelMeterTests: XCTestCase {
    func testNoReadingOrAStaleMeterIsIdle() {
        var meter = MicrophoneLevelMeter()

        XCTAssertFalse(meter.observe(nil, at: ms(0)))
        XCTAssertFalse(meter.observe(reading(-10, capturedThrough: 0), at: ms(260)))
        XCTAssertFalse(meter.observe(reading(-10, capturedThrough: 0), at: ms(1_000)))

        XCTAssertEqual(meter.display, MicrophoneLevelMeter.Display(isReceiving: false, step: 0))
    }

    func testAudioThatAdvancedBeforeAStopIsIdleWhenFirstPolledLate() {
        var meter = MicrophoneLevelMeter()
        XCTAssertTrue(meter.observe(reading(-10, capturedThrough: 0), at: ms(0)))

        XCTAssertTrue(meter.observe(reading(-10, capturedThrough: 1), at: ms(252)))
        XCTAssertEqual(meter.display, MicrophoneLevelMeter.Display(isReceiving: false, step: 0))

        var delayed = MicrophoneLevelMeter()
        XCTAssertFalse(delayed.observe(reading(-10, capturedThrough: 1), at: ms(1_000)))
    }

    func testDeliveredAudioIsShownInQuantizedStepsAndBecomesIdleAfterAQuarterSecond() {
        var meter = MicrophoneLevelMeter()

        XCTAssertTrue(meter.observe(reading(-10, capturedThrough: 33), at: ms(33)))
        XCTAssertEqual(meter.display, MicrophoneLevelMeter.Display(isReceiving: true, step: 6))
        XCTAssertTrue(meter.isMoving)

        XCTAssertTrue(meter.observe(reading(-120, capturedThrough: 66), at: ms(66)))
        XCTAssertEqual(meter.display.step, 5, "a falling level steps down gradually")

        _ = meter.observe(reading(-120, capturedThrough: 66), at: ms(316))
        XCTAssertTrue(meter.display.isReceiving, "an endpoint 250 ms old is still fresh")
        XCTAssertTrue(meter.observe(reading(-120, capturedThrough: 66), at: ms(317)))
        XCTAssertEqual(meter.display, MicrophoneLevelMeter.Display(isReceiving: false, step: 0))
    }

    func testQuietRoomNoiseNeverChangesTheDisplayAfterItStartsReceiving() {
        var meter = MicrophoneLevelMeter()
        XCTAssertTrue(meter.observe(reading(-66.6, capturedThrough: 0), at: ms(0)))

        var changes = 0
        for time in stride(from: 250, through: 10_000, by: 250) {
            let peak: Float = time.isMultiple(of: 500) ? -70 : -60
            if meter.observe(reading(peak, capturedThrough: time - 10), at: ms(time)) { changes += 1 }
        }

        XCTAssertEqual(changes, 0)
        XCTAssertEqual(meter.display, MicrophoneLevelMeter.Display(isReceiving: true, step: 0))
        XCTAssertFalse(meter.isMoving)
    }

    func testMonitorPublishesOnlyStepChangesAndReadsQuietBarsFourTimesASecond() {
        var current: MicrophoneLevelReading? = reading(-66.6, capturedThrough: 0)
        var clock = ms(0)
        let monitor = MicrophoneLevelMonitor(read: { current }, now: { clock })
        var publishes = 0
        let subscription = monitor.objectWillChange.sink { publishes += 1 }
        defer { subscription.cancel() }

        XCTAssertEqual(monitor.tick(), MicrophoneLevelMonitor.restingInterval)
        for time in stride(from: 250, through: 5_000, by: 250) {
            clock = ms(time)
            current = reading(-66.6, capturedThrough: time)
            XCTAssertEqual(monitor.tick(), MicrophoneLevelMonitor.restingInterval)
        }
        XCTAssertEqual(publishes, 1, "only the change from idle to receiving")

        clock = ms(5_033)
        current = reading(-12, capturedThrough: 5_033)
        XCTAssertEqual(monitor.tick(), MicrophoneLevelMonitor.movingInterval)
        XCTAssertEqual(publishes, 2)

        monitor.reducesMotion = true
        clock = ms(5_066)
        current = reading(-12, capturedThrough: 5_066)
        XCTAssertEqual(monitor.tick(), MicrophoneLevelMonitor.restingInterval)
        XCTAssertEqual(publishes, 2, "an unchanged step publishes nothing")

        monitor.stop()
        XCTAssertEqual(monitor.display, MicrophoneLevelMeter.Display())
    }

    func testRecorderLevelReadingNeverOpensOrPreparesTheMicrophone() async throws {
        let suiteName = "MicrophoneLevelMeterTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let hardware = MeterOnlyHardware()
        let recorder = Recorder(
            hardware: hardware, deviceManager: StatusDeviceManager(userDefaults: defaults), defaults: defaults,
            isMicrophoneAuthorized: { true }
        )
        try await Task.sleep(for: .milliseconds(50))
        let eventsBefore = hardware.events
        let monitor = MicrophoneLevelMonitor(recorder: recorder)

        monitor.start()
        try await Task.sleep(for: .milliseconds(300))
        monitor.stop()

        let opening: Set = ["prepare", "start", "switch", "idle-start"]
        XCTAssertEqual(hardware.events.dropFirst(eventsBefore.count).filter(opening.contains), [])
        XCTAssertGreaterThan(hardware.meterReads, 0)
        XCTAssertFalse(monitor.display.isReceiving)

        recorder.recorder = nil
        XCTAssertNil(recorder.inputLevelReading())
        XCTAssertNil(recorder.recorder)
    }

    private func reading(_ peak: Float, capturedThrough milliseconds: Int) -> MicrophoneLevelReading {
        MicrophoneLevelReading(peakDBFS: peak, capturedThroughNanoseconds: ms(milliseconds))
    }

    private func ms(_ milliseconds: Int) -> UInt64 { 1_000_000_000 + UInt64(milliseconds) * 1_000_000 }
}

private final class StatusDeviceManager: AudioDeviceManager {
    typealias Device = (id: AudioDeviceID, uid: String, name: String)
    static let internalID: AudioDeviceID = 1
    static let usbID: AudioDeviceID = 2
    static let shureID: AudioDeviceID = 3
    static let airPodsID: AudioDeviceID = 4
    static let usb: Device = (usbID, "usb", "USB Microphone")
    static let shure: Device = (shureID, "shure", "SHURE MV7")
    static let airPods: Device = (airPodsID, "airpods", "AirPods")

    var connected: [Device] = [(internalID, "internal", "MacBook Pro Microphone"), usb]
    var lidClosed = false
    var systemDefaultDeviceID: AudioDeviceID? = internalID
    override var isClamshellClosed: Bool { lidClosed }

    init(userDefaults: UserDefaults) {
        super.init(userDefaults: userDefaults, notificationCenter: NotificationCenter())
    }

    override func startMonitoring() {}
    override func loadAvailableDevices(completion: (() -> Void)? = nil) {
        availableDevices = connected
        reconcileInputAvailability()
        completion?()
    }
    /// Whether each CoreAudio-backed query ran on the main thread.
    private let queryLog = OSAllocatedUnfairLock(initialState: [Bool]())
    var queries: [Bool] { queryLog.withLock { $0 } }
    func resetQueries() { queryLog.withLock { $0.removeAll() } }
    private func logQuery() { queryLog.withLock { $0.append(Thread.isMainThread) } }

    override func getSystemDefaultDevice() -> AudioDeviceID? {
        logQuery()
        return systemDefaultDeviceID
    }
    override func isInternalMicrophone(_ deviceID: AudioDeviceID) -> Bool {
        logQuery()
        return deviceID == Self.internalID
    }
    override func getDeviceModelUID(deviceID: AudioDeviceID) -> String? {
        logQuery()
        return nil
    }
    override func inputTransport(_ deviceID: AudioDeviceID) -> AudioInputTransport {
        logQuery()
        switch deviceID {
        case Self.internalID: return .builtIn
        case Self.airPodsID: return .bluetooth
        default: return .other
        }
    }
}

/// Records every hardware call; its meter is stale because nothing captures.
private final class MeterOnlyHardware: RecordingHardware, @unchecked Sendable {
    private struct State {
        var events: [String] = []
        var meterReads = 0
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    var onAudioChunk: ((Data) -> Void)?
    var averagePower: Float { -160 }
    var peakPower: Float {
        state.withLock { $0.meterReads += 1 }
        return -12
    }
    var capturedThroughNanoseconds: UInt64? { 42 }
    var events: [String] { state.withLock { $0.events } }
    var meterReads: Int { state.withLock { $0.meterReads } }

    private func log(_ event: String) { state.withLock { $0.events.append(event) } }

    func prepare(deviceID: AudioDeviceID, selectedInputChannels: [UInt32]?) throws { log("prepare") }
    func startRecording(toOutputFile url: URL, deviceID: AudioDeviceID, selectedInputChannels: [UInt32]?) throws {
        log("start")
    }
    func stopRecording() { log("stop") }
    func switchDevice(to deviceID: AudioDeviceID, selectedInputChannels: [UInt32]?) throws { log("switch") }
    func invalidatePreparation() { log("invalidate") }
    func teardown() { log("teardown") }
    func startIdleCapture(deviceID: AudioDeviceID, selectedInputChannels: [UInt32]?) throws { log("idle-start") }
    func stopIdleCapture() { log("idle-stop") }
}
