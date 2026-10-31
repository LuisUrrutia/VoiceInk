import AppKit
import Carbon.HIToolbox
import CoreGraphics
import Foundation
import os

@MainActor
final class ShortcutMonitor {
    nonisolated static let captureAvailabilityDidChange = Notification.Name("ShortcutCaptureAvailabilityDidChange")
    typealias EventTapFactory = @Sendable (CGEventMask, @escaping @Sendable (CGEventType, CGEvent) -> Bool) throws -> any ShortcutEventTap
    typealias PhysicalKeyTapFactory = @Sendable (@escaping @Sendable (CGEventType, CGEvent) -> Bool) throws -> any ShortcutEventTap
    typealias ShortcutCallback = @MainActor (ShortcutAction, TimeInterval) async -> Void

    /// Listen-only HID tap for key presses that other apps' global hot keys consume before the session.
    /// Accessibility covers it; without the tap those chords simply go unseen.
    nonisolated static let systemPhysicalKeyTap: PhysicalKeyTapFactory = {
        try SystemShortcutEventTap(
            eventsOfInterest: CGEventMask(1) << CGEventType.keyDown.rawValue,
            location: .cghidEventTap,
            options: .listenOnly,
            handler: $0
        )
    }

    private let worker: ShortcutMonitorWorker
    private let tapThread = ShortcutEventTapThread.shared
    // Carbon hot keys keep keyed shortcuts working during Secure Event Input.
    private var systemHotKeys: [ShortcutAction: SystemHotKey] = [:]
    private var systemHotKeyShortcuts: [ShortcutAction: Shortcut] = [:]
    private let workspaceNotificationCenter: NotificationCenter
    private let isSecureEventInputEnabled: @MainActor () -> Bool
    private var lifecycleObservers: [NSObjectProtocol] = []

    init(
        owner: String = "shortcuts",
        makeEventTap: @escaping EventTapFactory = {
            try SystemShortcutEventTap(eventsOfInterest: $0, handler: $1)
        },
        isKeyDown: @escaping @Sendable (UInt16) -> Bool = { CGEventSource.keyState(.combinedSessionState, key: $0) },
        isShortcutPressed: @escaping @Sendable (Shortcut) -> Bool = { $0.isCurrentlyPressed },
        heldRecordingShortcut: @escaping @Sendable () -> Shortcut? = { nil },
        allowsInput: @escaping @Sendable () -> Bool = { UserSessionInputPolicy.allowsShortcutHandling },
        allowsDispatch: @escaping @MainActor @Sendable () -> Bool = { UserSessionInputPolicy.allowsShortcutDispatch },
        isSecureEventInputEnabled: @escaping @MainActor () -> Bool = { IsSecureEventInputEnabled() },
        makePhysicalKeyTap: PhysicalKeyTapFactory? = nil,
        physicalModifierFlags: @escaping @Sendable () -> CGEventFlags = { CGEventSource.flagsState(.hidSystemState) },
        postChordBreaker: @escaping @Sendable (CGEventFlags) -> Bool = { ChordBreakerPoster.shared.post(flags: $0) },
        workspaceNotificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter
    ) {
        UserSessionInputPolicy.startObserving()
        worker = ShortcutMonitorWorker(
            owner: owner,
            makeEventTap: makeEventTap,
            isKeyDown: isKeyDown,
            isShortcutPressed: isShortcutPressed,
            heldRecordingShortcut: heldRecordingShortcut,
            allowsInput: allowsInput,
            allowsDispatch: allowsDispatch,
            makePhysicalKeyTap: makePhysicalKeyTap,
            physicalModifierFlags: physicalModifierFlags,
            postChordBreaker: postChordBreaker
        )
        self.workspaceNotificationCenter = workspaceNotificationCenter
        self.isSecureEventInputEnabled = isSecureEventInputEnabled
        ShortcutDiagnostics.register(self, owner: owner)
        for (name, reason) in [
            (NSWorkspace.didWakeNotification, "wake"),
            (NSWorkspace.screensDidWakeNotification, "display-wake"),
            (NSWorkspace.sessionDidBecomeActiveNotification, "session-active"),
        ] {
            lifecycleObservers.append(workspaceNotificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.recoverEventTap(reason: reason) }
            })
        }
    }

    @discardableResult
    func start(
        shortcuts: [ShortcutAction: Shortcut],
        interruptibleActions: Set<ShortcutAction> = [],
        standaloneModifierActions: Set<ShortcutAction> = [],
        chordBreakerDelays: [ShortcutAction: TimeInterval] = [:],
        reservedShortcuts: [Shortcut] = [],
        onShortcutDown: @escaping ShortcutCallback,
        onShortcutUp: @escaping ShortcutCallback,
        onShortcutInterrupted: ShortcutCallback? = nil,
        onStandaloneModifierChord: (@MainActor (ShortcutAction) -> Void)? = nil,
        onMonitoringReset: (@MainActor (Set<ShortcutAction>) -> Void)? = nil,
        onMissedRelease: (@MainActor (ShortcutAction) -> Void)? = nil,
        onPressCaptured: (@Sendable (ShortcutAction, TimeInterval) -> Void)? = nil,
        reason: String = "refresh"
    ) -> Bool {
        let systemHotKeyActions = registerSystemHotKeys(for: shortcuts)
        let worker = worker
        let isTapEnabled = tapThread.performAndWait {
            worker.start(
                shortcuts: shortcuts,
                interruptibleActions: interruptibleActions,
                standaloneModifierActions: standaloneModifierActions,
                chordBreakerDelays: chordBreakerDelays,
                systemHotKeyActions: systemHotKeyActions,
                reservedShortcuts: reservedShortcuts,
                onShortcutDown: onShortcutDown,
                onShortcutUp: onShortcutUp,
                onShortcutInterrupted: onShortcutInterrupted,
                onStandaloneModifierChord: onStandaloneModifierChord,
                onMonitoringReset: onMonitoringReset,
                onMissedRelease: onMissedRelease,
                onPressCaptured: onPressCaptured,
                reason: reason
            )
        }
        return isTapEnabled || systemHotKeyActions.count == shortcuts.count
    }

    private func registerSystemHotKeys(for shortcuts: [ShortcutAction: Shortcut]) -> Set<ShortcutAction> {
        // Release changed registrations first so swapped combinations can be registered again.
        for (action, shortcut) in systemHotKeyShortcuts where shortcuts[action] != shortcut {
            systemHotKeys[action] = nil
            systemHotKeyShortcuts[action] = nil
        }
        for (action, shortcut) in shortcuts where systemHotKeys[action] == nil {
            guard let modifiers = shortcut.systemHotKeyModifiers,
                let hotKey = SystemHotKey(keyCode: shortcut.keyCode, modifiers: modifiers, onChange: { [weak self] isDown, eventTime in
                    MainActor.assumeIsolated {
                        self?.handleSystemHotKey(action: action, isDown: isDown, eventTime: eventTime)
                    }
                })
            else { continue }
            systemHotKeys[action] = hotKey
            systemHotKeyShortcuts[action] = shortcut
        }
        return Set(systemHotKeys.keys)
    }

    func handleSystemHotKey(action: ShortcutAction, isDown: Bool, eventTime: TimeInterval) {
        guard let shortcut = systemHotKeyShortcuts[action] else { return }
        let worker = worker
        tapThread.performAndWait {
            worker.handleSystemHotKey(action: action, shortcut: shortcut, isDown: isDown, eventTime: eventTime)
        }
    }

    func isMonitoring(_ action: ShortcutAction) -> Bool {
        if systemHotKeys[action] != nil { return true }
        let worker = worker
        return tapThread.performAndWait { worker.isMonitoring(action) }
    }

    func earlyCaptureAvailability(for actions: Set<ShortcutAction>) -> Bool? {
        let worker = worker
        guard let available = tapThread.performAndWait({ worker.earlyCaptureAvailability(for: actions) }) else {
            return nil
        }
        return available && !isSecureEventInputEnabled()
    }

    func updateStandaloneModifierActions(_ actions: Set<ShortcutAction>, chordBreakerDelays: [ShortcutAction: TimeInterval]) {
        let worker = worker
        tapThread.performAndWait { worker.updateStandaloneModifierActions(actions, chordBreakerDelays: chordBreakerDelays) }
    }

    func resetShortcutStates(for actions: Set<ShortcutAction>) {
        let worker = worker
        tapThread.performAndWait { worker.resetShortcutStates(for: actions) }
    }

    func stop(reason: String = "stop") {
        systemHotKeys = [:]
        systemHotKeyShortcuts = [:]
        let worker = worker
        tapThread.performAndWait { worker.stop(reason: reason) }
    }

    func recoverEventTap(reason: String = "health-check") {
        let worker = worker
        tapThread.performAndWait { worker.recoverEventTap(reason: reason) }
    }

    var diagnosticSummary: String {
        let worker = worker
        return tapThread.performAndWait { worker.diagnosticSummary }
    }

    isolated deinit {
        for observer in lifecycleObservers { workspaceNotificationCenter.removeObserver(observer) }
        stop()
    }
}

