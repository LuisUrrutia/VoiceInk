import AppKit
import CoreAudio
import XCTest
@testable import VoiceInk

private final class FakeOutputVolume: OutputVolumeControl {
    var values: [Float32]
    var failNextWrite = false
    /// Accepts writes without applying them, like an output that acknowledges them late.
    var defersWrites = false
    private(set) var writeCount = 0

    init(_ values: [Float32]) { self.values = values }

    func read() -> [Float32]? { values }

    func write(_ newValues: [Float32]) -> Bool {
        writeCount += 1
        if failNextWrite {
            // Only the first channel changes before the failure.
            failNextWrite = false
            values[0] = newValues[0]
            return false
        }
        if defersWrites { return true }
        // Hardware quantizes scalars.
        values = newValues.map { ($0 * 1000).rounded() / 1000 }
        return true
    }
}

private final class FakeOutputSystem: OutputVolumeSystem {
    var defaultDevice: AudioDeviceID? = 1
    var devices: [AudioDeviceID: FakeOutputVolume] = [:]

    func defaultOutputDevice() -> AudioDeviceID? { defaultDevice }
    func volumeControl(for deviceID: AudioDeviceID) -> (any OutputVolumeControl)? { devices[deviceID] }
}

private final class FakeClock {
    var now: TimeInterval = 0
}

private func assertClose(
    _ actual: [Float32], _ expected: [Float32], file: StaticString = #filePath, line: UInt = #line
) {
    XCTAssertEqual(actual.count, expected.count, file: file, line: line)
    for (value, expectedValue) in zip(actual, expected) {
        XCTAssertEqual(value, expectedValue, accuracy: 0.002, "\(actual) != \(expected)", file: file, line: line)
    }
}

