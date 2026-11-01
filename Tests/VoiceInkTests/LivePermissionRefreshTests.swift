import Combine
import os
import SwiftUI
import XCTest

@testable import VoiceInk

@MainActor
final class LivePermissionRefreshTests: XCTestCase {
    private var permissions: FakePermissions!
    private var timers: FakeRepeatingTimers!

    override func setUp() {
        super.setUp()
        permissions = FakePermissions()
        timers = FakeRepeatingTimers()
    }

    private func makeMonitor() -> PermissionMonitor {
        let permissions = permissions!
        let timers = timers!
        return PermissionMonitor(
            client: PermissionClient { permissions.read() },
            makeTimer: { interval, tick in timers.make(interval: interval, tick: tick) },
            scheduleRead: { read, deliver in deliver(read()) },
            observesActivation: false
        )
    }

    // MARK: Polling lifetime

    func testPollingRunsOnlyWhileAnOwnerIsActive() {
        let monitor = makeMonitor()
        let owner = NSObject()
        XCTAssertFalse(monitor.isLiveRefreshing)
        XCTAssertTrue(timers.intervals.isEmpty)

        monitor.setLiveRefresh(true, for: owner)
        XCTAssertTrue(monitor.isLiveRefreshing)
        XCTAssertEqual(timers.intervals, [0.4])
        let readsWhileVisible = permissions.reads
        timers.fire()
        timers.fire()
        XCTAssertEqual(permissions.reads, readsWhileVisible + 2)

        monitor.setLiveRefresh(false, for: owner)
        XCTAssertFalse(monitor.isLiveRefreshing)
        XCTAssertEqual(timers.activeCount, 0)
        let readsAfterHiding = permissions.reads
        timers.fire()
        XCTAssertEqual(permissions.reads, readsAfterHiding)
    }

    func testOneTimerServesSeveralOwnersUntilTheLastLeaves() {
        let monitor = makeMonitor()
        let first = NSObject()
        let second = NSObject()

        monitor.setLiveRefresh(true, for: first)
        monitor.setLiveRefresh(true, for: second)
        monitor.setLiveRefresh(true, for: first)
        XCTAssertEqual(timers.intervals.count, 1)

        monitor.setLiveRefresh(false, for: first)
        XCTAssertTrue(monitor.isLiveRefreshing)
        monitor.setLiveRefresh(false, for: second)
        XCTAssertFalse(monitor.isLiveRefreshing)
    }

    func testReleasedOwnerStopsPollingAtTheNextTick() {
        let monitor = makeMonitor()
        var owner: NSObject? = NSObject()
        monitor.setLiveRefresh(true, for: owner!)
        let reads = permissions.reads

        owner = nil
        timers.fire()

        XCTAssertFalse(monitor.isLiveRefreshing)
        XCTAssertEqual(timers.activeCount, 0)
        XCTAssertEqual(permissions.reads, reads, "A tick after the owner left must not read permissions")
    }

    func testReleasedMonitorCancelsItsTimer() {
        var monitor: PermissionMonitor? = makeMonitor()
        let owner = NSObject()
        monitor?.setLiveRefresh(true, for: owner)
        XCTAssertEqual(timers.activeCount, 1)

        monitor = nil

        XCTAssertEqual(timers.activeCount, 0)
    }

