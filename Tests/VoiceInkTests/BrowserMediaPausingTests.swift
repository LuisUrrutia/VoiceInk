import CoreAudio
import XCTest
@testable import VoiceInk

/// Scripted browser output: each listen window returns the next peak, then nil.
private final class ScriptedBrowserAudio: BrowserAudioListening, @unchecked Sendable {
    private let lock = NSLock()
    private var peaks: [Float?]
    private var holdBeforeWindow: Int?
    private var holdContinuation: CheckedContinuation<Void, Never>?
    let usesMicrophone: Bool
    let outputClosed: Bool
    let reachedHold = XCTestExpectation(description: "listen window held")
    private(set) var listenedWindows = 0
    private(set) var closed = false

    init(_ peaks: [Float?], usesMicrophone: Bool = false, outputClosed: Bool = false, holdBeforeWindow: Int? = nil) {
        self.peaks = peaks
        self.usesMicrophone = usesMicrophone
        self.outputClosed = outputClosed
        self.holdBeforeWindow = holdBeforeWindow
    }

    func isBrowserUsingMicrophone() -> Bool { usesMicrophone }

    func peakDBFS(over window: Duration) async -> Float? {
        let shouldHold = lock.withLock { () -> Bool in
            defer { listenedWindows += 1 }
            return listenedWindows == holdBeforeWindow
        }
        if shouldHold {
            await withCheckedContinuation { continuation in
                lock.withLock { holdContinuation = continuation }
                reachedHold.fulfill()
            }
        }
        return lock.withLock { peaks.isEmpty ? nil : peaks.removeFirst() }
    }

    func release() {
        lock.withLock {
            holdBeforeWindow = nil
            holdContinuation?.resume()
            holdContinuation = nil
        }
    }

    func isBrowserOutputClosed() -> Bool { outputClosed }
    func close() { lock.withLock { closed = true } }
}

private final class RecordingCommands: BrowserMediaCommandSending, @unchecked Sendable {
    private let lock = NSLock()
    private var commands: [BrowserMediaCommand] = []
    let accepts: Bool

    init(accepts: Bool = true) { self.accepts = accepts }

    var sent: [BrowserMediaCommand] { lock.withLock { commands } }

    func send(_ command: BrowserMediaCommand) -> Bool {
        lock.withLock { commands.append(command) }
        return accepts
    }
}

private struct FixedPermission: SystemAudioRecordingPermissionChecking {
    let state: SystemAudioRecordingAuthorization
    func authorization() -> SystemAudioRecordingAuthorization { state }
    func request(completion: @escaping @Sendable (Bool) -> Void) -> Bool { false }
}

private final class ListenerQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var listeners: [ScriptedBrowserAudio]
    private(set) var requested: [BrowserAudioProcesses] = []

    init(_ listeners: [ScriptedBrowserAudio]) { self.listeners = listeners }

    func next(_ which: BrowserAudioProcesses) -> any BrowserAudioListening {
        lock.withLock {
            requested.append(which)
            return listeners.isEmpty ? ScriptedBrowserAudio([]) : listeners.removeFirst()
        }
    }
}

private let playing: [Float?] = [-20, -20, -20]

final class BrowserMediaSequenceTests: XCTestCase {
    private func pause(_ audio: ScriptedBrowserAudio, _ commands: RecordingCommands) async -> Bool {
        await BrowserMediaSequence.pause(audio, commands: commands, gate: BrowserMediaCommandGate())
    }

    private func resume(_ audio: ScriptedBrowserAudio, _ commands: RecordingCommands) async -> BrowserMediaSequence.ResumeOutcome {
        await BrowserMediaSequence.resume(audio, commands: commands, gate: BrowserMediaCommandGate())
    }

    func testSilentBrowserIsLeftAlone() async {
        let commands = RecordingCommands()

        let paused = await pause(ScriptedBrowserAudio([-120]), commands)

        XCTAssertFalse(paused)
        XCTAssertEqual(commands.sent, [])
    }

    func testShortSoundIsNotAPlayingBrowser() async {
        for listen: [Float?] in [[-20, -120, -120], [-120, -20, -20], [-20, -20, nil], [-20, -20, -60]] {
            let commands = RecordingCommands()

            let paused = await pause(ScriptedBrowserAudio(listen + Array(repeating: -200, count: 5)), commands)

            XCTAssertFalse(paused, "\(listen)")
            XCTAssertEqual(commands.sent, [], "\(listen)")
        }
    }