/// Keeps matching and recovery on the tap thread; dispatch reads a locked snapshot.
private final class ShortcutMonitorWorker: @unchecked Sendable {
    typealias EventTapFactory = ShortcutMonitor.EventTapFactory
    typealias ShortcutCallback = ShortcutMonitor.ShortcutCallback

    fileprivate enum EventKind {
        case keyDown
        case keyUp
        case flagsChanged
        case mouseDown
        case mouseDragged
        case mouseUp
    }

    private struct ShortcutState {
        var shortcut: Shortcut
        var isDown = false
        var pressedAt: TimeInterval?
        var isInterrupted = false
        var requiresStandaloneRelease = false
        var recoveredMissedRelease = false
        var modifierFlagsAtPress: NSEvent.ModifierFlags = []
        // A physical key pressed after this press reached the HID tap first: the press never dispatches.
        var isDropped = false
    }

    private var shortcuts: [ShortcutAction: ShortcutState] = [:]
    private var pressedKeyCodes = Set<UInt16>()
    private var suppressedMouseButtons = Set<UInt16>()
    private var interruptibleActions: Set<ShortcutAction> = []
    private var standaloneModifierActions: Set<ShortcutAction> = []
    private var chordBreakerDelays: [ShortcutAction: TimeInterval] = [:]
    private var chordBreakerTimers: [ShortcutAction: Timer] = [:]
    private var physicalKeyTap: (any ShortcutEventTap)?
    private var physicalKeyTapRevision: UInt64 = 0
    private var physicalKeyTapIssue = "none"
    private var lastPhysicalKeyTapFailureLogAt: TimeInterval?
    // Recent HID key presses, which another app's global hot key may have hidden from the session.
    private var physicalKeyDowns: [(time: TimeInterval, modifierFlags: NSEvent.ModifierFlags)] = []
    // Registered hot keys own exact presses of these actions.
    private var systemHotKeyActions: Set<ShortcutAction> = []
    private var reservedShortcuts: [Shortcut] = []
    private var onPressCaptured: (@Sendable (ShortcutAction, TimeInterval) -> Void)?
    private var onShortcutDown: ShortcutCallback?
    private var onShortcutUp: ShortcutCallback?
    private var onShortcutInterrupted: ShortcutCallback?
    private var onStandaloneModifierChord: (@MainActor (ShortcutAction) -> Void)?
    private var onMonitoringReset: (@MainActor (Set<ShortcutAction>) -> Void)?
    private var onMissedRelease: (@MainActor (ShortcutAction) -> Void)?
    private var eventTap: (any ShortcutEventTap)?
    private var recoveryTimer: Timer?
    private var generation: UInt64 = 0
    private var actionRevisions: [ShortcutAction: UInt64] = [:]
    private var nextActionRevision: UInt64 = 0
    private let makeEventTap: EventTapFactory
    private let isKeyDown: @Sendable (UInt16) -> Bool
    private let isShortcutPressed: @Sendable (Shortcut) -> Bool
    private let heldRecordingShortcut: @Sendable () -> Shortcut?
    private let allowsInput: @Sendable () -> Bool
    private let allowsDispatch: @MainActor @Sendable () -> Bool
    private let makePhysicalKeyTap: ShortcutMonitor.PhysicalKeyTapFactory?
    private let physicalModifierFlags: @Sendable () -> CGEventFlags
    private let postChordBreaker: @Sendable (CGEventFlags) -> Bool
    private let owner: String
    private var keyDownCount = 0
    private var keyUpCount = 0
    private var modifierEventCount = 0
    private var mouseEventCount = 0
    private var lastEventAt: TimeInterval?
    private var lastMatchAt: TimeInterval?
    private var lastInputAllowed: Bool?
    private var installFailures = 0
    private var lastInstallFailureLogAt: TimeInterval?
    private var lastTapIssue = "none"
    private var ignoredModifierChords = 0
    private var lastModifierMismatch = "none"
    private var lastModifierMismatchAt: TimeInterval?
    private var recoveredPresses = 0
    private var ignoredRepeats = 0
    private var lastRepeatLogAt: TimeInterval?
    private var physicalChords = 0
    private var chordBreakersPosted = 0

    private struct DispatchSnapshot: Sendable {
        var generation: UInt64 = 0
        var revisions: [ShortcutAction: UInt64] = [:]
    }
    private let dispatchValidity = OSAllocatedUnfairLock(initialState: DispatchSnapshot())

    private static let shortcutInterruptionWindow: TimeInterval = 1.0
    // Hex's MINIMUM_HOLD_DURATION: HID evidence this soon after a press can overtake its session event.
    private static let physicalChordOvertakeWindow: TimeInterval = 0.3
    private static let physicalKeyDownHistory = 8
    private static let recoveryCheckInterval: TimeInterval = 10.0

    init(
        owner: String,
        makeEventTap: @escaping EventTapFactory,
        isKeyDown: @escaping @Sendable (UInt16) -> Bool,
        isShortcutPressed: @escaping @Sendable (Shortcut) -> Bool,
        heldRecordingShortcut: @escaping @Sendable () -> Shortcut?,
        allowsInput: @escaping @Sendable () -> Bool,
        allowsDispatch: @escaping @MainActor @Sendable () -> Bool,
        makePhysicalKeyTap: ShortcutMonitor.PhysicalKeyTapFactory?,
        physicalModifierFlags: @escaping @Sendable () -> CGEventFlags,
        postChordBreaker: @escaping @Sendable (CGEventFlags) -> Bool
    ) {
        self.makePhysicalKeyTap = makePhysicalKeyTap
        self.physicalModifierFlags = physicalModifierFlags
        self.postChordBreaker = postChordBreaker
        self.makeEventTap = makeEventTap
        self.isKeyDown = isKeyDown
        self.isShortcutPressed = isShortcutPressed
        self.heldRecordingShortcut = heldRecordingShortcut
        self.allowsInput = allowsInput
        self.allowsDispatch = allowsDispatch
        self.owner = owner
    }

