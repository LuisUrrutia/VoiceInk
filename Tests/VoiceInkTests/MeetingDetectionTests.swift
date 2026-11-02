import XCTest

@testable import VoiceInk

@MainActor final class MeetingDetectionTests: XCTestCase {
    private var root: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("MeetingDetectionTests-\(UUID().uuidString)")
        suiteName = "MeetingDetectionTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        Labs.setEnabled(true, for: .meetings, in: defaults)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
        defaults.removePersistentDomain(forName: suiteName)
    }

    // MARK: - Providers

    func testNativeCallAppsAndBrowsersAreRecognizedThroughTheirProcesses() {
        XCTAssertEqual(MeetingProvider.nativeProvider(forBundleIDs: ["us.zoom.caphost", "us.zoom.xos"]), .zoom)
        XCTAssertEqual(MeetingProvider.nativeProvider(forBundleIDs: ["com.microsoft.teams2.helper"]), .teams)
        XCTAssertEqual(MeetingProvider.nativeProvider(forBundleIDs: ["com.tinyspeck.slackmacgap.helper"]), .slack)
        XCTAssertEqual(MeetingProvider.nativeProvider(forBundleIDs: ["com.apple.avconferenced"]), .facetime)
        XCTAssertNil(MeetingProvider.nativeProvider(forBundleIDs: ["com.apple.WebKit.GPU", "com.apple.Safari"]))
        XCTAssertEqual(MeetingProvider.browser(forBundleIDs: ["com.apple.WebKit.GPU", "com.apple.Safari"]), .safari)
        XCTAssertEqual(MeetingProvider.browser(forBundleIDs: ["com.google.Chrome.helper"]), .chrome)
        XCTAssertNil(MeetingProvider.browser(forBundleIDs: ["com.google.Chromecast"]))
        XCTAssertNil(MeetingProvider.nativeProvider(forBundleIDs: ["com.prakashjoshipax.VoiceInk"]))
    }

    func testSafarisWebKitProcessIsAttributedBySafarisNameOnly() {
        let safari = CoreAudioInputProcessListing.withCanonicalHost(["com.apple.WebKit.GPU"], localizedName: "Safari Graphics and Media")
        let other = CoreAudioInputProcessListing.withCanonicalHost(["com.apple.WebKit.GPU"], localizedName: "Mail Graphics and Media")

        XCTAssertEqual(MeetingProvider.browser(forBundleIDs: safari), .safari)
        XCTAssertNil(MeetingProvider.browser(forBundleIDs: other))
    }

    func testOnlyMeetCallPagesCount() {
        XCTAssertTrue(MeetingProvider.isMeetCall("https://meet.google.com/abc-defg-hij"))
        XCTAssertTrue(MeetingProvider.isMeetCall("https://meet.google.com/abc-defg-hij?authuser=1"))
        XCTAssertFalse(MeetingProvider.isMeetCall("https://meet.google.com/"))
        XCTAssertFalse(MeetingProvider.isMeetCall("https://meet.google.com/landing"))
        XCTAssertFalse(MeetingProvider.isMeetCall("https://meet.google.com/new"))
        XCTAssertFalse(MeetingProvider.isMeetCall("https://calendar.google.com/meet.google.com/abc"))
    }

    // MARK: - Detector

    func testACallStartsAfterTwoSecondsAndEndsAfterThreeOff() {
        var detector = CallDetector()

        XCTAssertEqual(detector.observe([.zoom], at: 0), [])
        XCTAssertEqual(detector.observe([.zoom], at: 1.9), [])
        XCTAssertEqual(detector.observe([.zoom], at: 2), [.started(.zoom)])
        XCTAssertEqual(detector.observe([.zoom], at: 3), [])
        XCTAssertEqual(detector.observe([], at: 5), [])
        XCTAssertEqual(detector.observe([], at: 6), [.ended(.zoom)])
        XCTAssertEqual(detector.observe([], at: 7), [])
    }

    func testABriefMicrophoneUseIsNoCall() {
        var detector = CallDetector()

        XCTAssertEqual(detector.observe([.slack], at: 0), [])
        XCTAssertEqual(detector.observe([], at: 1), [])
        XCTAssertEqual(detector.observe([.slack], at: 2), [])
        XCTAssertEqual(detector.observe([.slack], at: 3.5), [])
        XCTAssertEqual(detector.observe([.slack], at: 4), [.started(.slack)])
    }

    func testALongObservationGapRestartsPendingRuns() {
        var detector = CallDetector()

        XCTAssertEqual(detector.observe([.teams], at: 0), [])
        XCTAssertEqual(detector.observe([.teams], at: 30), [])
        XCTAssertEqual(detector.observe([.teams], at: 32), [.started(.teams)])
    }

    func testASnoozeLastsUntilTheProviderIsOffTheMicrophoneForAMinute() {
        var detector = CallDetector()
        _ = detector.observe([.zoom], at: 0)
        _ = detector.observe([.zoom], at: 2)
        detector.snooze(.zoom)

        _ = detector.observe([], at: 10)
        _ = detector.observe([.zoom], at: 20)
        XCTAssertTrue(detector.isSnoozed(.zoom))
        _ = detector.observe([], at: 30)
        _ = detector.observe([], at: 89)
        XCTAssertTrue(detector.isSnoozed(.zoom))
        _ = detector.observe([], at: 90)

        XCTAssertFalse(detector.isSnoozed(.zoom))
    }

    // MARK: - Policies

    func testPoliciesDefaultToAskAndRoundTripThroughBackups() {
        XCTAssertEqual(MeetingSettings.policy(for: .zoom, in: defaults), .ask)
        MeetingSettings.setPolicy(.alwaysRecord, for: .zoom, in: defaults)
        MeetingSettings.setPolicy(.neverOffer, for: .facetime, in: defaults)
        defaults.set(false, forKey: MeetingSettings.detectsCallsKey)
        let backup = MeetingSettings.Backup.capture(from: defaults)
        let restoredName = "\(suiteName!).restored"
        let restored = UserDefaults(suiteName: restoredName)!
        defer { restored.removePersistentDomain(forName: restoredName) }

        backup.restore(in: restored)
        MeetingSettings.Backup(providerPolicies: ["zoom": "bogus", "skype": "always_record"]).restore(in: restored)

        XCTAssertEqual(MeetingSettings.policy(for: .zoom, in: restored), .alwaysRecord)
        XCTAssertEqual(MeetingSettings.policy(for: .facetime, in: restored), .neverOffer)
        XCTAssertEqual(MeetingSettings.policy(for: .meet, in: restored), .ask)
        XCTAssertFalse(MeetingSettings.detectsCalls(in: restored))
        MeetingSettings.setPolicy(.ask, for: .zoom, in: restored)
        XCTAssertNil((restored.dictionary(forKey: MeetingSettings.providerPoliciesKey) as? [String: String])?["zoom"])
    }

    // MARK: - Monitor

    func testAskOffersRecordingAndRecordStartsAMeetingForTheProvider() async throws {
        let fixture = makeMonitor()
        fixture.processes.bundleIDs = [["us.zoom.xos"]]

        await observe(fixture, seconds: [0, 2])
        XCTAssertEqual(fixture.prompt.offers, [.zoom])
        fixture.prompt.answerOffer(.record)
        try await waitUntil { fixture.recorder.isRecording }

        XCTAssertEqual(fixture.recorder.activeMeeting?.provider, "zoom")
        XCTAssertTrue(fixture.recorder.activeMeeting?.title.hasPrefix(MeetingProvider.zoom.callName) == true)
        _ = await fixture.recorder.stop()
    }

    func testNotNowSnoozesAndNeverOfferChangesThePolicy() async throws {
        let fixture = makeMonitor()
        fixture.processes.bundleIDs = [["us.zoom.xos"]]
        await observe(fixture, seconds: [0, 2])
        fixture.prompt.answerOffer(.notNow)
        fixture.processes.bundleIDs = []
        await observe(fixture, seconds: [3, 6])
        fixture.processes.bundleIDs = [["us.zoom.xos"]]
        await observe(fixture, seconds: [7, 9])
        XCTAssertEqual(fixture.prompt.offers, [.zoom])

        fixture.processes.bundleIDs = [["com.tinyspeck.slackmacgap"]]
        await observe(fixture, seconds: [20, 22])
        fixture.prompt.answerOffer(.neverOffer)

        XCTAssertEqual(MeetingSettings.policy(for: .slack, in: defaults), .neverOffer)
        XCTAssertFalse(fixture.recorder.isRecording)
    }

    func testAlwaysRecordStartsWithoutAskingAndTheCallEndingAsksToStop() async throws {
        MeetingSettings.setPolicy(.alwaysRecord, for: .teams, in: defaults)
        let fixture = makeMonitor()
        fixture.processes.bundleIDs = [["com.microsoft.teams2"]]

        await observe(fixture, seconds: [0, 2])
        try await waitUntil { fixture.recorder.isRecording }
        XCTAssertTrue(fixture.prompt.offers.isEmpty)
        XCTAssertEqual(fixture.prompt.automaticStarts, [.teams])

        fixture.processes.bundleIDs = []
        await observe(fixture, seconds: [3, 6])
        XCTAssertEqual(fixture.prompt.stopOffers, [.teams])
        XCTAssertTrue(fixture.recorder.isRecording)
        fixture.prompt.answerStop(.stop)

        try await waitUntil { !fixture.recorder.isRecording }
    }

    func testNeverOfferAndRecordingInProgressStayQuiet() async throws {
        MeetingSettings.setPolicy(.neverOffer, for: .facetime, in: defaults)
        let fixture = makeMonitor()
        fixture.processes.bundleIDs = [["com.apple.avconferenced"]]
        await observe(fixture, seconds: [0, 2])

        try await fixture.recorder.start(title: "Manual")
        fixture.processes.bundleIDs = [["us.zoom.xos"]]
        await observe(fixture, seconds: [3, 5])

        XCTAssertTrue(fixture.prompt.offers.isEmpty)
        fixture.processes.bundleIDs = []
        await observe(fixture, seconds: [6, 9])
        XCTAssertTrue(fixture.prompt.stopOffers.isEmpty, "a manual meeting has no provider to leave")
        _ = await fixture.recorder.stop()
    }

    func testMeetIsRecognizedOnlyOnACallPageInABrowserVoiceInkCanRead() async throws {
        let fixture = makeMonitor()
        fixture.processes.bundleIDs = [["com.google.Chrome.helper", "com.google.Chrome"]]
        fixture.urls[.chrome] = "https://meet.google.com/landing"
        await observe(fixture, seconds: [0, 2, 3])
        XCTAssertTrue(fixture.prompt.offers.isEmpty)

        fixture.urls[.chrome] = "https://meet.google.com/abc-defg-hij"
        await observe(fixture, seconds: [6, 8])
        XCTAssertEqual(fixture.prompt.offers, [.meet])

        fixture.processes.bundleIDs = [["com.apple.WebKit.GPU", "com.apple.Safari"]]
        fixture.urls[.safari] = nil
        await observe(fixture, seconds: [20, 22, 25, 30])
        XCTAssertEqual(fixture.prompt.offers, [.meet])
    }

    func testTurningDetectionOffDismissesAndStopsObserving() async throws {
        let fixture = makeMonitor()
        fixture.monitor.start()
        try await waitUntil { fixture.processes.calls > 0 }

        defaults.set(false, forKey: MeetingSettings.detectsCallsKey)
        try await waitUntil { fixture.prompt.dismissals > 0 }
        let calls = fixture.processes.calls
        try await Task.sleep(for: .milliseconds(60))

        XCTAssertEqual(fixture.processes.calls, calls)
    }

    func testSwitchingTabsDuringARecordedMeetCallDoesNotEndIt() async throws {
        MeetingSettings.setPolicy(.alwaysRecord, for: .meet, in: defaults)
        let fixture = makeMonitor()
        fixture.processes.bundleIDs = [["com.google.Chrome.helper"]]
        fixture.urls[.chrome] = "https://meet.google.com/abc-defg-hij"
        await observe(fixture, seconds: [0, 2])
        try await waitUntil { fixture.recorder.isRecording }

        fixture.urls[.chrome] = "https://docs.google.com/document/d/notes"
        await observe(fixture, seconds: [4, 7, 10])
        XCTAssertTrue(fixture.prompt.stopOffers.isEmpty)

        fixture.processes.bundleIDs = []
        await observe(fixture, seconds: [11, 14])
        XCTAssertEqual(fixture.prompt.stopOffers, [.meet])
        _ = await fixture.recorder.stop()
    }

    func testADeclinedMeetCallStaysSnoozedWhileItsBrowserKeepsTheMicrophone() async throws {
        let fixture = makeMonitor()
        fixture.processes.bundleIDs = [["com.google.Chrome.helper"]]
        fixture.urls[.chrome] = "https://meet.google.com/abc-defg-hij"
        await observe(fixture, seconds: [0, 2])
        fixture.prompt.answerOffer(.notNow)

        fixture.urls[.chrome] = "https://docs.google.com/document/d/notes"
        await observe(fixture, seconds: Array(stride(from: 4.0, through: 80, by: 4)))
        fixture.urls[.chrome] = "https://meet.google.com/abc-defg-hij"
        await observe(fixture, seconds: [82, 84, 86])
        XCTAssertEqual(fixture.prompt.offers, [.meet])

        fixture.processes.bundleIDs = []
        await observe(fixture, seconds: [90, 160])
        fixture.processes.bundleIDs = [["com.google.Chrome.helper"]]
        await observe(fixture, seconds: [161, 163])
        XCTAssertEqual(fixture.prompt.offers, [.meet, .meet])
    }

    func testTwoCallsStartingTogetherKeepTheFirstRecordingsBrowser() async throws {
        MeetingSettings.setPolicy(.alwaysRecord, for: .meet, in: defaults)
        MeetingSettings.setPolicy(.alwaysRecord, for: .zoom, in: defaults)
        let fixture = makeMonitor()
        fixture.processes.bundleIDs = [["com.google.Chrome.helper"], ["us.zoom.xos"]]
        fixture.urls[.chrome] = "https://meet.google.com/abc-defg-hij"
        await observe(fixture, seconds: [0, 2])
        try await waitUntil { fixture.recorder.isRecording }
        try await Task.sleep(for: .milliseconds(30))
        let provider = try XCTUnwrap(fixture.recorder.activeMeeting?.provider)

        fixture.urls[.chrome] = "https://docs.google.com/document/d/notes"
        await observe(fixture, seconds: [4, 7, 10])

        XCTAssertTrue(fixture.prompt.stopOffers.isEmpty, "\(provider) is still on its call")
        XCTAssertEqual(fixture.prompt.automaticStarts.count, 1)
        _ = await fixture.recorder.stop()
    }

    func testStartingAMeetingElsewhereWithdrawsAnOpenOffer() async throws {
        let fixture = makeMonitor()
        fixture.processes.bundleIDs = [["us.zoom.xos"]]
        await observe(fixture, seconds: [0, 2])
        XCTAssertEqual(fixture.prompt.offers, [.zoom])

        try await fixture.recorder.start(title: "Manual")
        fixture.prompt.answerOffer(.record)
        try await Task.sleep(for: .milliseconds(30))

        XCTAssertGreaterThan(fixture.prompt.dismissals, 0)
        XCTAssertEqual(fixture.recorder.activeMeeting?.title, "Manual")
        _ = await fixture.recorder.stop()
    }

    func testACallEndingWhileItsRecordingStartsAsksOnceItStarted() async throws {
        MeetingSettings.setPolicy(.alwaysRecord, for: .zoom, in: defaults)
        let fixture = makeMonitor()
        fixture.microphone.holdStart = true
        fixture.processes.bundleIDs = [["us.zoom.xos"]]
        await observe(fixture, seconds: [0, 2])
        try await waitUntil { fixture.recorder.isStarting }

        fixture.processes.bundleIDs = []
        await observe(fixture, seconds: [3, 6])
        XCTAssertTrue(fixture.prompt.stopOffers.isEmpty)
        fixture.microphone.releaseStart()

        try await waitUntil { fixture.prompt.stopOffers == [.zoom] }
        XCTAssertTrue(fixture.recorder.isRecording)
        _ = await fixture.recorder.stop()
    }

    func testARecordedCallIsNotOfferedAgainUntilItsAppIsOffTheMicrophoneForAMinute() async throws {
        MeetingSettings.setPolicy(.alwaysRecord, for: .zoom, in: defaults)
        let fixture = makeMonitor()
        fixture.processes.bundleIDs = [["us.zoom.xos"]]
        await observe(fixture, seconds: [0, 2])
        try await waitUntil { fixture.recorder.isRecording }
        _ = await fixture.recorder.stop()

        fixture.processes.bundleIDs = []
        await observe(fixture, seconds: [3, 5])
        fixture.processes.bundleIDs = [["us.zoom.xos"]]
        await observe(fixture, seconds: [6, 8, 9])
        XCTAssertFalse(fixture.recorder.isRecording)

        fixture.processes.bundleIDs = []
        await observe(fixture, seconds: [10, 80])
        fixture.processes.bundleIDs = [["us.zoom.xos"]]
        await observe(fixture, seconds: [81, 83])
        try await waitUntil { fixture.recorder.isRecording }
        _ = await fixture.recorder.stop()
    }

    func testSwitchingDetectionOffDuringABrowserLookupDropsItsResult() async throws {
        let fixture = makeMonitor()
        fixture.processes.bundleIDs = [["com.google.Chrome.helper"]]
        fixture.urls[.chrome] = "https://meet.google.com/abc-defg-hij"
        fixture.urls.holdsLookups = true
        fixture.monitor.start()
        try await waitUntil { fixture.urls.heldLookups > 0 }

        defaults.set(false, forKey: MeetingSettings.detectsCallsKey)
        try await Task.sleep(for: .milliseconds(20))
        fixture.urls.releaseLookups()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(fixture.prompt.offers.isEmpty)

        // A fresh run starts when detection returns; the dropped observation at 0 s must not count toward it.
        fixture.clock.now = 1.5
        defaults.set(true, forKey: MeetingSettings.detectsCallsKey)
        try await Task.sleep(for: .milliseconds(40))
        fixture.clock.now = 2.5
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertTrue(fixture.prompt.offers.isEmpty)
        fixture.clock.now = 3.6
        try await waitUntil { fixture.prompt.offers == [.meet] }
    }

    func testThePromptPanelTimesOutWithoutRecordingAndNeverAnswersAfterDismissal() async throws {
        let panel = MeetingCallPromptPanel()
        var answers: [MeetingCallPromptAnswer] = []

        panel.offerRecording(.zoom, timeout: .milliseconds(30)) { answers.append($0) }
        try await waitUntil { !answers.isEmpty }
        panel.offerRecording(.slack, timeout: .milliseconds(30)) { answers.append($0) }
        panel.dismiss()
        try await Task.sleep(for: .milliseconds(80))

        XCTAssertEqual(answers, [.notNow])
    }

    func testDetectionPreferencesRoundTripThroughTheConfigurationFile() throws {
        MeetingSettings.setPolicy(.alwaysRecord, for: .meet, in: defaults)
        defaults.set(false, forKey: MeetingSettings.detectsCallsKey)

        let captured = try ConfigurationPreferences.capture(from: defaults)
        let restoredName = "\(suiteName!).configuration"
        let restored = UserDefaults(suiteName: restoredName)!
        defer { restored.removePersistentDomain(forName: restoredName) }
        try ConfigurationPreferences.apply(
            captured.filter { [MeetingSettings.detectsCallsKey, MeetingSettings.providerPoliciesKey].contains($0.key) }, to: restored
        )

        XCTAssertEqual(captured[MeetingSettings.detectsCallsKey], .bool(false))
        XCTAssertEqual(MeetingSettings.policy(for: .meet, in: restored), .alwaysRecord)
        XCTAssertFalse(MeetingSettings.detectsCalls(in: restored))
    }

    func testAReleasedMonitorIsFreedAndStopsPolling() async throws {
        var fixture: MonitorFixture? = makeMonitor()
        let processes = try XCTUnwrap(fixture?.processes)
        weak var monitor = fixture?.monitor
        fixture?.monitor.start()
        try await waitUntil { processes.calls > 0 }

        fixture = nil
        try await waitUntil { monitor == nil }
        let calls = processes.calls
        try await Task.sleep(for: .milliseconds(60))

        XCTAssertEqual(processes.calls, calls)
    }

    func testCoreAudioListsProcessesWithoutThisProcess() {
        let processes = CoreAudioInputProcessListing().processesUsingInput()

        XCTAssertFalse(processes.contains { $0.pid == getpid() })
        XCTAssertEqual(CoreAudioInputProcessListing.lineage(of: getpid()).first, getpid())
    }

    // MARK: - Fixture

    private struct MonitorFixture {
        let monitor: MeetingCallMonitor
        let recorder: MeetingRecorder
        let processes: FakeInputProcesses
        let microphone: FakeMeetingMicrophoneHardware
        let prompt: FakeCallPrompt
        let clock: DetectionClock
        let urls: BrowserURLs
    }

    private func makeMonitor() -> MonitorFixture {
        let devices = MeetingAudioDevices(userDefaults: defaults)
        let microphone = FakeMeetingMicrophoneHardware()
        var recorderDependencies = MeetingRecorder.Dependencies()
        recorderDependencies.store = MeetingStore(rootURL: root)
        recorderDependencies.permission = AllowedSystemAudio()
        recorderDependencies.makeSystemAudio = { QuietSystemAudio() }
        recorderDependencies.makeMicrophone = { MeetingMicrophoneCapture(deviceManager: devices, makeHardware: { microphone }) }
        recorderDependencies.isMicrophoneAuthorized = { true }
        recorderDependencies.defaults = defaults
        let recorder = MeetingRecorder(dependencies: recorderDependencies)
        let processes = FakeInputProcesses()
        let prompt = FakeCallPrompt()
        let clock = DetectionClock()
        let urls = BrowserURLs()
        var dependencies = MeetingCallMonitor.Dependencies()
        dependencies.processes = processes
        dependencies.browserURL = { await urls.lookup($0) }
        dependencies.prompt = prompt
        dependencies.recorder = recorder
        dependencies.defaults = defaults
        dependencies.now = { clock.now }
        dependencies.pollInterval = .milliseconds(5)
        return MonitorFixture(
            monitor: MeetingCallMonitor(dependencies: dependencies), recorder: recorder, processes: processes,
            microphone: microphone, prompt: prompt, clock: clock, urls: urls
        )
    }

    private func observe(_ fixture: MonitorFixture, seconds: [TimeInterval]) async {
        for second in seconds {
            fixture.clock.now = second
            await fixture.monitor.poll()
        }
    }

    private func waitUntil(timeout: Duration = .seconds(2), _ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else { return XCTFail("Condition not met in time") }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

private final class DetectionClock: @unchecked Sendable {
    var now: TimeInterval = 0
}

@MainActor
private final class BrowserURLs {
    private var values: [BrowserType: String] = [:]
    var holdsLookups = false
    private(set) var heldLookups = 0
    private var held: [CheckedContinuation<Void, Never>] = []

    subscript(browser: BrowserType) -> String? {
        get { values[browser] }
        set { values[browser] = newValue }
    }

    func lookup(_ browser: BrowserType) async -> String? {
        if holdsLookups {
            heldLookups += 1
            await withCheckedContinuation { held.append($0) }
        }
        return values[browser]
    }

    func releaseLookups() {
        holdsLookups = false
        held.forEach { $0.resume() }
        held = []
    }
}

private final class FakeInputProcesses: AudioInputProcessListing, @unchecked Sendable {
    var bundleIDs: [[String]] = []
    private(set) var calls = 0

    func processesUsingInput() -> [AudioInputProcess] {
        calls += 1
        return bundleIDs.enumerated().map { AudioInputProcess(pid: pid_t(1_000 + $0.offset), bundleIDs: $0.element) }
    }
}

@MainActor
private final class FakeCallPrompt: MeetingCallPrompting {
    var offers: [MeetingProvider] = []
    var stopOffers: [MeetingProvider] = []
    var automaticStarts: [MeetingProvider] = []
    var dismissals = 0
    private var offerAnswer: (@MainActor (MeetingCallPromptAnswer) -> Void)?
    private var stopAnswer: (@MainActor (MeetingCallPromptAnswer) -> Void)?

    func offerRecording(_ provider: MeetingProvider, timeout: Duration, answer: @escaping @MainActor (MeetingCallPromptAnswer) -> Void) {
        offers.append(provider)
        offerAnswer = answer
    }

    func offerStop(_ provider: MeetingProvider, answer: @escaping @MainActor (MeetingCallPromptAnswer) -> Void) {
        stopOffers.append(provider)
        stopAnswer = answer
    }

    func showStartedAutomatically(_ provider: MeetingProvider) { automaticStarts.append(provider) }

    /// Like the panel, a dismissed prompt never answers.
    func dismiss() {
        dismissals += 1
        offerAnswer = nil
        stopAnswer = nil
    }

    func answerOffer(_ answer: MeetingCallPromptAnswer) {
        offerAnswer?(answer)
        offerAnswer = nil
    }

    func answerStop(_ answer: MeetingCallPromptAnswer) {
        stopAnswer?(answer)
        stopAnswer = nil
    }
}

private final class AllowedSystemAudio: SystemAudioAuthorizing {
    func status() -> SystemAudioAuthorization { .granted }
    func request() async -> SystemAudioAuthorization { .granted }
}

private final class QuietSystemAudio: SystemAudioCapturing, @unchecked Sendable {
    var lastDeliveryNanoseconds: UInt64? { DispatchTime.now().uptimeNanoseconds }
    func start(writingTo url: URL, meetingStartNanoseconds: UInt64) throws {}
    func restart() throws {}
    func stop() -> MeetingTrackCaptureResult { MeetingTrackCaptureResult() }
}