    func testCallIsNeverPausedOrHeard() async {
        let audio = ScriptedBrowserAudio(playing, usesMicrophone: true)
        let commands = RecordingCommands()

        let paused = await pause(audio, commands)

        XCTAssertFalse(paused)
        XCTAssertEqual(commands.sent, [])
        XCTAssertEqual(audio.listenedWindows, 0)
    }

    func testNoLevelSendsNothing() async {
        let commands = RecordingCommands()

        let paused = await pause(ScriptedBrowserAudio([nil]), commands)

        XCTAssertFalse(paused)
        XCTAssertEqual(commands.sent, [])
    }

    func testConfirmedPauseIsResumed() async {
        let audio = ScriptedBrowserAudio(playing + [-30, -200, -200, -200, -200, -25])
        let commands = RecordingCommands()

        let paused = await pause(audio, commands)
        let outcome = await resume(audio, commands)

        XCTAssertTrue(paused)
        XCTAssertEqual(outcome, .resumed)
        XCTAssertEqual(commands.sent, [.pause, .play])
    }

    func testRefusedPauseIsNotOwned() async {
        let commands = RecordingCommands(accepts: false)

        let paused = await pause(ScriptedBrowserAudio(playing + [-200, -200]), commands)

        XCTAssertFalse(paused)
        XCTAssertEqual(commands.sent, [.pause])
    }

    func testTwoSoundingTabsNeverGetPlay() async {
        let commands = RecordingCommands()

        let paused = await pause(ScriptedBrowserAudio(playing + Array(repeating: -25, count: 10)), commands)

        XCTAssertFalse(paused)
        XCTAssertEqual(commands.sent, [.pause])
    }

    func testLateSilenceIsNotAConfirmedPause() async {
        let commands = RecordingCommands()

        let paused = await pause(
            ScriptedBrowserAudio(playing + [-25, -25, -25, -25] + Array(repeating: -200, count: 6)), commands
        )

        XCTAssertFalse(paused)
        XCTAssertEqual(commands.sent, [.pause])
    }

    func testOneQuietWindowIsNotAConfirmedPause() async {
        let commands = RecordingCommands()

        let paused = await pause(ScriptedBrowserAudio(playing + [-200, -25, -200, -25, -25, -200, -200]), commands)

        XCTAssertFalse(paused)
        XCTAssertEqual(commands.sent, [.pause])
    }

    func testBrowserAlreadyPlayingAgainGetsNoPlay() async {
        let commands = RecordingCommands()

        let outcome = await resume(ScriptedBrowserAudio([-25]), commands)

        XCTAssertEqual(outcome, .leftAlone)
        XCTAssertEqual(commands.sent, [])
    }

    func testUnheardBrowserWithOpenOutputGetsNoPlay() async {
        let commands = RecordingCommands()

        let outcome = await resume(ScriptedBrowserAudio([nil], outputClosed: false), commands)

        XCTAssertEqual(outcome, .leftAlone)
        XCTAssertEqual(commands.sent, [])
    }

    func testPlayTheBrowserNeverTakesIsPausedAgain() async {
        let commands = RecordingCommands()

        let outcome = await resume(ScriptedBrowserAudio(Array(repeating: -200, count: 40)), commands)

        XCTAssertEqual(outcome, .pausedAgain)
        XCTAssertEqual(commands.sent, [.play, .pause])
    }

    func testBrowserThatPlaysLateInTheCheckKeepsPlaying() async {
        let commands = RecordingCommands()

        let outcome = await resume(ScriptedBrowserAudio(Array(repeating: -200, count: 20) + [-25]), commands)

        XCTAssertEqual(outcome, .resumed)
        XCTAssertEqual(commands.sent, [.play])
    }

    func testBrowserItStopsHearingAfterPlayGetsNothingMore() async {
        let commands = RecordingCommands()

        let outcome = await resume(ScriptedBrowserAudio([-200, -200]), commands)

        XCTAssertEqual(outcome, .unconfirmed)
        XCTAssertEqual(commands.sent, [.play])
    }

    func testBrowserThatClosedItsOutputGetsPlay() async {
        let commands = RecordingCommands()

        let outcome = await resume(ScriptedBrowserAudio([nil, nil, nil, -25], outputClosed: true), commands)

        XCTAssertEqual(outcome, .resumed)
        XCTAssertEqual(commands.sent, [.play])
    }