    @discardableResult
    func start(
        shortcuts: [ShortcutAction: Shortcut],
        interruptibleActions: Set<ShortcutAction> = [],
        standaloneModifierActions: Set<ShortcutAction> = [],
        chordBreakerDelays: [ShortcutAction: TimeInterval] = [:],
        systemHotKeyActions: Set<ShortcutAction> = [],
        reservedShortcuts: [Shortcut] = [],
        onShortcutDown: @escaping ShortcutCallback,
        onShortcutUp: @escaping ShortcutCallback,
        onShortcutInterrupted: ShortcutCallback? = nil,
        onStandaloneModifierChord: (@MainActor (ShortcutAction) -> Void)? = nil,
        onMonitoringReset: (@MainActor (Set<ShortcutAction>) -> Void)? = nil,
        onMissedRelease: (@MainActor (ShortcutAction) -> Void)? = nil,
        onPressCaptured: (@Sendable (ShortcutAction, TimeInterval) -> Void)? = nil,
        reason: String = "refresh"
    ) -> Bool {
        defer { notifyCaptureAvailabilityChanged() }
        guard !shortcuts.isEmpty else {
            stop(reason: reason)
            return true
        }

        let changedActions = Set(self.shortcuts.keys).union(shortcuts.keys).filter { action in
            self.shortcuts[action]?.shortcut != shortcuts[action]
                || self.interruptibleActions.contains(action) != interruptibleActions.contains(action)
                || self.standaloneModifierActions.contains(action) != standaloneModifierActions.contains(action)
                || self.systemHotKeyActions.contains(action) != systemHotKeyActions.contains(action)
        }
        resetShortcutStates(for: changedActions.intersection(self.shortcuts.keys))
        self.shortcuts = shortcuts.reduce(into: [:]) { result, entry in
            result[entry.key] = self.shortcuts[entry.key] ?? ShortcutState(shortcut: entry.value)
            if changedActions.contains(entry.key) {
                result[entry.key] = ShortcutState(shortcut: entry.value)
                advanceRevision(for: entry.key)
            }
        }
        actionRevisions = actionRevisions.filter { shortcuts[$0.key] != nil }
        publishDispatchValidity()
        self.reservedShortcuts = reservedShortcuts
        ShortcutDiagnostics.notice("monitor owner=\(owner) generation=\(generation) reason=\(reason) shortcuts={\(shortcutSummary)}\(reservedShortcutSummary)")

        self.interruptibleActions = interruptibleActions
        self.standaloneModifierActions = standaloneModifierActions
        self.chordBreakerDelays = chordBreakerDelays
        self.systemHotKeyActions = systemHotKeyActions
        self.onPressCaptured = onPressCaptured
        self.onShortcutDown = onShortcutDown
        self.onShortcutUp = onShortcutUp
        self.onShortcutInterrupted = onShortcutInterrupted
        self.onStandaloneModifierChord = onStandaloneModifierChord
        self.onMonitoringReset = onMonitoringReset
        self.onMissedRelease = onMissedRelease

        if eventTap == nil {
            _ = installEventTap()
        } else {
            recoverEventTap(reason: reason)
        }
        // Recover from missed tap-disable notifications.
        if recoveryTimer == nil {
            let timer = Timer(timeInterval: Self.recoveryCheckInterval, repeats: true) { [weak self] _ in
                self?.recoverEventTap()
            }
            timer.tolerance = 0.2
            recoveryTimer = timer
            RunLoop.current.add(timer, forMode: .common)
        }
        updatePhysicalKeyTap()
        return eventTap?.isEnabled == true
    }

    func updateStandaloneModifierActions(_ actions: Set<ShortcutAction>, chordBreakerDelays: [ShortcutAction: TimeInterval]) {
        resetShortcutStates(for: standaloneModifierActions.symmetricDifference(actions).intersection(shortcuts.keys))
        standaloneModifierActions = actions
        self.chordBreakerDelays = chordBreakerDelays
        updatePhysicalKeyTap()
    }

    func resetShortcutStates(for actions: Set<ShortcutAction>) {
        let monitoredActions = actions.intersection(shortcuts.keys)
        guard !monitoredActions.isEmpty else { return }
        for action in monitoredActions {
            guard let state = shortcuts[action] else { continue }
            shortcuts[action] = ShortcutState(shortcut: state.shortcut)
            advanceRevision(for: action)
        }
        notifyMonitoringReset(monitoredActions)
    }

    private func advanceRevision(for action: ShortcutAction) {
        nextActionRevision &+= 1
        actionRevisions[action] = nextActionRevision
        publishDispatchValidity()
    }

    private func publishDispatchValidity() {
        dispatchValidity.withLock {
            $0 = DispatchSnapshot(generation: generation, revisions: actionRevisions)
        }
    }

    private func notifyMonitoringReset(_ actions: Set<ShortcutAction>) {
        guard !actions.isEmpty, let callback = onMonitoringReset else { return }
        DispatchQueue.main.async { callback(actions) }
    }

    private func observeEnvironment(reason: String) {
        DispatchQueue.main.async { ShortcutDiagnostics.observeEnvironment(reason: reason) }
    }

    func stop(reason: String = "stop") {
        defer { notifyCaptureAvailabilityChanged() }
        if !shortcuts.isEmpty {
            ShortcutDiagnostics.notice("monitor owner=\(owner) generation=\(generation) result=stopped reason=\(reason) pressed=\(pressedActionSummary)")
        }
        generation &+= 1
        publishDispatchValidity()
        recoveryTimer?.invalidate()
        recoveryTimer = nil
        eventTap?.stop()
        eventTap = nil
        physicalKeyTap?.stop()
        physicalKeyTap = nil
        physicalKeyDowns = []
        chordBreakerTimers.values.forEach { $0.invalidate() }
        chordBreakerTimers = [:]
        notifyMonitoringReset(Set(shortcuts.keys))

        shortcuts = [:]
        actionRevisions = [:]
        pressedKeyCodes = []
        suppressedMouseButtons = []
        interruptibleActions = []
        standaloneModifierActions = []
        chordBreakerDelays = [:]
        systemHotKeyActions = []
        reservedShortcuts = []
        onPressCaptured = nil
        onShortcutDown = nil
        onShortcutUp = nil
        onShortcutInterrupted = nil
        onStandaloneModifierChord = nil
        onMonitoringReset = nil
        onMissedRelease = nil
        publishDispatchValidity()
    }