    func testProductionTimerIsInvalidatedWithItsCancellable() {
        var ticks = 0
        var cancellable: AnyCancellable? = PermissionMonitor.mainRunLoopTimer(interval: 0.02) { ticks += 1 }
        let deadline = Date().addingTimeInterval(5)
        while ticks == 0 && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertGreaterThan(ticks, 0)

        cancellable = nil
        let ticksAtCancel = ticks
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))

        XCTAssertNil(cancellable)
        XCTAssertEqual(ticks, ticksAtCancel)
    }

    func testProductionReadsRunOffTheMainThreadAndPublishOnIt() async {
        let reads = OSAllocatedUnfairLock(initialState: [Bool]())
        let granted = OSAllocatedUnfairLock(initialState: false)
        let monitor = PermissionMonitor(
            client: PermissionClient {
                reads.withLock { $0.append(Thread.isMainThread) }
                return PermissionSnapshot(microphone: .granted, accessibility: granted.withLock { $0 }, screenRecording: false)
            },
            makeTimer: { _, _ in AnyCancellable {} }, observesActivation: false
        )
        let published = expectation(description: "grant published")
        let subscription = monitor.$snapshot.dropFirst().sink { snapshot in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertTrue(snapshot.accessibility)
            published.fulfill()
        }
        defer { subscription.cancel() }

        granted.withLock { $0 = true }
        monitor.refresh()
        await fulfillment(of: [published], timeout: 3)

        XCTAssertEqual(reads.withLock { $0 }, [true, false], "Only the launch read runs on the main thread")
    }

    func testRefreshesDuringASlowReadCoalesceIntoOneFurtherRead() {
        var pending: [() -> Void] = []
        var readCount = 0
        let monitor = PermissionMonitor(
            client: PermissionClient { PermissionSnapshot(microphone: .granted, accessibility: false, screenRecording: false) },
            makeTimer: { _, _ in AnyCancellable {} },
            scheduleRead: { read, deliver in
                readCount += 1
                pending.append { deliver(read()) }
            },
            observesActivation: false
        )

        monitor.refresh()
        monitor.refresh()
        monitor.refresh()
        XCTAssertEqual(readCount, 1)

        pending.removeFirst()()
        XCTAssertEqual(readCount, 2)
        pending.removeFirst()()
        XCTAssertEqual(readCount, 2)
        XCTAssertTrue(pending.isEmpty)
    }

    // MARK: Live grants

    func testSnapshotPublishesOnlyWhenAPermissionChanges() {
        let monitor = makeMonitor()
        var published: [PermissionSnapshot] = []
        let subscription = monitor.$snapshot.dropFirst().sink { published.append($0) }
        monitor.setLiveRefresh(true, for: self)

        timers.fire()
        timers.fire()
        XCTAssertTrue(published.isEmpty)

        permissions.snapshot.accessibility = true
        timers.fire()
        timers.fire()

        XCTAssertEqual(published.map(\.accessibility), [true])
        subscription.cancel()
        monitor.setLiveRefresh(false, for: self)
    }

    func testAccessibilityObserversRunAfterTheSnapshotChangesAndOnlyOnChange() async {
        let monitor = makeMonitor()
        var delivered: [(granted: Bool, snapshot: Bool)] = []
        let changed = expectation(description: "accessibility change delivered")
        let subscription = monitor.observeAccessibilityChanges { granted in
            delivered.append((granted, monitor.snapshot.accessibility))
            changed.fulfill()
        }

        permissions.snapshot.microphone = .granted
        monitor.refresh()
        permissions.snapshot.accessibility = true
        monitor.refresh()
        monitor.refresh()
        await fulfillment(of: [changed], timeout: 3)

        XCTAssertEqual(delivered.map(\.granted), [true])
        XCTAssertEqual(delivered.map(\.snapshot), [true], "Refreshes must read the granted value from the monitor")
        subscription.cancel()
    }

    func testModifierPollsOnlyWhileItsBranchIsShown() throws {
        let monitor = makeMonitor()
        let model = BranchModel()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: BranchView(model: model, monitor: monitor))
        defer { window.contentView = nil }

        func settle() {
            window.contentView?.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        settle()
        XCTAssertTrue(monitor.isLiveRefreshing, "The reminder is visible")

        model.showsReminder = false
        settle()
        XCTAssertFalse(monitor.isLiveRefreshing, "Insights replaced the reminder")

        model.showsReminder = true
        settle()
        XCTAssertTrue(monitor.isLiveRefreshing)

        window.contentView = NSHostingView(rootView: EmptyView())
        settle()
        XCTAssertFalse(monitor.isLiveRefreshing, "Removing the hosting view releases the owner")
    }

    func testOnboardingRowsFlipWhenMacOSGrantsDuringPolling() {
        let monitor = makeMonitor()
        let coordinator = OnboardingCoordinator(
            defaults: isolatedDefaults(), permissionMonitor: monitor
        )
        let subscription = monitor.$snapshot.dropFirst().sink { coordinator.permissions.apply($0) }
        coordinator.permissions.refreshPermissionStatuses()
        coordinator.permissions.setActivePermission(.accessibility)
        XCTAssertEqual(coordinator.permissions.status(for: .microphone), .needsAccess)
        XCTAssertEqual(coordinator.permissions.status(for: .accessibility), .needsAccess)
        monitor.setLiveRefresh(true, for: self)

        permissions.snapshot.microphone = .granted
        permissions.snapshot.accessibility = true
        timers.fire()

        XCTAssertEqual(coordinator.permissions.status(for: .microphone), .granted)
        XCTAssertEqual(coordinator.permissions.status(for: .accessibility), .granted)
        XCTAssertTrue(coordinator.requiredPermissionsGranted)
        XCTAssertEqual(coordinator.activePermission, .screenRecording)
        subscription.cancel()
        monitor.setLiveRefresh(false, for: self)
    }

    func testOnboardingMapsEveryMicrophoneState() {
        let cases: [(CapturePermission, OnboardingPermissionStatus)] = [
            (.granted, .granted), (.denied, .denied), (.restricted, .restricted), (.notDetermined, .needsAccess),
        ]
        for (microphone, expected) in cases {
            let snapshot = PermissionSnapshot(microphone: microphone, accessibility: false, screenRecording: true)

            XCTAssertEqual(OnboardingPermissionController.status(for: .microphone, in: snapshot), expected)
            XCTAssertEqual(OnboardingPermissionController.status(for: .screenRecording, in: snapshot), .granted)
        }
    }

    // MARK: Restart-needed detection

    func testAccessibilityGrantAfterLaunchIsRemembered() {
        let monitor = makeMonitor()
        XCTAssertTrue(monitor.hasObservedUntrustedAccessibility)

        permissions.snapshot.accessibility = true
        monitor.refresh()

        XCTAssertTrue(monitor.snapshot.accessibility)
        XCTAssertTrue(monitor.hasObservedUntrustedAccessibility)
    }

    func testAccessibilityPresentAtLaunchIsNotAGrantSinceLaunch() {
        permissions.snapshot.accessibility = true
        let monitor = makeMonitor()
        XCTAssertFalse(monitor.hasObservedUntrustedAccessibility)

        permissions.snapshot.accessibility = false
        monitor.refresh()

        XCTAssertTrue(monitor.hasObservedUntrustedAccessibility, "A later revocation makes a regrant a relaunch candidate")
    }

    func testHotkeyNeedsRestartOnlyForAGrantTheTapStillRefuses() {
        func resolve(monitoring: Bool = false, shortcut: Bool = true, trusted: Bool, sinceLaunch: Bool) -> RecordingHotkeyAvailability {
            RecordingHotkeyAvailability.resolve(
                isMonitoring: monitoring, hasShortcut: shortcut,
                accessibilityTrusted: trusted, accessibilityGrantedSinceLaunch: sinceLaunch
            )
        }

        XCTAssertEqual(resolve(trusted: true, sinceLaunch: true), .needsRestart)
        XCTAssertEqual(resolve(trusted: true, sinceLaunch: false), .unavailable)
        XCTAssertEqual(resolve(trusted: false, sinceLaunch: true), .needsAccessibility)
        XCTAssertEqual(resolve(monitoring: true, trusted: true, sinceLaunch: true), .available)
        XCTAssertEqual(resolve(monitoring: true, trusted: false, sinceLaunch: true), .available, "Carbon hot keys need no tap")
        XCTAssertEqual(resolve(shortcut: false, trusted: true, sinceLaunch: true), .unconfigured)
    }

    func testRestartNeededIsAShortcutIssueThatNamesTheRelaunch() {
        let readiness = CaptureReadiness(
            microphonePermission: .granted, hasMicrophone: true, accessibilityGranted: true, model: .ready, usesPaste: true
        )

        XCTAssertEqual(readiness.issues(for: .shortcutDictation, hotkey: .needsRestart), [.hotkey(.needsRestart)])
        XCTAssertTrue(readiness.issues(for: .onScreenDictation, hotkey: .needsRestart).isEmpty)
        XCTAssertTrue(RecordingHotkeyAvailability.needsRestart.message.contains("Restart VoiceInk"))
    }

    // MARK: Shortcut connections

    func testAccessibilityGrantRefreshesShortcutMonitoringWithoutActivation() async {
        let monitor = makeMonitor()
        let refreshed = expectation(description: "monitoring refreshed")
        var refreshes = 0
        let tracker = ShortcutPermissionTracker(
            permissionMonitor: monitor, notificationCenter: NotificationCenter(),
            refreshMonitoring: {
                refreshes += 1
                refreshed.fulfill()
            }
        )

        monitor.setLiveRefresh(true, for: self)
        permissions.snapshot.accessibility = true
        timers.fire()
        timers.fire()
        await fulfillment(of: [refreshed], timeout: 3)

        XCTAssertEqual(refreshes, 1)
        withExtendedLifetime(tracker) {}
        monitor.setLiveRefresh(false, for: self)
    }

    func testMonitoringChangeClearsAStaleRestartState() async {
        let monitor = makeMonitor()
        let center = NotificationCenter()
        var isMonitoring = false
        var published: [RecordingHotkeyAvailability] = []
        permissions.snapshot.accessibility = true
        monitor.refresh()
        let tracker = ShortcutPermissionTracker(
            permissionMonitor: monitor, notificationCenter: center,
            refreshMonitoring: {},
            availability: .init(
                isMonitoring: { isMonitoring }, hasShortcut: { true }, publish: { published.append($0) }
            )
        )
        tracker.updateAvailability()
        XCTAssertEqual(published, [.needsRestart])
        let recovered = expectation(description: "availability recomputed")
        let observer = center.addObserver(forName: ShortcutMonitor.captureAvailabilityDidChange, object: nil, queue: .main) { _ in
            DispatchQueue.main.async { recovered.fulfill() }
        }
        defer { center.removeObserver(observer) }

        // The health check installed the tap after the grant.
        isMonitoring = true
        center.post(name: ShortcutMonitor.captureAvailabilityDidChange, object: nil)
        await fulfillment(of: [recovered], timeout: 3)

        XCTAssertEqual(published, [.needsRestart, .available])
    }

    func testReleasedTrackerStopsReacting() async {
        let monitor = makeMonitor()
        let center = NotificationCenter()
        var refreshes = 0
        var publishes = 0
        var tracker: ShortcutPermissionTracker? = ShortcutPermissionTracker(
            permissionMonitor: monitor, notificationCenter: center,
            refreshMonitoring: { refreshes += 1 },
            availability: .init(isMonitoring: { false }, hasShortcut: { true }, publish: { _ in publishes += 1 })
        )
        XCTAssertNotNil(tracker)

        tracker = nil
        permissions.snapshot.accessibility = true
        monitor.refresh()
        center.post(name: ShortcutMonitor.captureAvailabilityDidChange, object: nil)
        await Task.yield()
        let drained = expectation(description: "main queue drained")
        DispatchQueue.main.async { drained.fulfill() }
        await fulfillment(of: [drained], timeout: 3)

        XCTAssertEqual(refreshes, 0)
        XCTAssertEqual(publishes, 0)
    }

    func testShortcutIssueRowOffersTheFixForEachStateAndPollsOnlyForAMissingGrant() {
        let expected: [(RecordingHotkeyAvailability, RecordingHotkeyAvailability.IssueAction?, Bool)] = [
            (.needsAccessibility, .openAccessibilitySettings, true),
            (.needsRestart, .restart, false),
            (.unavailable, .refresh, false),
            (.unconfigured, nil, false),
            (.available, nil, false),
        ]
        for (availability, action, polls) in expected {
            XCTAssertEqual(availability.issueAction, action, "\(availability)")
            XCTAssertEqual(availability.needsLivePermissionRefresh, polls, "\(availability)")
        }
    }

    func testIssueRowStopsPollingWhenAGrantTurnsIntoARestartOrRecovery() throws {
        let monitor = makeMonitor()
        let model = IssueRowModel()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: IssueRowView(model: model, monitor: monitor))
        defer { window.contentView = nil }
        func settle() {
            window.contentView?.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }

        settle()
        XCTAssertTrue(monitor.isLiveRefreshing)

        model.availability = .needsRestart
        settle()
        XCTAssertFalse(monitor.isLiveRefreshing, "A pending restart keeps the row without polling")

        model.availability = .needsAccessibility
        settle()
        XCTAssertTrue(monitor.isLiveRefreshing)

        model.availability = .available
        settle()
        XCTAssertFalse(monitor.isLiveRefreshing, "Recovery removes the row and its owner")
    }

    // MARK: Relaunch

    func testRelaunchIsBlockedWhileARecordingOrTestIsBusy() {
        var busy = true
        let recorder = RelaunchRecorder()
        let relauncher = recorder.relauncher(isBusy: { busy })

        XCTAssertFalse(relauncher.canRelaunch)
        XCTAssertFalse(relauncher.relaunch())
        XCTAssertTrue(recorder.helperCommands.isEmpty)
        XCTAssertEqual(recorder.terminations, 0)

        busy = false
        XCTAssertTrue(relauncher.canRelaunch)
        XCTAssertTrue(relauncher.relaunch())

        XCTAssertEqual(recorder.helperCommands.count, 1)
        XCTAssertEqual(recorder.helperCommands.first?.pid, 4242)
        XCTAssertEqual(recorder.helperCommands.first?.command, ["/usr/bin/open", "-n", "/Applications/VoiceInk Dev.app"])
        XCTAssertEqual(recorder.terminations, 1)
    }

    func testRelaunchRunsOnceWhileTerminationIsPending() {
        let recorder = RelaunchRecorder()
        let relauncher = recorder.relauncher(isBusy: { false })

        XCTAssertTrue(relauncher.relaunch())
        XCTAssertFalse(relauncher.canRelaunch)
        XCTAssertFalse(relauncher.relaunch())

        XCTAssertEqual(recorder.helperCommands.count, 1)
        XCTAssertEqual(recorder.terminations, 1)
    }

    func testHelperFailureKeepsVoiceInkRunning() {
        let recorder = RelaunchRecorder()
        recorder.helperError = CocoaError(.executableNotLoadable)
        let relauncher = recorder.relauncher(isBusy: { false })

        XCTAssertFalse(relauncher.relaunch())

        XCTAssertEqual(recorder.terminations, 0)
        XCTAssertTrue(relauncher.canRelaunch)
    }

    func testEveryActiveRecordingPhasePipelineFinalizationAndMicrophoneTestBlocksRelaunch() {
        func blocks(
            _ state: RecordingState = .idle, pipelines: Int = 0, finalization: Bool = false, test: Bool = false
        ) -> Bool {
            AppRelauncher.blocksRelaunch(
                recordingState: state, unfinishedPipelines: pipelines, finalizationRunning: finalization,
                microphoneTestBusy: test
            )
        }
        for state in [RecordingState.starting, .recording, .transcribing, .enhancing, .busy] {
            XCTAssertTrue(blocks(state), "\(state)")
        }
        XCTAssertTrue(blocks(pipelines: 1), "Cancel sets idle before a canceled pipeline saves History")
        XCTAssertTrue(blocks(finalization: true))
        XCTAssertTrue(blocks(test: true))
        XCTAssertFalse(blocks())
    }

    func testHelperWaitsForTheProcessToExitBeforeReopening() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = directory.appendingPathComponent("reopened")
        let running = Process()
        running.executableURL = URL(fileURLWithPath: "/bin/sleep")
        running.arguments = ["0.6"]
        try running.run()

        try AppRelauncher.launchWaitingHelper(
            processIdentifier: running.processIdentifier, command: ["/usr/bin/touch", marker.path]
        )
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertTrue(running.isRunning)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))

        running.waitUntilExit()
        let deadline = Date().addingTimeInterval(3)
        while !FileManager.default.fileExists(atPath: marker.path) && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
    }

    private func isolatedDefaults() -> UserDefaults {
        let suiteName = "LivePermissionRefreshTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        return defaults
    }
}