    func testClosedBrowserThatNeverOpensAfterPlayIsPausedAgain() async {
        let audio = ScriptedBrowserAudio([], outputClosed: true)
        let commands = RecordingCommands()

        let outcome = await resume(audio, commands)

        XCTAssertEqual(outcome, .pausedAgain)
        XCTAssertEqual(commands.sent, [.play, .pause])
        XCTAssertEqual(audio.listenedWindows, 1 + BrowserMediaSequence.openCheckWindows)
    }

    func testAbandonedGateSendsNothingButASentPauseIsStillConfirmed() async {
        let abandoned = BrowserMediaCommandGate()
        abandoned.abandon()
        let commands = RecordingCommands()
        let sent = BrowserMediaCommandGate()

        let skipped = await BrowserMediaSequence.pause(ScriptedBrowserAudio(playing), commands: commands, gate: abandoned)
        XCTAssertTrue(sent.claimSend())
        sent.abandon()
        let resumeOutcome = await BrowserMediaSequence.resume(ScriptedBrowserAudio([-200]), commands: commands, gate: abandoned)

        XCTAssertFalse(skipped)
        XCTAssertEqual(resumeOutcome, .abandoned)
        XCTAssertEqual(commands.sent, [])
        XCTAssertTrue(sent.claimSend(), "abandoning after a send has no effect")
    }
}

@MainActor
final class BrowserMediaPauserTests: XCTestCase {
    private func makePauser(
        _ listeners: [ScriptedBrowserAudio],
        permission: SystemAudioRecordingAuthorization = .granted,
        commands: RecordingCommands
    ) -> (BrowserMediaPauser, ListenerQueue) {
        let queue = ListenerQueue(listeners)
        let pauser = BrowserMediaPauser(
            permission: FixedPermission(state: permission), commands: commands, makeListener: { queue.next($0) }
        )
        return (pauser, queue)
    }

    func testOnlyGrantedPermissionListens() async {
        for state: SystemAudioRecordingAuthorization in [.denied, .notDetermined, .unknown] {
            let commands = RecordingCommands()
            let (pauser, queue) = makePauser([ScriptedBrowserAudio(playing + [-200, -200])], permission: state, commands: commands)

            await pauser.pause()

            XCTAssertFalse(pauser.ownsPause, "\(state)")
            XCTAssertEqual(queue.requested, [], "\(state)")
            XCTAssertEqual(commands.sent, [], "\(state)")
        }
    }

    func testPauseHearsPlayingBrowsersAndResumeHearsAllAndClosesListeners() async {
        let pauseAudio = ScriptedBrowserAudio(playing + [-200, -200])
        let resumeAudio = ScriptedBrowserAudio([-200, -25])
        let commands = RecordingCommands()
        let (pauser, queue) = makePauser([pauseAudio, resumeAudio], commands: commands)

        await pauser.pause()
        let ownedAfterPause = pauser.ownsPause
        await pauser.resume()

        XCTAssertTrue(ownedAfterPause)
        XCTAssertFalse(pauser.ownsPause)
        XCTAssertEqual(queue.requested, [.playing, .all])
        XCTAssertEqual(commands.sent, [.pause, .play])
        XCTAssertTrue(pauseAudio.closed)
        XCTAssertTrue(resumeAudio.closed)
    }

    func testOwnedPauseIsInheritedWithoutListeningAgain() async {
        let commands = RecordingCommands()
        let (pauser, queue) = makePauser([ScriptedBrowserAudio(playing + [-200, -200])], commands: commands)

        await pauser.pause()
        await pauser.pause()

        XCTAssertTrue(pauser.ownsPause)
        XCTAssertEqual(queue.requested, [.playing])
        XCTAssertEqual(commands.sent, [.pause])
    }

    func testCancelledBeforeThePauseSendsNothing() async {
        let audio = ScriptedBrowserAudio(playing + [-200, -200], holdBeforeWindow: 1)
        let commands = RecordingCommands()
        let (pauser, _) = makePauser([audio], commands: commands)

        let caller = Task { await pauser.pause() }
        await fulfillment(of: [audio.reachedHold], timeout: 5)
        caller.cancel()
        audio.release()
        await caller.value
        await pauser.settle()

        XCTAssertFalse(pauser.ownsPause)
        XCTAssertEqual(commands.sent, [])
    }