    private func installEventTap() -> Bool {
        let installedGeneration = generation
        do {
            eventTap = try makeEventTap(Self.eventMask) { [weak self] type, event in
                guard let self, self.generation == installedGeneration else { return false }
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    let reason = type == .tapDisabledByTimeout ? "timeout" : "user-input"
                    self.lastTapIssue = reason
                    ShortcutDiagnostics.warning("tap owner=\(self.owner) generation=\(self.generation) result=disabled reason=\(reason) pressed=\(self.pressedActionSummary)")
                    self.recoverEventTap(reason: reason)
                    return false
                }
                return self.handleCGEvent(type: type, event: event)
            }
            ShortcutDiagnostics.notice("tap owner=\(owner) generation=\(generation) result=installed enabled=\(eventTap?.isEnabled == true) tapThread=\(ShortcutEventTapThread.shared.isCurrent) mainThread=\(Thread.isMainThread) failedAttempts=\(installFailures)")
            lastInstallFailureLogAt = nil
            return true
        } catch {
            installFailures += 1
            if case ShortcutEventTapError.runLoopSourceFailed = error {
                lastTapIssue = "run-loop-source-failed"
            } else if case ShortcutEventTapError.enableFailed = error {
                lastTapIssue = "enable-failed"
            } else {
                lastTapIssue = "creation-failed"
            }
            let now = ProcessInfo.processInfo.systemUptime
            if lastInstallFailureLogAt.map({ now - $0 >= 60 }) ?? true {
                lastInstallFailureLogAt = now
                ShortcutDiagnostics.error("tap owner=\(owner) generation=\(generation) result=install-failed reason=\(lastTapIssue) attempts=\(installFailures)")
                observeEnvironment(reason: "tap-install-failed")
            }
            return false
        }
    }

    func recoverEventTap(reason: String = "health-check") {
        defer {
            updatePhysicalKeyTap()
            notifyCaptureAvailabilityChanged()
        }
        guard !shortcuts.isEmpty else { return }
        observeEnvironment(reason: reason)
        let inputAllowed = observeInputPolicy()
        guard let eventTap, eventTap.isValid else {
            if self.eventTap != nil {
                lastTapIssue = "invalid"
                ShortcutDiagnostics.warning("tap owner=\(owner) result=invalid reason=\(reason) pressed=\(pressedActionSummary)")
            }
            rebuildEventTap(reason: reason)
            return
        }
        guard !eventTap.isEnabled else { return }
        if reason == "health-check" { lastTapIssue = "disabled-at-health-check" }
        // Enable before checking held keys to avoid missing a release.
        eventTap.enable()
        if inputAllowed {
            // Preserve shortcuts that are still physically held.
            let releasedActions = Set(shortcuts.compactMap { action, state in
                systemHotKeyActions.contains(action)
                    || (state.isDown && !state.requiresStandaloneRelease && isShortcutPressed(state.shortcut)) ? nil : action
            })
            resetShortcutStates(for: releasedActions)
            pressedKeyCodes = pressedKeyCodes.filter(isKeyDown)
            suppressedMouseButtons = Set(shortcuts.values.compactMap { state in
                state.isDown && state.shortcut.kind == .mouseButton ? state.shortcut.keyCode : nil
            })
        }
        if eventTap.isEnabled {
            lastInstallFailureLogAt = nil
            ShortcutDiagnostics.notice("tap owner=\(owner) result=re-enabled reason=\(reason)")
        } else {
            lastTapIssue = "re-enable-failed"
            let now = ProcessInfo.processInfo.systemUptime
            if lastInstallFailureLogAt.map({ now - $0 >= 60 }) ?? true {
                lastInstallFailureLogAt = now
                ShortcutDiagnostics.error("tap owner=\(owner) result=re-enable-failed reason=\(reason)")
            }
            // Recreate once; later failures wait for the health check.
            rebuildEventTap(reason: "re-enable-failed.\(reason)")
        }
    }

    private func rebuildEventTap(reason: String) {
        generation &+= 1
        publishDispatchValidity()
        eventTap?.stop()
        eventTap = nil
        resetShortcutStates(for: Set(shortcuts.keys).subtracting(systemHotKeyActions))
        pressedKeyCodes.removeAll()
        suppressedMouseButtons.removeAll()
        ShortcutDiagnostics.notice("tap owner=\(owner) result=rebuilding reason=\(reason)")
        _ = installEventTap()
    }

    private func observeInputPolicy() -> Bool {
        let allowed = allowsInput()
        if lastInputAllowed != allowed {
            lastInputAllowed = allowed
            // Invalidate queued actions even when their keys are already released.
            if !allowed { clearPressedShortcutState() }
            ShortcutDiagnostics.notice("monitor owner=\(owner) inputAllowed=\(allowed)")
        }
        return allowed
    }

    private func handleCGEvent(type: CGEventType, event: CGEvent) -> Bool {
        // The chord breaker passes on to other apps' taps; the annotated-session filter drops it.
        guard !ChordBreaker.isMarked(event) else { return false }
        lastEventAt = ProcessInfo.processInfo.systemUptime
        switch type {
        case .keyDown: keyDownCount += 1
        case .keyUp: keyUpCount += 1
        case .flagsChanged: modifierEventCount += 1
        default: mouseEventCount += 1
        }
        guard let eventKind = EventKind(type) else {
            return false
        }

        let inputCode: UInt16
        switch eventKind {
        case .keyDown, .keyUp, .flagsChanged:
            inputCode = UInt16(clamping: event.getIntegerValueField(.keyboardEventKeycode))
        case .mouseDown, .mouseDragged, .mouseUp:
            inputCode = UInt16(clamping: event.getIntegerValueField(.mouseEventButtonNumber))
        }

        let modifierFlags = NSEvent.ModifierFlags(rawValue: UInt(event.flags.rawValue))
        let isAutoRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        let inputAllowed = observeInputPolicy()
        let relevantActions = shortcuts.filter { _, state in
            switch state.shortcut.kind {
            case .key:
                return (eventKind == .keyDown || eventKind == .keyUp) && state.shortcut.keyCode == inputCode
                    && (state.isDown || ShortcutDiagnostics.shouldTraceKey(code: inputCode, flags: modifierFlags))
            case .mouseButton: return (eventKind == .mouseDown || eventKind == .mouseUp) && state.shortcut.keyCode == inputCode
            case .modifierOnly:
                return eventKind == .flagsChanged && (state.shortcut.keyCode == inputCode || state.shortcut.keyCode == UInt16.max)
            }
        }.keys.map(\.storageName).sorted().joined(separator: ",")
        if !relevantActions.isEmpty, !isAutoRepeat {
            ShortcutDiagnostics.notice("input owner=\(owner) generation=\(generation) event=\(eventKind) code=\(inputCode) flags=0x\(String(modifierFlags.rawValue, radix: 16)) repeat=false timestamp=\(event.timestamp) sourcePID=\(event.getIntegerValueField(.eventSourceUnixProcessID)) actions=\(relevantActions) pressed=\(pressedActionSummary) inputAllowed=\(inputAllowed) capture=\(ShortcutDiagnostics.captureSummary)")
        }
        guard inputAllowed else {
            if !relevantActions.isEmpty {
                ShortcutDiagnostics.notice("input owner=\(owner) result=ignored reason=session-input-policy actions=\(relevantActions)")
            }
            return false
        }
        return handleEvent(
            kind: eventKind,
            inputCode: inputCode,
            modifierFlags: modifierFlags,
            // Session timestamps use nanoseconds since boot.
            eventTime: event.timestamp == 0
                ? ProcessInfo.processInfo.systemUptime
                : TimeInterval(event.timestamp) / 1_000_000_000,
            isAutoRepeat: isAutoRepeat,
            isChordEvidence: !Self.isPostedByThisProcess(event)
        )
    }

    // VoiceInk's own paste and typing events are not the user's chord.
    private static func isPostedByThisProcess(_ event: CGEvent) -> Bool {
        event.getIntegerValueField(.eventSourceUnixProcessID) == Int64(getpid())
    }

    private func clearPressedShortcutState() {
        if shortcuts.values.contains(where: { $0.isDown }) {
            ShortcutDiagnostics.notice("monitor owner=\(owner) result=release-reset pressed=\(pressedActionSummary)")
        }
        // Clear unresolved presses without firing release actions.
        resetShortcutStates(for: Set(shortcuts.keys))
        pressedKeyCodes.removeAll()
        suppressedMouseButtons.removeAll()
    }

    private func handleEvent(
        kind: EventKind,
        inputCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags,
        eventTime: TimeInterval,
        isAutoRepeat: Bool,
        isChordEvidence: Bool
    ) -> Bool {
        var shouldSuppress: Bool
        switch kind {
        case .mouseDragged:
            shouldSuppress = suppressedMouseButtons.contains(inputCode)
        case .mouseUp:
            shouldSuppress = suppressedMouseButtons.remove(inputCode) != nil
        case .keyDown, .keyUp, .flagsChanged, .mouseDown:
            shouldSuppress = false
        }

        updatePressedKeyCodes(kind: kind, inputCode: inputCode)
        if isChordEvidence {
            invalidateStandaloneModifierCandidateForKeyboardEvent(
                kind: kind,
                inputCode: inputCode,
                modifierFlags: modifierFlags
            )
        }

        if kind == .keyDown, isChordEvidence {
            handleShortcutInterruptions(keyCode: inputCode, modifierFlags: modifierFlags, eventTime: eventTime)
        }

        for action in Array(shortcuts.keys) {
            guard var state = shortcuts[action] else {
                continue
            }
            if systemHotKeyActions.contains(action) {
                if kind == .keyDown, !isAutoRepeat,
                    matchesInput(state.shortcut, kind: kind, inputCode: inputCode, modifierFlags: modifierFlags)
                {
                    onPressCaptured?(action, eventTime)
                }
                // Hot keys own exact presses; the tap still matches cancellation with held recording modifiers.
                guard action == .cancelRecorder || action == .recorderPanelEscape,
                    kind != .keyDown || !matchesInput(state.shortcut, kind: kind, inputCode: inputCode, modifierFlags: modifierFlags)
                else { continue }
            }

            var recoveredMissedRelease = false
            if kind == .keyDown, state.shortcut.kind == .key, inputCode == state.shortcut.keyCode {
                let matches = matchesShortcut(state.shortcut, action: action, kind: kind, inputCode: inputCode, modifierFlags: modifierFlags)
                if isAutoRepeat {
                    // Ignore repeats, but suppress held keys after modifier changes.
                    if matches || state.isDown {
                        shouldSuppress = true
                        ignoredRepeats += 1
                        let now = ProcessInfo.processInfo.systemUptime
                        if lastRepeatLogAt.map({ now - $0 >= 5 }) ?? true {
                            lastRepeatLogAt = now
                            ShortcutDiagnostics.notice("input owner=\(owner) action=\(action.storageName) result=ignored reason=autorepeat count=\(ignoredRepeats)")
                        }
                    }
                    continue
                }
                if matches, state.isDown {
                    // A fresh down recovers a missed release.
                    recoveredPresses += 1
                    ShortcutDiagnostics.warning("recovery owner=\(owner) action=\(action.storageName) reason=fresh-down-without-up heldSeconds=\(String(format: "%.3f", eventTime - (state.pressedAt ?? eventTime)))")
                    state = ShortcutState(shortcut: state.shortcut)
                    shortcuts[action] = state
                    recoveredMissedRelease = true
                }
            } else if kind == .mouseDown, state.shortcut.kind == .mouseButton,
                matchesShortcut(state.shortcut, action: action, kind: kind, inputCode: inputCode, modifierFlags: modifierFlags), state.isDown
            {
                // A new mouse-down is a fresh click.
                recoveredPresses += 1
                state = ShortcutState(shortcut: state.shortcut)
                shortcuts[action] = state
                recoveredMissedRelease = true
            } else if kind == .flagsChanged, state.shortcut.isModifierOnly, state.isDown,
                (inputCode == state.shortcut.keyCode
                    || (state.shortcut.keyCode == UInt16.max
                        && Shortcut.modifierKeyIsDown(inputCode, flags: state.modifierFlagsAtPress, requiringDeviceBit: true))),
                matchesShortcut(state.shortcut, action: action, kind: kind, inputCode: inputCode, modifierFlags: modifierFlags),
                Shortcut.modifierKeyIsDown(inputCode, flags: modifierFlags, requiringDeviceBit: true)
            {
                // Recover only keys held in the original chord; adding the opposite-side
                // modifier must not turn an interrupted chord into a fresh shortcut.
                recoveredPresses += 1
                ShortcutDiagnostics.warning("recovery owner=\(owner) action=\(action.storageName) reason=fresh-modifier-down-without-up")
                state = ShortcutState(shortcut: state.shortcut)
                shortcuts[action] = state
                recoveredMissedRelease = true
            }

            // Save modifier mismatches for diagnostics.
            if inputCode == state.shortcut.keyCode,
                (kind == .keyDown && state.shortcut.kind == .key)
                    || (kind == .flagsChanged && state.shortcut.isModifierOnly && !state.isDown)
            {
                let flags = Shortcut.normalizedModifierFlags(modifierFlags, forKeyCode: inputCode)
                if flags != state.shortcut.modifierFlags,
                    !matchesShortcut(state.shortcut, action: action, kind: kind, inputCode: inputCode, modifierFlags: modifierFlags)
                {
                    lastModifierMismatch = "\(action.storageName):actual=0x\(String(flags.rawValue, radix: 16)),expected=0x\(String(state.shortcut.modifierFlags.rawValue, radix: 16))"
                    lastModifierMismatchAt = ProcessInfo.processInfo.systemUptime
                    if ShortcutDiagnostics.shouldTraceKey(code: inputCode, flags: modifierFlags) {
                        ShortcutDiagnostics.notice("input owner=\(owner) action=\(action.storageName) result=ignored reason=modifier-mismatch \(lastModifierMismatch)")
                    }
                }
            }

            if state.shortcut.isModifierOnly {
                handleModifierOnlyShortcut(
                    action: action,
                    state: state,
                    kind: kind,
                    keyCode: inputCode,
                    modifierFlags: modifierFlags,
                    eventTime: eventTime,
                    recoveredMissedRelease: recoveredMissedRelease
                )
                continue
            }

            let transition: ShortcutTransition
            switch state.shortcut.kind {
            case .key:
                transition = transitionForKeyShortcut(
                    state.shortcut,
                    action: action,
                    isDown: state.isDown,
                    kind: kind,
                    keyCode: inputCode,
                    modifierFlags: modifierFlags
                )
            case .mouseButton:
                transition = transitionForMouseShortcut(
                    state.shortcut,
                    action: action,
                    isDown: state.isDown,
                    kind: kind,
                    buttonNumber: inputCode,
                    modifierFlags: modifierFlags
                )
            case .modifierOnly:
                transition = .none
            }

            switch transition {
            case .none:
                if !state.isDown, inputCode == state.shortcut.keyCode,
                    (kind == .keyUp && state.shortcut.kind == .key && ShortcutDiagnostics.shouldTraceKey(code: inputCode, flags: modifierFlags))
                        || (kind == .mouseUp && state.shortcut.kind == .mouseButton)
                {
                    ShortcutDiagnostics.notice("input owner=\(owner) action=\(action.storageName) result=ignored reason=release-without-down")
                }
                break
            case .suppress:
                if kind == .mouseDown {
                    ShortcutDiagnostics.notice("input owner=\(owner) action=\(action.storageName) result=ignored reason=already-held")
                }
                if kind != .flagsChanged {
                    shouldSuppress = true
                }
            case .keyDown:
                state.isDown = true
                state.pressedAt = eventTime
                state.isInterrupted = false
                shortcuts[action] = state
                if state.shortcut.kind == .mouseButton {
                    suppressedMouseButtons.insert(inputCode)
                }
                shouldSuppress = true
                dispatchShortcutDown(for: action, eventTime: eventTime, recoveredMissedRelease: recoveredMissedRelease)
            case .keyUp:
                state.isDown = false
                state.pressedAt = nil
                state.isInterrupted = false
                shortcuts[action] = state
                if kind != .flagsChanged {
                    shouldSuppress = true
                }
                dispatchShortcutUp(for: action, eventTime: eventTime)
            }
        }

        return shouldSuppress
    }

    func handleSystemHotKey(action: ShortcutAction, shortcut: Shortcut, isDown: Bool, eventTime: TimeInterval) {
        guard observeInputPolicy() else {
            ShortcutDiagnostics.notice("input owner=\(owner) action=\(action.storageName) result=ignored reason=session-input-policy route=system-hot-key")
            return
        }
        guard systemHotKeyActions.contains(action), var state = shortcuts[action], state.shortcut == shortcut else { return }

        var recoveredMissedRelease = false
        if isDown, state.isDown {
            // A fresh press recovers a missed release.
            recoveredPresses += 1
            ShortcutDiagnostics.warning("recovery owner=\(owner) action=\(action.storageName) reason=fresh-down-without-up route=system-hot-key")
            state = ShortcutState(shortcut: state.shortcut)
            recoveredMissedRelease = true
        }
        guard state.isDown != isDown else { return }

        let eventKind: EventKind = isDown ? .keyDown : .keyUp
        updatePressedKeyCodes(kind: eventKind, inputCode: shortcut.keyCode)
        invalidateStandaloneModifierCandidateForKeyboardEvent(kind: eventKind, inputCode: shortcut.keyCode, modifierFlags: [])
        if isDown {
            // Carbon matched these exact modifiers.
            handleShortcutInterruptions(keyCode: shortcut.keyCode, modifierFlags: shortcut.modifierFlags, eventTime: eventTime)
        }
        state.isDown = isDown
        state.pressedAt = isDown ? eventTime : nil
        state.isInterrupted = false
        shortcuts[action] = state

        if isDown {
            dispatchShortcutDown(for: action, eventTime: eventTime, recoveredMissedRelease: recoveredMissedRelease)
        } else {
            dispatchShortcutUp(for: action, eventTime: eventTime)
        }
    }

    func isMonitoring(_ action: ShortcutAction) -> Bool {
        shortcuts[action] != nil && eventTap?.isEnabled == true
    }

    func earlyCaptureAvailability(for actions: Set<ShortcutAction>) -> Bool? {
        guard !actions.isDisjoint(with: shortcuts.keys) else { return nil }
        return eventTap?.isValid == true && eventTap?.isEnabled == true
    }

    private func notifyCaptureAvailabilityChanged() {
        NotificationCenter.default.post(name: ShortcutMonitor.captureAvailabilityDidChange, object: nil)
    }

    private enum ShortcutTransition {
        case none
        case suppress
        case keyDown
        case keyUp
    }

    private func transitionForKeyShortcut(
        _ shortcut: Shortcut,
        action: ShortcutAction,
        isDown: Bool,
        kind: EventKind,
        keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags
    ) -> ShortcutTransition {
        switch kind {
        case .keyDown:
            guard matchesShortcut(shortcut, action: action, kind: kind, inputCode: keyCode, modifierFlags: modifierFlags) else {
                return .none
            }

            return isDown ? .suppress : .keyDown
        case .keyUp:
            return isDown && keyCode == shortcut.keyCode ? .keyUp : .none
        case .flagsChanged:
            guard isDown else {
                return .none
            }

            let currentFlags = Shortcut.normalizedModifierFlags(
                modifierFlags,
                forKeyCode: shortcut.keyCode
            )
            return currentFlags.isSuperset(of: shortcut.modifierFlags) ? .suppress : .keyUp
        case .mouseDown, .mouseDragged, .mouseUp:
            return .none
        }
    }

    private func matchesShortcut(
        _ shortcut: Shortcut,
        action: ShortcutAction,
        kind: EventKind,
        inputCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags
    ) -> Bool {
        guard action == .cancelRecorder || action == .recorderPanelEscape else {
            return matchesInput(shortcut, kind: kind, inputCode: inputCode, modifierFlags: modifierFlags)
        }

        // Ordinary typing should not query physical recording state or scan reservations.
        switch kind {
        case .keyDown:
            guard shortcut.kind == .key, shortcut.keyCode == inputCode else { return false }
        case .mouseDown:
            guard shortcut.kind == .mouseButton, shortcut.keyCode == inputCode else { return false }
        case .flagsChanged:
            guard shortcut.isModifierOnly else { return false }
        case .keyUp, .mouseUp, .mouseDragged:
            return false
        }
        let flags = Shortcut.normalizedModifierFlags(modifierFlags, forKeyCode: shortcut.kind == .key ? inputCode : nil)
        guard flags.isSuperset(of: shortcut.modifierFlags) else { return false }
        // Preserve the existing Force Quit exception.
        if kind == .keyDown, inputCode == UInt16(kVK_Escape),
            modifierFlags.contains([.command, .option]),
            !shortcut.modifierFlags.contains([.command, .option])
        {
            return false
        }
        guard !reservedShortcuts.contains(where: {
            matchesInput($0, kind: kind, inputCode: inputCode, modifierFlags: modifierFlags)
        }) else { return false }

        if matchesInput(shortcut, kind: kind, inputCode: inputCode, modifierFlags: modifierFlags) {
            return true
        }
        guard let recordingShortcut = heldRecordingShortcut(), isShortcutPressed(recordingShortcut) else { return false }

        // Keep the cancel modifiers; ignore only extras from the active physical recording press.
        let recordingModifiers = recordingShortcut.modifierFlags.subtracting(shortcut.modifierFlags)
        return matchesInput(shortcut, kind: kind, inputCode: inputCode,
                            modifierFlags: modifierFlags.subtracting(recordingModifiers))
    }

    private func matchesInput(
        _ shortcut: Shortcut,
        kind: EventKind,
        inputCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags
    ) -> Bool {
        switch kind {
        case .keyDown:
            return shortcut.matchesKeyEvent(keyCode: inputCode, modifierFlags: modifierFlags)
        case .mouseDown:
            return shortcut.matchesMouseEvent(buttonNumber: inputCode, modifierFlags: modifierFlags)
        case .flagsChanged:
            return shortcut.matchesModifierEvent(keyCode: inputCode, modifierFlags: modifierFlags)
        case .keyUp, .mouseUp, .mouseDragged:
            return false
        }
    }

    private func transitionForMouseShortcut(
        _ shortcut: Shortcut,
        action: ShortcutAction,
        isDown: Bool,
        kind: EventKind,
        buttonNumber: UInt16,
        modifierFlags: NSEvent.ModifierFlags
    ) -> ShortcutTransition {
        switch kind {
        case .mouseDown:
            guard matchesShortcut(shortcut, action: action, kind: kind, inputCode: buttonNumber, modifierFlags: modifierFlags) else {
                return .none
            }

            return isDown ? .suppress : .keyDown
        case .mouseUp:
            return isDown && buttonNumber == shortcut.keyCode ? .keyUp : .none
        case .flagsChanged:
            guard isDown else {
                return .none
            }

            let currentFlags = Shortcut.normalizedModifierFlags(modifierFlags, forKeyCode: nil)
            return currentFlags.isSuperset(of: shortcut.modifierFlags) ? .suppress : .keyUp
        case .keyDown, .keyUp, .mouseDragged:
            return .none
        }
    }

    private func handleModifierOnlyShortcut(
        action: ShortcutAction,
        state: ShortcutState,
        kind: EventKind,
        keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags,
        eventTime: TimeInterval,
        recoveredMissedRelease: Bool
    ) {
        var state = state

        guard kind == .flagsChanged else {
            return
        }

        if state.isDown {
            if state.shortcut.shouldReleaseModifierEvent(keyCode: keyCode, modifierFlags: modifierFlags) {
                let shouldTrigger =
                    state.requiresStandaloneRelease
                    && !state.isInterrupted
                let shouldDispatchUp = !state.requiresStandaloneRelease && !state.isDropped
                let wasDropped = state.isDropped
                let pressedAt = state.pressedAt
                let recoveredPress = state.recoveredMissedRelease
                state.isDown = false
                state.pressedAt = nil
                state.isInterrupted = false
                state.requiresStandaloneRelease = false
                state.recoveredMissedRelease = false
                state.isDropped = false
                shortcuts[action] = state
                if shouldTrigger, let pressedAt {
                    dispatchShortcutDown(for: action, eventTime: pressedAt, recoveredMissedRelease: recoveredPress)
                    dispatchShortcutUp(for: action, eventTime: eventTime)
                } else if shouldDispatchUp {
                    dispatchShortcutUp(for: action, eventTime: eventTime)
                } else if wasDropped {
                    ShortcutDiagnostics.notice("input owner=\(owner) action=\(action.storageName) result=ignored reason=physical-chord-before-press")
                } else {
                    ignoredModifierChords += 1
                    ShortcutDiagnostics.notice("input owner=\(owner) action=\(action.storageName) result=ignored reason=standalone-modifier-chord")
                }
            }

            return
        }

        if matchesShortcut(state.shortcut, action: action, kind: kind, inputCode: keyCode, modifierFlags: modifierFlags) {
            state.isDown = true
            state.pressedAt = eventTime
            state.recoveredMissedRelease = recoveredMissedRelease
            state.modifierFlagsAtPress = modifierFlags
            state.requiresStandaloneRelease = standaloneModifierActions.contains(action)
            if isOvertakenByPhysicalKey(action: action, pressedAt: eventTime) {
                physicalChords += 1
                state.isInterrupted = true
                state.isDropped = !state.requiresStandaloneRelease
                shortcuts[action] = state
                ShortcutDiagnostics.notice("input owner=\(owner) action=\(action.storageName) result=dropped reason=physical-key-overtook-press")
                return
            }
            if state.requiresStandaloneRelease {
                onPressCaptured?(action, eventTime)
                // Drop keys that are no longer held.
                pressedKeyCodes = pressedKeyCodes.filter(isKeyDown)
            }
            state.isInterrupted = state.requiresStandaloneRelease && !pressedKeyCodes.isEmpty
            shortcuts[action] = state
            if !state.requiresStandaloneRelease {
                dispatchShortcutDown(for: action, eventTime: eventTime, recoveredMissedRelease: recoveredMissedRelease)
            }
            if !state.isInterrupted {
                scheduleChordBreaker(for: action, pressedAt: eventTime)
            }
        }
    }

    private func isChordEvidenceAction(_ action: ShortcutAction) -> Bool {
        shortcuts[action]?.shortcut.isModifierOnly == true
            && (interruptibleActions.contains(action) || standaloneModifierActions.contains(action))
    }

    private func isOvertakenByPhysicalKey(action: ShortcutAction, pressedAt: TimeInterval) -> Bool {
        guard isChordEvidenceAction(action), let shortcut = shortcuts[action]?.shortcut else { return false }
        return physicalKeyDowns.contains { keyDown in
            keyDown.time > pressedAt && keyDown.time - pressedAt < Self.physicalChordOvertakeWindow
                && Self.isHeld(shortcut, by: keyDown.modifierFlags)
        }
    }

    private func updatePhysicalKeyTap() {
        guard let makePhysicalKeyTap, shortcuts.keys.contains(where: isChordEvidenceAction) else {
            physicalKeyTap?.stop()
            physicalKeyTap = nil
            physicalKeyDowns = []
            return
        }
        if let physicalKeyTap, physicalKeyTap.isValid {
            if !physicalKeyTap.isEnabled { physicalKeyTap.enable() }
            return
        }
        physicalKeyTap?.stop()
        physicalKeyTap = nil
        // Without Accessibility the session tap fails, and a listen-only keyboard tap could prompt for Input Monitoring.
        guard eventTap?.isEnabled == true else {
            physicalKeyTapIssue = "awaiting-session-tap"
            return
        }
        physicalKeyTapRevision &+= 1
        let revision = physicalKeyTapRevision
        do {
            physicalKeyTap = try makePhysicalKeyTap { [weak self] type, event in
                guard let self, self.physicalKeyTapRevision == revision else { return false }
                self.handlePhysicalEvent(type: type, event: event)
                return false
            }
            physicalKeyTapIssue = "none"
            lastPhysicalKeyTapFailureLogAt = nil
            ShortcutDiagnostics.notice("physical-tap owner=\(owner) result=installed")
        } catch {
            physicalKeyTapIssue = "unavailable"
            let now = ProcessInfo.processInfo.systemUptime
            if lastPhysicalKeyTapFailureLogAt.map({ now - $0 >= 60 }) ?? true {
                lastPhysicalKeyTapFailureLogAt = now
                ShortcutDiagnostics.warning("physical-tap owner=\(owner) result=unavailable effect=global-hot-key-chords-unseen")
            }
        }
    }

    private func handlePhysicalEvent(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            // Missing evidence only lets a chord count as a hold, so just resume.
            physicalKeyTapIssue = type == .tapDisabledByTimeout ? "timeout" : "user-input"
            physicalKeyTap?.enable()
            return
        }
        guard type == .keyDown, !ChordBreaker.isMarked(event), !Self.isPostedByThisProcess(event),
            event.getIntegerValueField(.keyboardEventAutorepeat) == 0
        else { return }
        let keyCode = UInt16(clamping: event.getIntegerValueField(.keyboardEventKeycode))
        let modifierFlags = NSEvent.ModifierFlags(rawValue: UInt(event.flags.rawValue))
        // Escape and VoiceInk's own shortcuts already act through their session events or hot keys.
        guard keyCode != UInt16(kVK_Escape), !Shortcut.isModifierKeyCode(keyCode),
            !shortcuts.values.contains(where: {
                matchesInput($0.shortcut, kind: .keyDown, inputCode: keyCode, modifierFlags: modifierFlags)
            }),
            observeInputPolicy()
        else { return }

        let eventTime = PhysicalKeyEventTime.seconds(rawTimestamp: event.timestamp, now: ProcessInfo.processInfo.systemUptime)
        if physicalKeyDowns.count == Self.physicalKeyDownHistory { physicalKeyDowns.removeFirst() }
        physicalKeyDowns.append((eventTime, modifierFlags))
        for action in Array(shortcuts.keys) where isChordEvidenceAction(action) {
            // A key typed just after the release can overtake the session's release event.
            guard var state = shortcuts[action], state.isDown, state.requiresStandaloneRelease, !state.isInterrupted,
                let pressedAt = state.pressedAt, eventTime >= pressedAt, Self.isHeld(state.shortcut, by: modifierFlags)
            else { continue }
            physicalChords += 1
            state.isInterrupted = true
            shortcuts[action] = state
        }
        handleShortcutInterruptions(keyCode: keyCode, modifierFlags: modifierFlags, eventTime: eventTime, isPhysicalEvidence: true)
    }

    private static func isHeld(_ shortcut: Shortcut, by modifierFlags: NSEvent.ModifierFlags) -> Bool {
        shortcut.isModifierOnly && !shortcut.shouldReleaseModifierEvent(keyCode: shortcut.keyCode, modifierFlags: modifierFlags)
    }

    private func scheduleChordBreaker(for action: ShortcutAction, pressedAt: TimeInterval) {
        chordBreakerTimers.removeValue(forKey: action)?.invalidate()
        // Fn is the system's own tap; keyed shortcuts are consumed and need no breaker.
        guard let delay = chordBreakerDelays[action], let shortcut = shortcuts[action]?.shortcut,
            shortcut.isModifierOnly, !shortcut.modifierFlags.contains(.function)
        else { return }
        let elapsed = max(0, ProcessInfo.processInfo.systemUptime - pressedAt)
        let timer = Timer(timeInterval: max(0, delay - elapsed), repeats: false) { [weak self] _ in
            self?.postChordBreakerIfHeld(for: action, pressedAt: pressedAt)
        }
        chordBreakerTimers[action] = timer
        RunLoop.current.add(timer, forMode: .common)
    }

    private func postChordBreakerIfHeld(for action: ShortcutAction, pressedAt: TimeInterval) {
        chordBreakerTimers[action] = nil
        guard let state = shortcuts[action], state.isDown, state.pressedAt == pressedAt,
            !state.isInterrupted, !state.isDropped, observeInputPolicy()
        else { return }
        let flags = physicalModifierFlags()
        // Any other modifier already breaks the other apps' tap.
        guard state.shortcut.matchesModifierEvent(
            keyCode: state.shortcut.keyCode,
            modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(flags.rawValue))
        ) else { return }
        if postChordBreaker(flags) {
            chordBreakersPosted += 1
            ShortcutDiagnostics.notice("chord-breaker owner=\(owner) action=\(action.storageName) result=posted")
        } else {
            ShortcutDiagnostics.notice("chord-breaker owner=\(owner) action=\(action.storageName) result=skipped")
        }
    }

    private func updatePressedKeyCodes(kind: EventKind, inputCode: UInt16) {
        switch kind {
        case .keyDown:
            pressedKeyCodes.insert(inputCode)
        case .keyUp:
            pressedKeyCodes.remove(inputCode)
        case .flagsChanged, .mouseDown, .mouseDragged, .mouseUp:
            break
        }
    }

    private func invalidateStandaloneModifierCandidateForKeyboardEvent(
        kind: EventKind,
        inputCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags
    ) {
        guard kind == .keyDown || kind == .keyUp || kind == .flagsChanged else {
            return
        }

        for action in Array(shortcuts.keys) {
            guard var state = shortcuts[action],
                state.isDown,
                state.requiresStandaloneRelease,
                !state.isInterrupted
            else {
                continue
            }

            let isReleaseEvent = kind == .flagsChanged
                && state.shortcut.shouldReleaseModifierEvent(
                    keyCode: inputCode,
                    modifierFlags: modifierFlags
                )
            if !isReleaseEvent {
                state.isInterrupted = true
                shortcuts[action] = state
            }
        }
    }

    private func handleShortcutInterruptions(
        keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags,
        eventTime: TimeInterval,
        isPhysicalEvidence: Bool = false
    ) {
        guard !Shortcut.isModifierKeyCode(keyCode) else {
            return
        }

        for action in standaloneModifierActions {
            guard shortcuts[action]?.shortcut.isModifierOnly == true else { continue }
            guard let callback = onStandaloneModifierChord else { continue }
            let validity = dispatchValidity
            let queuedGeneration = generation
            let queuedRevision = actionRevisions[action]
            DispatchQueue.main.async {
                // Keep cancellation ordered with shortcut actions.
                Task { @MainActor in
                    guard validity.withLock({ $0.generation == queuedGeneration && $0.revisions[action] == queuedRevision }) else { return }
                    callback(action)
                }
            }
        }

        for action in interruptibleActions {
            guard var state = shortcuts[action],
                state.isDown,
                !state.isInterrupted,
                let pressedAt = state.pressedAt,
                state.shortcut.isInterruptedByAdditionalKeyDown(keyCode: keyCode),
                // A held modifier-only shortcut plus any key is a chord at any time (Hex `dictate.held-chord`).
                // HID evidence counts only then: it can overtake the session's press or release event.
                isPhysicalEvidence
                    ? Self.isHeld(state.shortcut, by: modifierFlags) && eventTime >= pressedAt
                    : eventTime - pressedAt <= Self.shortcutInterruptionWindow || Self.isHeld(state.shortcut, by: modifierFlags)
            else {
                continue
            }

            if isPhysicalEvidence { physicalChords += 1 }
            state.isInterrupted = true
            shortcuts[action] = state
            dispatchShortcutInterrupted(for: action, eventTime: pressedAt)
        }
    }

    private func dispatchShortcutDown(for action: ShortcutAction, eventTime: TimeInterval, recoveredMissedRelease: Bool = false) {
        onPressCaptured?(action, eventTime)
        dispatch(onShortcutDown, action: action, eventTime: eventTime, transition: "down", recoveredMissedRelease: recoveredMissedRelease)
    }

    private func dispatchShortcutUp(for action: ShortcutAction, eventTime: TimeInterval) {
        dispatch(onShortcutUp, action: action, eventTime: eventTime, transition: "up")
    }

    private func dispatchShortcutInterrupted(for action: ShortcutAction, eventTime: TimeInterval) {
        dispatch(onShortcutInterrupted, action: action, eventTime: eventTime, transition: "interrupted")
    }

    private func dispatch(
        _ callback: ShortcutCallback?,
        action: ShortcutAction,
        eventTime: TimeInterval,
        transition: String,
        recoveredMissedRelease: Bool = false
    ) {
        let queuedGeneration = generation
        let queuedRevision = actionRevisions[action]
        // Tap rebuilds advance the generation; system hot keys do not depend on the tap.
        let followsTapGeneration = !systemHotKeyActions.contains(action)
        let queuedAt = ProcessInfo.processInfo.systemUptime
        let validity = dispatchValidity
        let owner = owner
        let allowsDispatch = allowsDispatch
        let onMissedRelease = onMissedRelease
        lastMatchAt = queuedAt
        ShortcutDiagnostics.notice("match owner=\(owner) generation=\(generation) action=\(action.storageName) transition=\(transition) eventTime=\(String(format: "%.6f", eventTime)) recoveredMissedRelease=\(recoveredMissedRelease)")
        DispatchQueue.main.async {
            Task { @MainActor in
                guard validity.withLock({
                    (!followsTapGeneration || $0.generation == queuedGeneration) && $0.revisions[action] == queuedRevision
                }) else {
                    ShortcutDiagnostics.notice("dispatch owner=\(owner) action=\(action.storageName) transition=\(transition) result=dropped reason=monitor-restarted queuedGeneration=\(queuedGeneration)")
                    return
                }
                guard allowsDispatch() else {
                    ShortcutDiagnostics.notice("dispatch owner=\(owner) action=\(action.storageName) transition=\(transition) result=dropped reason=live-session-input-policy")
                    return
                }
                let delay = ProcessInfo.processInfo.systemUptime - queuedAt
                if delay >= 0.5 {
                    ShortcutDiagnostics.warning("dispatch owner=\(owner) action=\(action.storageName) result=delayed seconds=\(String(format: "%.3f", delay))")
                }
                // Reset the gesture before delivering the recovered press.
                if recoveredMissedRelease { onMissedRelease?(action) }
                await callback?(action, eventTime)
            }
        }
    }

    private var shortcutSummary: String {
        shortcuts.map { "\($0.key.storageName):\($0.value.shortcut.diagnosticDescription)" }.sorted().joined(separator: ";")
    }

    private var reservedShortcutSummary: String {
        guard !reservedShortcuts.isEmpty else { return "" }
        return " reserved={\(reservedShortcuts.map(\.diagnosticDescription).sorted().joined(separator: ";"))}"
    }

    private var pressedActionSummary: String {
        let actions = shortcuts.filter { $0.value.isDown }.keys.map(\.storageName).sorted()
        return actions.isEmpty ? "none" : actions.joined(separator: ",")
    }

    var diagnosticSummary: String {
        let now = ProcessInfo.processInfo.systemUptime
        func age(_ time: TimeInterval?) -> String {
            time.map { String(format: "%.1f", max(0, now - $0)) } ?? "never"
        }
        let pressedSnapshots = shortcuts.filter { $0.value.isDown }.map { action, state in
            let sessionDown = state.shortcut.kind == .key ? isKeyDown(state.shortcut.keyCode) : state.shortcut.isCurrentlyPressed
            return "\(action.storageName):sessionDown=\(sessionDown)"
        }.sorted().joined(separator: ";")
        return "generation=\(generation) valid=\(eventTap?.isValid == true) enabled=\(eventTap?.isEnabled == true) recoveryTimerActive=\(recoveryTimer != nil) systemHotKeys=\(systemHotKeyActions.map(\.storageName).sorted().joined(separator: ",")) lastIssue=\(lastTapIssue) installFailures=\(installFailures) recoveredPresses=\(recoveredPresses) ignoredRepeats=\(ignoredRepeats) ignoredModifierChords=\(ignoredModifierChords) physicalTap=\(physicalKeyTap.map { $0.isEnabled ? "enabled" : "disabled" } ?? "none") physicalTapIssue=\(physicalKeyTapIssue) physicalChords=\(physicalChords) chordBreakers=\(chordBreakersPosted) events={down:\(keyDownCount),up:\(keyUpCount),modifiers:\(modifierEventCount),mouse:\(mouseEventCount)} lastEventAge=\(age(lastEventAt)) lastMatchAge=\(age(lastMatchAt)) lastModifierMismatch={\(lastModifierMismatch)} mismatchAge=\(age(lastModifierMismatchAt)) pressed=\(pressedActionSummary) pressedSnapshots={\(pressedSnapshots)} shortcuts={\(shortcutSummary)}"
    }

    private static let eventMask: CGEventMask = [
        CGEventType.keyDown,
        CGEventType.keyUp,
        CGEventType.flagsChanged,
        CGEventType.otherMouseDown,
        CGEventType.otherMouseDragged,
        CGEventType.otherMouseUp,
    ].reduce(CGEventMask(0)) { mask, type in
        mask | (CGEventMask(1) << Int(type.rawValue))
    }
}