@MainActor
final class OutputVolumeLoweringTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!
    private var system: FakeOutputSystem!
    private var clock: FakeClock!

    override func setUpWithError() throws {
        suite = "OutputVolumeLoweringTests.\(UUID())"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        system = FakeOutputSystem()
        clock = FakeClock()
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        defaults = nil
    }

    private func makeLowering() -> OutputVolumeLowering {
        let clock = clock!
        return OutputVolumeLowering(
            system: system,
            now: { clock.now },
            sleep: { seconds in
                clock.now += seconds
                await Task.yield()
            }
        )
    }

    private func makeMediaController(
        lowering: OutputVolumeLowering? = nil, notificationCenter: NotificationCenter = NotificationCenter()
    ) -> MediaController {
        MediaController(
            defaults: defaults, outputLowering: lowering ?? makeLowering(), notificationCenter: notificationCenter
        )
    }

    // MARK: Ramp

    func testRampLowersRelativeVolumePreservingBalanceAndSilenceThenRestores() throws {
        for original: [Float32] in [[0.3, 0.8], [0, 0.8], [0.5]] {
            for factor: Float32 in [0, 0.2, 1] {
                let device = FakeOutputVolume(original)
                let ramp = try XCTUnwrap(OutputVolumeRamp(control: device))

                ramp.retarget(factor: factor)
                ramp.advance(toElapsed: 0.5)
                assertClose(device.values, original.map { $0 * (1 + factor) / 2 })
                ramp.advance(toElapsed: 1)
                assertClose(device.values, original.map { $0 * factor })
                XCTAssertTrue(ramp.isSettled)
                XCTAssertFalse(ramp.isFinished)

                ramp.retarget(factor: nil)
                ramp.advance(toElapsed: 1)
                assertClose(device.values, original)
                XCTAssertTrue(ramp.isFinished)
            }
        }
    }

    func testInterruptedRampRestoresTheOriginalVolumes() throws {
        let device = FakeOutputVolume([0.3, 0.8])
        let ramp = try XCTUnwrap(OutputVolumeRamp(control: device))

        ramp.retarget(factor: 0)
        ramp.advance(toElapsed: 0.1)
        ramp.retarget(factor: nil)
        ramp.advance(toElapsed: 1)

        assertClose(device.values, [0.3, 0.8])
        XCTAssertTrue(ramp.isFinished)
    }

    func testVolumeChangedAfterSettlingIsLeftAlone() throws {
        let device = FakeOutputVolume([0.3, 0.8])
        let ramp = try XCTUnwrap(OutputVolumeRamp(control: device))
        ramp.retarget(factor: 0.2)
        ramp.advance(toElapsed: 1)

        device.values = [0.5, 0.5]
        ramp.retarget(factor: nil)
        ramp.advance(toElapsed: 1)
        ramp.restoreImmediately()

        XCTAssertEqual(device.values, [0.5, 0.5])
        XCTAssertTrue(ramp.isFinished)
    }

    func testLateAcknowledgementAfterSettlingIsStillRestored() throws {
        let device = FakeOutputVolume([0.5, 0.5])
        let ramp = try XCTUnwrap(OutputVolumeRamp(control: device))
        device.defersWrites = true
        ramp.retarget(factor: 0.2)
        ramp.advance(toElapsed: 1)
        XCTAssertFalse(ramp.isSettled)
        ramp.advance(toElapsed: OutputVolumeRamp.settleLimit)
        XCTAssertTrue(ramp.isSettled)

        device.defersWrites = false
        device.values = [0.1, 0.1]
        ramp.retarget(factor: nil)
        ramp.advance(toElapsed: 1)

        assertClose(device.values, [0.5, 0.5])
        XCTAssertTrue(ramp.isFinished)
    }

    func testPartialWriteRollsBackEveryChannel() throws {
        let device = FakeOutputVolume([0.3, 0.8])
        let ramp = try XCTUnwrap(OutputVolumeRamp(control: device))
        device.failNextWrite = true

        ramp.retarget(factor: 0.2)
        ramp.advance(toElapsed: 0.5)

        assertClose(device.values, [0.3, 0.8])
        XCTAssertTrue(ramp.isFinished)
    }

    func testFixedVolumeAndUnrestorableBalanceOutputsAreNotControlled() {
        let main = kAudioObjectPropertyElementMain
        let channels = CoreAudioOutputVolumeSystem.volumeElements(
            channelCount: 2, isSettable: { _ in true }, read: { _ in 0.5 }
        )
        let fixed = CoreAudioOutputVolumeSystem.volumeElements(
            channelCount: 2, isSettable: { _ in false }, read: { _ in 0.5 }
        )
        let readOnlyBalance = CoreAudioOutputVolumeSystem.volumeElements(
            channelCount: 2, isSettable: { $0 == main }, read: { _ in 0.5 }
        )
        let masterOnly = CoreAudioOutputVolumeSystem.volumeElements(
            channelCount: 2, isSettable: { $0 == main }, read: { $0 == main ? 0.5 : nil }
        )

        XCTAssertEqual(channels, [1, 2])
        XCTAssertNil(fixed)
        XCTAssertNil(readOnlyBalance)
        XCTAssertEqual(masterOnly, [main])
    }

    // MARK: Owned outputs

    func testFixedVolumeDeviceIsLeftUnchanged() {
        let lowering = makeLowering()

        XCTAssertFalse(lowering.lower(to: 0.2))
        XCTAssertFalse(lowering.ownsOutput)
    }

    func testOutputSelectedDuringRecordingIsNotLoweredAndOriginalIsRestored() async {
        let original = FakeOutputVolume([0.3, 0.8])
        let newlySelected = FakeOutputVolume([0.6, 0.6])
        system.devices = [1: original, 2: newlySelected]
        let lowering = makeLowering()

        lowering.lower(to: 0.2)
        await lowering.settle()
        system.defaultDevice = 2
        await lowering.restore()

        assertClose(original.values, [0.3, 0.8])
        XCTAssertEqual(newlySelected.values, [0.6, 0.6])
        XCTAssertEqual(newlySelected.writeCount, 0)
        XCTAssertFalse(lowering.ownsOutput)
    }

    // MARK: Recording sessions

    func testOverlappingSessionsKeepTheFirstSessionsOriginalVolumes() async {
        let device = FakeOutputVolume([0.3, 0.8])
        system.devices = [1: device]
        let lowering = makeLowering()
        let controller = makeMediaController(lowering: lowering)
        controller.recordingOutputBehavior = .lower
        controller.audioResumptionDelay = 1
        let first = UUID()
        controller.beginRecordingSession(sessionID: first)
        controller.lowerSystemAudio(sessionID: first)
        await lowering.settle()

        let delayedRestoration = Task { await controller.restoreSystemAudio(sessionID: first) }
        let second = UUID()
        controller.beginRecordingSession(sessionID: second)
        delayedRestoration.cancel()
        await delayedRestoration.value
        controller.lowerSystemAudio(sessionID: second)
        await lowering.settle()
        assertClose(device.values, [0.06, 0.16])

        controller.audioResumptionDelay = 0
        await controller.restoreSystemAudio(sessionID: second)
        await controller.waitForLoweredOutputRestoration()
        assertClose(device.values, [0.3, 0.8])
    }

    func testStopToneWaitsForLoweredOutputRestoration() async {
        let device = FakeOutputVolume([0.4, 0.4])
        system.devices = [1: device]
        let lowering = makeLowering()
        let controller = makeMediaController(lowering: lowering)
        controller.recordingOutputBehavior = .lower
        let session = UUID()
        controller.beginRecordingSession(sessionID: session)
        controller.lowerSystemAudio(sessionID: session)
        await lowering.settle()

        await controller.restoreSystemAudio(sessionID: session)
        XCTAssertTrue(controller.isRestoringLoweredOutput)
        await controller.waitForLoweredOutputRestoration()

        assertClose(device.values, [0.4, 0.4])
        XCTAssertFalse(controller.isRestoringLoweredOutput)
    }

    func testLevelIsReadWhenTheNextRecordingStarts() async {
        let device = FakeOutputVolume([0.5, 0.5])
        system.devices = [1: device]
        let lowering = makeLowering()
        let controller = makeMediaController(lowering: lowering)
        controller.recordingOutputBehavior = .lower
        let session = UUID()
        controller.beginRecordingSession(sessionID: session)
        controller.lowerSystemAudio(sessionID: session)
        await lowering.settle()

        controller.systemAudioLoweringLevel = 0.5
        await lowering.settle()
        assertClose(device.values, [0.1, 0.1])

        await controller.restoreSystemAudio(sessionID: session)
        await controller.waitForLoweredOutputRestoration()
        let next = UUID()
        controller.beginRecordingSession(sessionID: next)
        controller.lowerSystemAudio(sessionID: next)
        await lowering.settle()
        assertClose(device.values, [0.25, 0.25])
    }

    func testOtherBehaviorsDoNotLowerOutput() async {
        let device = FakeOutputVolume([0.5, 0.5])
        system.devices = [1: device]
        let controller = makeMediaController()
        let session = UUID()
        controller.beginRecordingSession(sessionID: session)

        for behavior: RecordingOutputAudioBehavior in [.unchanged, .mute] {
            controller.recordingOutputBehavior = behavior
            XCTAssertFalse(controller.lowerSystemAudio(sessionID: session))
        }
        XCTAssertEqual(device.writeCount, 0)
    }

    func testOrderlyShutdownRestoresImmediately() async {
        let device = FakeOutputVolume([0.3, 0.8])
        system.devices = [1: device]
        let lowering = makeLowering()
        let center = NotificationCenter()
        let controller = makeMediaController(lowering: lowering, notificationCenter: center)
        controller.recordingOutputBehavior = .lower
        let session = UUID()
        controller.beginRecordingSession(sessionID: session)
        controller.lowerSystemAudio(sessionID: session)
        await lowering.settle()

        // The app exits right after this notification, so restoration must finish during its delivery.
        center.post(name: NSApplication.willTerminateNotification, object: nil)

        XCTAssertEqual(device.values, [0.3, 0.8])
        XCTAssertFalse(lowering.ownsOutput)
    }

    // MARK: Preferences

    func testMuteAndLowerAreExclusiveAndPersisted() {
        let controller = makeMediaController()

        controller.recordingOutputBehavior = .lower
        XCTAssertTrue(defaults.bool(forKey: MediaController.loweringKey))
        XCTAssertFalse(defaults.bool(forKey: MediaController.muteKey))

        controller.isSystemMuteEnabled = true
        XCTAssertEqual(controller.recordingOutputBehavior, .mute)
        XCTAssertFalse(defaults.bool(forKey: MediaController.loweringKey))

        controller.recordingOutputBehavior = .unchanged
        XCTAssertFalse(defaults.bool(forKey: MediaController.muteKey))
        XCTAssertFalse(defaults.bool(forKey: MediaController.loweringKey))
    }

    func testEditedConfigurationEnablingBothPrefersMuteAndLevelIsBounded() {
        defaults.set(true, forKey: MediaController.muteKey)
        defaults.set(true, forKey: MediaController.loweringKey)
        defaults.set(1.5, forKey: MediaController.loweringLevelKey)

        let controller = makeMediaController()

        XCTAssertEqual(controller.recordingOutputBehavior, .mute)
        XCTAssertEqual(controller.systemAudioLoweringLevel, 1)
        controller.systemAudioLoweringLevel = .nan
        XCTAssertEqual(controller.systemAudioLoweringLevel, MediaController.defaultLoweringLevel)
        controller.systemAudioLoweringLevel = -1
        XCTAssertEqual(defaults.double(forKey: MediaController.loweringLevelKey), 0)
    }

    func testLevelDefaultsToTwentyPercent() {
        XCTAssertEqual(makeMediaController().systemAudioLoweringLevel, 0.2)
    }

    func testConfigurationRoundTripsTheLowerChoiceAndLevel() throws {
        defaults.set(false, forKey: MediaController.muteKey)
        defaults.set(true, forKey: MediaController.loweringKey)
        defaults.set(0.35, forKey: MediaController.loweringLevelKey)

        let captured = try ConfigurationPreferences.capture(from: defaults)
        let restoredSuite = "OutputVolumeLoweringTests.restored.\(UUID())"
        let restoredDefaults = try XCTUnwrap(UserDefaults(suiteName: restoredSuite))
        defer { restoredDefaults.removePersistentDomain(forName: restoredSuite) }
        try ConfigurationPreferences.apply(captured, to: restoredDefaults)
        let controller = MediaController(defaults: restoredDefaults, outputLowering: makeLowering())

        XCTAssertEqual(captured[MediaController.loweringKey], .bool(true))
        XCTAssertEqual(captured[MediaController.loweringLevelKey], .number(0.35))
        XCTAssertEqual(controller.recordingOutputBehavior, .lower)
        XCTAssertEqual(controller.systemAudioLoweringLevel, 0.35)
    }

    func testGeneralBackupsRestoreTheChoiceAndKeepCurrentValuesForMissingFields() throws {
        func backup(_ json: String) throws -> GeneralBackup {
            try JSONDecoder().decode(GeneralBackup.self, from: Data(json.utf8))
        }

        let legacyMute = try backup(#"{"isSystemMuteEnabled":true}"#)
        let legacyUnmuted = try backup(#"{"isSystemMuteEnabled":false}"#)
        let lowered = try backup(
            #"{"isSystemMuteEnabled":false,"isSystemAudioLoweringEnabled":true,"systemAudioLoweringLevel":0.4}"#
        )

        XCTAssertEqual(legacyMute.recordingOutputBehavior(restoring: .lower), .mute)
        XCTAssertEqual(legacyUnmuted.recordingOutputBehavior(restoring: .lower), .lower)
        XCTAssertEqual(legacyUnmuted.recordingOutputBehavior(restoring: .mute), .unchanged)
        XCTAssertEqual(lowered.recordingOutputBehavior(restoring: .mute), .lower)
        XCTAssertEqual(lowered.systemAudioLoweringLevel, 0.4)
    }
}