    func testCancelledAfterThePauseStillConfirmsAndResumeWaitsForIt() async {
        let audio = ScriptedBrowserAudio(playing + [-200, -200], holdBeforeWindow: 3)
        let commands = RecordingCommands()
        let (pauser, _) = makePauser([audio, ScriptedBrowserAudio([-200, -25])], commands: commands)

        let caller = Task { await pauser.pause() }
        await fulfillment(of: [audio.reachedHold], timeout: 5)
        caller.cancel()
        let resumer = Task { await pauser.resume() }
        audio.release()
        await caller.value
        await resumer.value

        XCTAssertEqual(commands.sent, [.pause, .play])
        XCTAssertFalse(pauser.ownsPause)
    }

    func testNewRecordingAbandonsAResumeBeforePlayAndInheritsThePause() async {
        let resumeAudio = ScriptedBrowserAudio([-200, -25], holdBeforeWindow: 0)
        let commands = RecordingCommands()
        let (pauser, queue) = makePauser([ScriptedBrowserAudio(playing + [-200, -200]), resumeAudio], commands: commands)
        await pauser.pause()

        let resumer = Task { await pauser.resume() }
        await fulfillment(of: [resumeAudio.reachedHold], timeout: 5)
        pauser.abandonPendingResume()
        resumeAudio.release()
        await resumer.value
        await pauser.pause()

        XCTAssertTrue(pauser.ownsPause)
        XCTAssertEqual(commands.sent, [.pause])
        XCTAssertEqual(queue.requested, [.playing, .all])
    }

    func testForgottenPauseIsNeverPlayed() async {
        let commands = RecordingCommands()
        let (pauser, queue) = makePauser([ScriptedBrowserAudio(playing + [-200, -200])], commands: commands)
        await pauser.pause()

        pauser.forgetPause()
        await pauser.resume()

        XCTAssertFalse(pauser.ownsPause)
        XCTAssertEqual(commands.sent, [.pause])
        XCTAssertEqual(queue.requested, [.playing])
    }
}

private struct FixedProcessList: BrowserAudioProcessListing {
    let list: [BrowserAudioProcess]?
    func processes() -> [BrowserAudioProcess]? { list }
}

private func process(
    _ id: AudioObjectID, _ bundleID: String, name: String? = nil, output: Bool? = false, input: Bool? = false,
    pid: pid_t = 4242
) -> BrowserAudioProcess {
    BrowserAudioProcess(
        objectID: id, pid: pid, bundleID: bundleID, applicationName: name, isRunningOutput: output, isRunningInput: input
    )
}

final class BrowserAudioCatalogTests: XCTestCase {
    func testBrowsersAndTheirHelpersAreRecognized() {
        XCTAssertTrue(BrowserAudioCatalog.isBrowser(bundleID: "com.google.Chrome.helper", applicationName: nil))
        XCTAssertTrue(BrowserAudioCatalog.isBrowser(bundleID: "com.brave.Browser", applicationName: nil))
        XCTAssertTrue(BrowserAudioCatalog.isBrowser(bundleID: "company.thebrowser.Browser.helper.renderer", applicationName: nil))
        XCTAssertTrue(BrowserAudioCatalog.isBrowser(bundleID: "org.mozilla.plugincontainer", applicationName: nil))
        XCTAssertTrue(BrowserAudioCatalog.isBrowser(bundleID: "com.apple.WebKit.GPU", applicationName: "Safari Graphics and Media"))
        XCTAssertFalse(BrowserAudioCatalog.isBrowser(bundleID: "com.apple.WebKit.GPU", applicationName: "Mail Graphics and Media"))
        XCTAssertFalse(BrowserAudioCatalog.isBrowser(bundleID: "com.apple.WebKit.GPU", applicationName: nil))
        XCTAssertFalse(BrowserAudioCatalog.isBrowser(bundleID: "com.google.Chromecast", applicationName: nil))
        XCTAssertFalse(BrowserAudioCatalog.isBrowser(bundleID: "com.spotify.client", applicationName: nil))
    }

    func testPlayingSelectionCountsUnknownOutputAsOpen() {
        let browsers = [process(1, "com.google.Chrome", output: true), process(2, "com.brave.Browser", output: nil),
                        process(3, "com.apple.Safari", output: false)]

        XCTAssertEqual(BrowserAudioCatalog.select(.playing, from: browsers).map(\.objectID), [1, 2])
        XCTAssertEqual(BrowserAudioCatalog.select(.all, from: browsers).map(\.objectID), [1, 2, 3])
    }

    func testOwnProcessIsExcluded() {
        let own = ProcessInfo.processInfo.processIdentifier
        let browsers = BrowserAudioCatalog.browsers(
            in: [process(1, "com.google.Chrome", pid: own), process(2, "com.google.Chrome")], excluding: own
        )

        XCTAssertEqual(browsers.map(\.objectID), [2])
    }