private extension ShortcutMonitorWorker.EventKind {
    init?(_ type: CGEventType) {
        switch type {
        case .keyDown:
            self = .keyDown
        case .keyUp:
            self = .keyUp
        case .flagsChanged:
            self = .flagsChanged
        case .otherMouseDown:
            self = .mouseDown
        case .otherMouseDragged:
            self = .mouseDragged
        case .otherMouseUp:
            self = .mouseUp
        default:
            return nil
        }
    }
}

/// HID-tap timestamps arrive as Mach ticks on Apple Silicon and as nanoseconds on some events
/// (Hex `physical_event_instant`); keep whichever reading is recent, else the arrival time.
enum PhysicalKeyEventTime {
    private static let recentWindow: TimeInterval = 5

    static func seconds(
        rawTimestamp: UInt64,
        now: TimeInterval,
        nanosecondsPerMachTick: Double = PhysicalKeyEventTime.nanosecondsPerMachTick
    ) -> TimeInterval {
        let readings = [Double(rawTimestamp) * nanosecondsPerMachTick / 1_000_000_000, Double(rawTimestamp) / 1_000_000_000]
        return readings.first { now - $0 >= 0 && now - $0 <= recentWindow } ?? now
    }

    static let nanosecondsPerMachTick: Double = {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        return timebase.denom == 0 ? 1 : Double(timebase.numer) / Double(timebase.denom)
    }()
}