private final class BranchModel: ObservableObject {
    @Published var showsReminder = true
}

private struct BranchView: View {
    @ObservedObject var model: BranchModel
    let monitor: PermissionMonitor

    var body: some View {
        if model.showsReminder {
            Text("Allow Accessibility").livePermissionRefresh(monitor: monitor)
        } else {
            Text("Insights")
        }
    }
}

private final class IssueRowModel: ObservableObject {
    @Published var availability = RecordingHotkeyAvailability.needsAccessibility
}

/// Mirrors Settings' shortcut issue row: shown for an issue action, polling while a grant is missing.
private struct IssueRowView: View {
    @ObservedObject var model: IssueRowModel
    let monitor: PermissionMonitor

    var body: some View {
        if model.availability.issueAction != nil {
            Text(model.availability.message)
                .livePermissionRefresh(isActive: model.availability.needsLivePermissionRefresh, monitor: monitor)
        }
    }
}

private final class FakePermissions: @unchecked Sendable {
    var snapshot = PermissionSnapshot(microphone: .notDetermined, accessibility: false, screenRecording: false)
    private(set) var reads = 0

    func read() -> PermissionSnapshot {
        reads += 1
        return snapshot
    }
}

private final class FakeRepeatingTimers {
    private(set) var intervals: [TimeInterval] = []
    private var active: [Int: @MainActor () -> Void] = [:]
    private var nextID = 0

    var activeCount: Int { active.count }

    func make(interval: TimeInterval, tick: @escaping @MainActor () -> Void) -> AnyCancellable {
        intervals.append(interval)
        let id = nextID
        nextID += 1
        active[id] = tick
        return AnyCancellable { [weak self] in self?.active[id] = nil }
    }

    @MainActor
    func fire() {
        for tick in active.sorted(by: { $0.key < $1.key }).map(\.value) { tick() }
    }
}

@MainActor
private final class RelaunchRecorder {
    var helperCommands: [(pid: Int32, command: [String])] = []
    var helperError: Error?
    var terminations = 0
    let gate = AppRelaunchGate()

    func relauncher(isBusy: @escaping () -> Bool) -> AppRelauncher {
        AppRelauncher(
            isBusy: isBusy,
            bundleURL: URL(fileURLWithPath: "/Applications/VoiceInk Dev.app"),
            processIdentifier: 4242,
            launchHelper: { [unowned self] pid, command in
                if let helperError { throw helperError }
                helperCommands.append((pid, command))
            },
            terminate: { [unowned self] in terminations += 1 },
            gate: gate
        )
    }
}