    func testMicrophoneUseCountsOnlyBrowsersAndAnUnreadableListCountsAsACall() {
        let call = CoreAudioBrowserAudioListener(
            .playing, processList: FixedProcessList(list: [process(1, "com.google.Chrome.helper", input: true)])
        )
        let otherApp = CoreAudioBrowserAudioListener(
            .playing, processList: FixedProcessList(list: [process(1, "us.zoom.xos", input: true),
                                                           process(2, "com.google.Chrome", output: true)])
        )
        let unreadable = CoreAudioBrowserAudioListener(.playing, processList: FixedProcessList(list: nil))

        XCTAssertTrue(call.isBrowserUsingMicrophone())
        XCTAssertFalse(otherApp.isBrowserUsingMicrophone())
        XCTAssertTrue(unreadable.isBrowserUsingMicrophone())
    }

    func testOutputIsClosedOnlyWhileABrowserRunsWithEveryOutputClosed() {
        func closed(_ list: [BrowserAudioProcess]?) -> Bool {
            CoreAudioBrowserAudioListener(.all, processList: FixedProcessList(list: list)).isBrowserOutputClosed()
        }

        XCTAssertTrue(closed([process(1, "com.google.Chrome", output: false), process(2, "com.spotify.client", output: true)]))
        XCTAssertFalse(closed([process(1, "com.google.Chrome", output: false), process(2, "com.google.Chrome.helper", output: true)]))
        XCTAssertFalse(closed([process(2, "com.spotify.client", output: true)]), "a quit browser is not a paused one")
        XCTAssertFalse(closed(nil))
    }

    func testNoOpenBrowserOutputCreatesNoTap() async {
        let listener = CoreAudioBrowserAudioListener(
            .playing, processList: FixedProcessList(list: [process(1, "com.google.Chrome", output: false)])
        )

        let peak = await listener.peakDBFS(over: .milliseconds(1))

        XCTAssertNil(peak)
    }

    /// Opt-in: `TEST_RUNNER_VOICEINK_BROWSER_TAP=1` with a browser playing audio and
    /// System Audio Recording allowed for the test host.
    func testNativeTapHearsAPlayingBrowser() async throws {
        guard ProcessInfo.processInfo.environment["VOICEINK_BROWSER_TAP"] == "1" else {
            throw XCTSkip("Set TEST_RUNNER_VOICEINK_BROWSER_TAP=1 with a browser playing audio")
        }
        let listener = CoreAudioBrowserAudioListener(.playing)
        defer { listener.close() }

        let peak = await listener.peakDBFS(over: BrowserMediaSequence.window)

        print("Browser peak: \(peak.map { String($0) } ?? "none") dBFS")
        XCTAssertGreaterThan(try XCTUnwrap(peak), BrowserMediaSequence.soundDBFS)
    }
}

final class BrowserMediaPausingSettingsTests: XCTestCase {
    func testConfigurationRoundTripsTheSetting() throws {
        let suite = "BrowserMediaPausingSettingsTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: PlaybackController.pauseBrowserMediaKey)
        let restoredSuite = "\(suite).restored"
        let restored = try XCTUnwrap(UserDefaults(suiteName: restoredSuite))
        defer { restored.removePersistentDomain(forName: restoredSuite) }

        let captured = try ConfigurationPreferences.capture(from: defaults)
        try ConfigurationPreferences.apply(captured, to: restored)

        XCTAssertEqual(captured[PlaybackController.pauseBrowserMediaKey], .bool(true))
        XCTAssertEqual(restored.object(forKey: PlaybackController.pauseBrowserMediaKey) as? Bool, true)
    }

    func testGeneralBackupCarriesTheSettingAndMissingFieldKeepsTheCurrentValue() throws {
        let legacy = try JSONDecoder().decode(GeneralBackup.self, from: Data(#"{"isPauseMediaEnabled":true}"#.utf8))
        let enabled = try JSONDecoder().decode(
            GeneralBackup.self, from: Data(#"{"isPauseMediaEnabled":true,"isPauseBrowserMediaEnabled":true}"#.utf8)
        )

        XCTAssertNil(legacy.isPauseBrowserMediaEnabled)
        XCTAssertEqual(enabled.isPauseBrowserMediaEnabled, true)
    }
}

private final class FakeNowPlaying: NowPlayingMediaControlling {
    var onStateReceived: ((NowPlayingState?) -> Void)?
    var current: NowPlayingState?
    private(set) var commands: [BrowserMediaCommand] = []
    private(set) var isListening = false

    func startListening() { isListening = true }
    func stopListening() { isListening = false }
    func pause() { commands.append(.pause) }
    func fetchState(_ onReceive: @escaping (NowPlayingState?) -> Void) { onReceive(current) }

    func report(_ bundleID: String, playing: Bool) {
        current = NowPlayingState(bundleIdentifier: bundleID, isPlaying: playing)
        onStateReceived?(current)
    }
}

@MainActor
final class PlaybackControllerOwnershipTests: XCTestCase {
    private var suite = ""
    private var defaults: UserDefaults!
    private var nowPlaying: FakeNowPlaying!
    private var browserCommands: RecordingCommands!
    private var playPauseKeys = 0
    private var delay = 0.0

    override func setUp() async throws {
        suite = "PlaybackControllerOwnershipTests.\(UUID())"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set(true, forKey: "isPauseMediaEnabled")
        defaults.set(true, forKey: PlaybackController.pauseBrowserMediaKey)
        nowPlaying = FakeNowPlaying()
        browserCommands = RecordingCommands()
        playPauseKeys = 0
        delay = 0
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
    }

    private func makeController(_ listeners: [ScriptedBrowserAudio]) -> (PlaybackController, ListenerQueue) {
        let queue = ListenerQueue(listeners)
        let pauser = BrowserMediaPauser(
            permission: FixedPermission(state: .granted), commands: browserCommands, makeListener: { queue.next($0) }
        )
        let controller = PlaybackController(
            mediaController: nowPlaying, browserMediaPauser: pauser, defaults: defaults,
            sendPlayPauseKey: { [unowned self] in playPauseKeys += 1 },
            isApplicationRunning: { _ in true },
            resumptionDelay: { [unowned self] in delay }
        )
        return (controller, queue)
    }

    func testANowPlayingPauseNeverAlsoPausesTheBrowser() async {
        let (controller, queue) = makeController([ScriptedBrowserAudio(playing + [-200, -200])])
        nowPlaying.report("com.spotify.client", playing: true)
        let session = controller.beginRecordingSession()

        await controller.pauseMedia(sessionID: session)
        nowPlaying.report("com.spotify.client", playing: false)
        await controller.resumeMedia(sessionID: session)

        XCTAssertEqual(nowPlaying.commands, [.pause])
        XCTAssertEqual(playPauseKeys, 1, "the Now Playing restore keeps its play/pause key")
        XCTAssertEqual(queue.requested, [], "the browser is not heard while a Now Playing pause is owned")
        XCTAssertEqual(browserCommands.sent, [])
    }

    func testABrowserPauseSkipsTheNowPlayingPathAndResumesOnlyTheBrowser() async {
        let (controller, queue) = makeController([
            ScriptedBrowserAudio(playing + [-200, -200]), ScriptedBrowserAudio([-200, -25]),
        ])
        let first = controller.beginRecordingSession()
        await controller.pauseMedia(sessionID: first)

        // A second recording inherits the unresumed browser pause even though Spotify now plays.
        nowPlaying.report("com.spotify.client", playing: true)
        let second = controller.beginRecordingSession()
        await controller.pauseMedia(sessionID: second)
        await controller.resumeMedia(sessionID: first)
        let ownedAfterStaleResume = browserCommands.sent
        await controller.resumeMedia(sessionID: second)

        XCTAssertEqual(ownedAfterStaleResume, [.pause], "an older session's resume does not play")
        XCTAssertEqual(browserCommands.sent, [.pause, .play])
        XCTAssertEqual(queue.requested, [.playing, .all])
        XCTAssertEqual(nowPlaying.commands, [], "Spotify is never paused while the browser pause is owned")
        XCTAssertEqual(playPauseKeys, 0)
    }

    func testBrowserResumeWaitsForResumeDelayAndCancellationKeepsThePause() async {
        delay = 5
        let (controller, queue) = makeController([
            ScriptedBrowserAudio(playing + [-200, -200]), ScriptedBrowserAudio([-200, -25]),
        ])
        let session = controller.beginRecordingSession()
        await controller.pauseMedia(sessionID: session)

        let restore = Task { await controller.resumeMedia(sessionID: session) }
        try? await Task.sleep(for: .milliseconds(50))
        restore.cancel()
        await restore.value
        let afterCanceledDelay = browserCommands.sent
        delay = 0
        await controller.resumeMedia(sessionID: session)

        XCTAssertEqual(afterCanceledDelay, [.pause], "no play during Resume Delay or after its cancellation")
        XCTAssertEqual(browserCommands.sent, [.pause, .play])
        XCTAssertEqual(queue.requested, [.playing, .all])
    }

    func testBrowserStepNeedsBothSettings() async {
        for (pauseMedia, browser) in [(true, false), (false, true)] {
            defaults.set(pauseMedia, forKey: "isPauseMediaEnabled")
            defaults.set(browser, forKey: PlaybackController.pauseBrowserMediaKey)
            browserCommands = RecordingCommands()
            let (controller, queue) = makeController([ScriptedBrowserAudio(playing + [-200, -200])])
            let session = controller.beginRecordingSession()

            await controller.pauseMedia(sessionID: session)

            XCTAssertEqual(queue.requested, [], "pause media \(pauseMedia), browser \(browser)")
            XCTAssertEqual(browserCommands.sent, [])
        }
    }

    func testTurningTheBrowserSettingOffForgetsItsPauseWithoutPlaying() async {
        let (controller, queue) = makeController([ScriptedBrowserAudio(playing + [-200, -200])])
        let session = controller.beginRecordingSession()
        await controller.pauseMedia(sessionID: session)

        controller.isPauseBrowserMediaEnabled = false
        await controller.resumeMedia(sessionID: session)

        XCTAssertEqual(browserCommands.sent, [.pause])
        XCTAssertEqual(queue.requested, [.playing])
        XCTAssertEqual(defaults.object(forKey: PlaybackController.pauseBrowserMediaKey) as? Bool, false)
    }
}

private final class ScriptedPermission: SystemAudioRecordingPermissionChecking, @unchecked Sendable {
    private let lock = NSLock()
    private var state: SystemAudioRecordingAuthorization
    private var completions: [@Sendable (Bool) -> Void] = []
    private(set) var requests = 0

    init(_ state: SystemAudioRecordingAuthorization) { self.state = state }

    func authorization() -> SystemAudioRecordingAuthorization { lock.withLock { state } }

    func request(completion: @escaping @Sendable (Bool) -> Void) -> Bool {
        lock.withLock {
            guard state == .notDetermined else { return false }
            requests += 1
            completions.append(completion)
            return true
        }
    }

    func answer(_ granted: Bool) {
        let pending = lock.withLock { () -> [@Sendable (Bool) -> Void] in
            state = granted ? .granted : .denied
            defer { completions.removeAll() }
            return completions
        }
        pending.forEach { $0(granted) }
    }
}

@MainActor
final class SystemAudioRecordingPermissionModelTests: XCTestCase {
    private func waitUntil(_ condition: @escaping @MainActor () -> Bool) async {
        for _ in 0..<200 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
    }

    func testAnswerEndsWaitingAndShowsTheResult() async {
        let permission = ScriptedPermission(.notDetermined)
        let model = SystemAudioRecordingPermissionModel(permission: permission)

        model.requestIfUndetermined()
        let waited = model.isWaitingForAnswer
        permission.answer(true)
        await waitUntil { !model.isWaitingForAnswer }

        XCTAssertTrue(waited)
        XCTAssertFalse(model.isWaitingForAnswer)
        XCTAssertEqual(model.authorization, .granted)
    }

    func testUnansweredRequestOffersAllowAgainAfterActivationOrTimeout() async {
        let permission = ScriptedPermission(.notDetermined)
        let model = SystemAudioRecordingPermissionModel(permission: permission, answerTimeout: .milliseconds(50))

        model.requestIfUndetermined()
        model.applicationDidBecomeActive()
        let afterActivation = model.isWaitingForAnswer
        model.requestIfUndetermined()
        await waitUntil { !model.isWaitingForAnswer }

        XCTAssertFalse(afterActivation)
        XCTAssertFalse(model.isWaitingForAnswer)
        XCTAssertEqual(model.authorization, .notDetermined)
        XCTAssertEqual(permission.requests, 2)
    }

    func testDecidedOrUnknownPermissionIsNeverRequested() {
        for state: SystemAudioRecordingAuthorization in [.granted, .denied, .unknown] {
            let permission = ScriptedPermission(state)
            let model = SystemAudioRecordingPermissionModel(permission: permission)

            model.requestIfUndetermined()

            XCTAssertFalse(model.isWaitingForAnswer, "\(state)")
            XCTAssertEqual(permission.requests, 0, "\(state)")
        }
    }
}

private struct TapStartFailure: Error {}

private final class SilentLevel: BrowserOutputLevel {
    func waitForFirstCycle() async {}
    func peakDBFS(over window: Duration) async -> Float? { nil }
}

final class BrowserTapFailureTests: XCTestCase {
    private let closedChrome = FixedProcessList(list: [process(1, "com.google.Chrome", output: false)])

    func testAFailedTapCannotAuthorizePlayForAClosedOutput() async {
        let listener = CoreAudioBrowserAudioListener(.all, processList: closedChrome, startTap: { _ in throw TapStartFailure() })
        let commands = RecordingCommands()

        let outcome = await BrowserMediaSequence.resume(listener, commands: commands, gate: BrowserMediaCommandGate())

        XCTAssertEqual(outcome, .leftAlone)
        XCTAssertEqual(commands.sent, [])
        XCTAssertFalse(listener.isBrowserOutputClosed())
    }

    func testAStartedTapOnAClosedOutputStillAllowsPlay() async {
        let listener = CoreAudioBrowserAudioListener(.all, processList: closedChrome, startTap: { _ in SilentLevel() })

        let peak = await listener.peakDBFS(over: .milliseconds(1))

        XCTAssertNil(peak)
        XCTAssertTrue(listener.isBrowserOutputClosed())
    }
}

@MainActor
final class BrowserMediaResumeConsentTests: XCTestCase {
    func testRevokedConsentSendsNoPlayAndGivesUpThePause() async {
        let permission = ScriptedPermission(.granted)
        let commands = RecordingCommands()
        let queue = ListenerQueue([ScriptedBrowserAudio(playing + [-200, -200]), ScriptedBrowserAudio([-200, -25])])
        let pauser = BrowserMediaPauser(permission: permission, commands: commands, makeListener: { queue.next($0) })
        await pauser.pause()

        permission.answer(false)
        await pauser.resume()

        XCTAssertEqual(commands.sent, [.pause])
        XCTAssertEqual(queue.requested, [.playing])
        XCTAssertFalse(pauser.ownsPause)
    }
}

private var sentMediaRemoteCommands: [UInt32] = []

final class MediaRemoteCommandSenderTests: XCTestCase {
    func testExplicitCommandsAndTheirResultReachTheSequence() {
        sentMediaRemoteCommands = []
        let accepting = MediaRemoteCommandSender(sendCommand: { command, _ in
            sentMediaRemoteCommands.append(command)
            return 1
        })
        let refusing = MediaRemoteCommandSender(sendCommand: { _, _ in 0 })

        XCTAssertTrue(accepting.send(.pause))
        XCTAssertTrue(accepting.send(.play))
        XCTAssertFalse(refusing.send(.pause))
        XCTAssertFalse(MediaRemoteCommandSender(sendCommand: nil).send(.pause), "a missing symbol refuses")
        XCTAssertEqual(sentMediaRemoteCommands, [1, 0], "kMRPause is 1 and kMRPlay is 0; never the toggle")
    }
}

@MainActor
final class BrowserMediaBackupRestoreTests: XCTestCase {
    func testBackupRestoresPresentValuesAndKeepsTheCurrentOneWhenMissing() throws {
        let suite = "BrowserMediaBackupRestoreTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: PlaybackController.pauseBrowserMediaKey)
        let controller = PlaybackController(
            mediaController: FakeNowPlaying(),
            browserMediaPauser: BrowserMediaPauser(
                permission: FixedPermission(state: .granted), commands: RecordingCommands(),
                makeListener: { _ in ScriptedBrowserAudio([]) }
            ),
            defaults: defaults, sendPlayPauseKey: {}, isApplicationRunning: { _ in true }, resumptionDelay: { 0 }
        )
        func backup(_ json: String) throws -> GeneralBackup {
            try JSONDecoder().decode(GeneralBackup.self, from: Data(json.utf8))
        }

        try backup(#"{"isPauseMediaEnabled":true}"#).restoreBrowserMediaPausing(in: controller)
        let afterMissingField = controller.isPauseBrowserMediaEnabled
        try backup(#"{"isPauseBrowserMediaEnabled":false}"#).restoreBrowserMediaPausing(in: controller)

        XCTAssertTrue(afterMissingField)
        XCTAssertFalse(controller.isPauseBrowserMediaEnabled)
        XCTAssertEqual(defaults.object(forKey: PlaybackController.pauseBrowserMediaKey) as? Bool, false)
    }
}
