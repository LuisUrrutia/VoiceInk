import AppKit
import Combine
import Foundation
import os

@MainActor
class RecordingShortcutManager: ObservableObject {
    @Published private(set) var hotkeyAvailability: RecordingHotkeyAvailability = .unconfigured
    private var activationSubscription: AnyCancellable?
    private var accessibilityGranted = AXIsProcessTrusted()
    @Published var primaryRecordingShortcut: ShortcutSelection {
        didSet {
            UserDefaults.standard.set(primaryRecordingShortcut.rawValue, forKey: "primaryRecordingShortcut")
            refreshShortcutMonitoring(reason: "primary-selection")
        }
    }
    @Published var secondaryRecordingShortcut: ShortcutSelection {
        didSet {
            if secondaryRecordingShortcut == .none {
                ShortcutStore.setShortcut(nil, for: .secondaryRecording)
            }
            UserDefaults.standard.set(secondaryRecordingShortcut.rawValue, forKey: "secondaryRecordingShortcut")
            refreshShortcutMonitoring(reason: "secondary-selection")
        }
    }
    @Published var primaryRecordingShortcutMode: Mode {
        didSet {
            UserDefaults.standard.set(primaryRecordingShortcutMode.rawValue, forKey: "primaryRecordingShortcutMode")
            ShortcutDiagnostics.notice("configuration action=primaryRecording mode=\(primaryRecordingShortcutMode.rawValue)")
            primaryRecordingShortcutModeSource.primaryMode = primaryRecordingShortcutMode
            // Dictate Without Processing records with the primary shortcut's mode.
            shortcutModeHandler.resetShortcutStates(for: [.primaryRecording, .rawRecording])
            shortcutMonitor.resetShortcutStates(for: [.primaryRecording, .rawRecording])
            modeShortcutManager.recordingModeDidChange()
            updateStandaloneModifierActions()
        }
    }
    @Published var secondaryRecordingShortcutMode: Mode {
        didSet {
            UserDefaults.standard.set(secondaryRecordingShortcutMode.rawValue, forKey: "secondaryRecordingShortcutMode")
            ShortcutDiagnostics.notice("configuration action=secondaryRecording mode=\(secondaryRecordingShortcutMode.rawValue)")
            shortcutModeHandler.resetShortcutState(for: .secondaryRecording)
            shortcutMonitor.resetShortcutStates(for: [.secondaryRecording])
            updateStandaloneModifierActions()
        }
    }
    /// Unbound by default; set only through `ShortcutStore`.
    @Published private(set) var rawRecordingShortcut: Shortcut?
    private var engine: VoiceInkEngine
    private var recorderUIManager: RecorderUIManager
    private var recorderPanelShortcutManager: RecorderPanelShortcutManager
    private let modeShortcutManager: ModeShortcutManager
    private let shortcutMonitor = ShortcutMonitor(owner: "recording", makePhysicalKeyTap: ShortcutMonitor.systemPhysicalKeyTap)
    private let monitoringLifecycle = ShortcutMonitoringLifecycle()
    private var lifecycleObservers: [NSObjectProtocol] = []
    private var shortcutChangeObserver: NSObjectProtocol?
    private let shortcutModeHandler: RecordingShortcutModeHandler
    private let primaryRecordingShortcutModeSource: RecordingShortcutModeSource

    enum Mode: String, CaseIterable {
        case toggle = "toggle"
        case pushToTalk = "pushToTalk"
        case hybrid = "hybrid"
        case doubleTap = "doubleTap"

        var displayName: String {
            switch self {
            case .toggle: return String(localized: "Toggle")
            case .pushToTalk: return String(localized: "Push to Talk")
            case .hybrid: return String(localized: "Hybrid")
            case .doubleTap: return String(localized: "Double Tap")
            }
        }

        /// How long a modifier-only press is held before its chord breaker; nil keeps every press a tap.
        var chordBreakerDelay: TimeInterval? {
            switch self {
            // A shorter release is a discarded short tap, which stays a tap for other apps.
            case .pushToTalk: return RecordingShortcutModeHandler.shortTapThreshold
            // A tap starts or finishes these, so they use Hex's 40 ms chord grace instead of the hold.
            case .toggle, .hybrid: return 0.04
            case .doubleTap: return nil
            }
        }
    }

    enum ShortcutSelection: String, CaseIterable {
        case none = "none"
        case custom = "custom"

        var displayName: String {
            switch self {
            case .none: return String(localized: "None")
            case .custom: return String(localized: "Custom")
            }
        }
    }

    private static func canHandleShortcutAction(for recordingState: RecordingState) -> Bool {
        recordingState != .transcribing && recordingState != .enhancing && recordingState != .busy
    }

    init(engine: VoiceInkEngine, recorderUIManager: RecorderUIManager) {
        ShortcutMigration.migrateLegacyShortcutsIfNeeded()

        self.primaryRecordingShortcut = ShortcutMigration.migrateShortcutSelection(
            action: .primaryRecording,
            allowsNone: false
        )
        self.secondaryRecordingShortcut = ShortcutMigration.migrateShortcutSelection(
            action: .secondaryRecording,
            allowsNone: true
        )

        let primaryRecordingShortcutMode = ShortcutMigration.migrateShortcutMode(
            for: .primaryRecording
        )
        self.primaryRecordingShortcutMode = primaryRecordingShortcutMode
        self.secondaryRecordingShortcutMode = ShortcutMigration.migrateShortcutMode(
            for: .secondaryRecording
        )

        let shortcutModeHandler = RecordingShortcutModeHandler(
            canHandleShortcutAction: {
                Self.canHandleShortcutAction(for: engine.recordingState)
            },
            isRecorderVisible: {
                recorderUIManager.isRecorderPanelVisible
            },
            recordingState: {
                engine.recordingState
            },
            isShortcutHeld: { action in
                ShortcutStore.shortcut(for: action)?.isCurrentlyPressed == true
            },
            finishHeldRecording: {
                recorderUIManager.finishHeldShortcutRecording()
            },
            toggleRecorderPanel: { modeId, eventTime, processing in
                // Every handler stop is a release or finishing press that transcribes.
                await recorderUIManager.toggleRecorderPanel(
                    modeId: modeId, processing: processing, keepsReleaseTail: true,
                    preRollPressNanoseconds: UInt64(eventTime * 1_000_000_000)
                )
            },
            captureProcessing: {
                recorderUIManager.captureProcessing
            },
            cancelRecording: {
                await recorderUIManager.cancelRecording()
            },
            retractStartSound: {
                SoundManager.shared.retractStartSound()
            }
        )

        let primaryRecordingShortcutModeSource = RecordingShortcutModeSource(
            primaryMode: primaryRecordingShortcutMode
        )

        self.rawRecordingShortcut = ShortcutStore.shortcut(for: .rawRecording)
        self.engine = engine
        self.recorderUIManager = recorderUIManager
        self.recorderPanelShortcutManager = RecorderPanelShortcutManager(
            recorderUIManager: recorderUIManager,
            heldRecordingShortcut: { shortcutModeHandler.heldRecordingShortcut }
        )
        self.shortcutModeHandler = shortcutModeHandler
        engine.outputQueue.isRecordingShortcutHeld = {
            shortcutModeHandler.heldRecordingShortcut?.isCurrentlyPressed == true
        }
        self.primaryRecordingShortcutModeSource = primaryRecordingShortcutModeSource
        self.modeShortcutManager = ModeShortcutManager(
            modeProvider: {
                primaryRecordingShortcutModeSource.primaryMode
            },
            shortcutModeHandler: shortcutModeHandler,
            preRollPress: engine.recorder.preRollPress
        )
        engine.recorder.setPreRollObserverProvider { [weak self] in
            guard let self else { return false }
            let availability = [
                self.shortcutMonitor.earlyCaptureAvailability(
                    for: [.primaryRecording, .secondaryRecording, .rawRecording]
                ),
                self.modeShortcutManager.earlyCaptureAvailability,
            ].compactMap { $0 }
            return !availability.isEmpty && availability.allSatisfy { $0 }
        }

        shortcutChangeObserver = NotificationCenter.default.addObserver(
            forName: ShortcutStore.shortcutDidChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let action = (notification.object as? ShortcutAction)?.storageName ?? "unknown"
            Task { @MainActor in
                self?.refreshShortcutMonitoring(reason: "store-change.\(action)")
            }
        }

        setupLifecycleDiagnostics()
        ShortcutDiagnostics.logSessionStart()
        ShortcutDiagnostics.setRecordingContext { [weak self] in
            guard let self else { return "unavailable" }
            return "state=\(self.engine.recordingState) visible=\(self.recorderUIManager.isRecorderPanelVisible) primarySelection=\(self.primaryRecordingShortcut.rawValue) primaryMode=\(self.primaryRecordingShortcutMode.rawValue) secondarySelection=\(self.secondaryRecordingShortcut.rawValue) secondaryMode=\(self.secondaryRecordingShortcutMode.rawValue) rawBound=\(self.rawRecordingShortcut != nil) \(self.shortcutModeHandler.diagnosticSummary)"
        }
        ShortcutDiagnostics.notice("configuration primarySelection=\(self.primaryRecordingShortcut.rawValue) primaryMode=\(self.primaryRecordingShortcutMode.rawValue) secondarySelection=\(self.secondaryRecordingShortcut.rawValue) secondaryMode=\(self.secondaryRecordingShortcutMode.rawValue)")
        ShortcutDiagnostics.observeEnvironment(reason: "startup", force: true)

        refreshShortcutMonitoring(reason: "startup")
        activationSubscription = LifecycleObserver.shared.publisher(for: .applicationDidBecomeActive).sink { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let granted = AXIsProcessTrusted()
                if self.accessibilityGranted != granted {
                    self.accessibilityGranted = granted
                    self.refreshShortcutMonitoring(reason: "accessibility-change")
                }
            }
        }
    }

    private func refreshShortcutMonitoring(reason: String) {
        monitoringLifecycle.refreshWhenReady { [weak self] in
            self?.refreshShortcutMonitor(reason: reason)
        }
    }

    private func refreshShortcutMonitor(reason: String) {
        let primaryShortcut = primaryRecordingShortcut == .custom ? ShortcutStore.shortcut(for: .primaryRecording) : nil
        let secondaryShortcut =
            secondaryRecordingShortcut == .custom ? ShortcutStore.shortcut(for: .secondaryRecording) : nil
        var shortcuts = ShortcutStore.shortcuts(for: ShortcutAction.globalUtilityActions)
        var interruptibleRecordingActions = Set<ShortcutAction>()

        if let primaryShortcut {
            shortcuts[.primaryRecording] = primaryShortcut
            interruptibleRecordingActions.insert(.primaryRecording)
        }

        if let secondaryShortcut {
            shortcuts[.secondaryRecording] = secondaryShortcut
            interruptibleRecordingActions.insert(.secondaryRecording)
        }

        rawRecordingShortcut = ShortcutStore.shortcut(for: .rawRecording)
        if let rawRecordingShortcut {
            shortcuts[.rawRecording] = rawRecordingShortcut
            interruptibleRecordingActions.insert(.rawRecording)
        }

        shortcutMonitor.start(
            shortcuts: shortcuts,
            interruptibleActions: interruptibleRecordingActions,
            standaloneModifierActions: standaloneModifierActions,
            chordBreakerDelays: chordBreakerDelays,
            onShortcutDown: { [weak self] action, eventTime in
                guard let self else { return }
                guard let mode = self.recordingMode(for: action) else { return }
                await self.shortcutModeHandler.handleShortcutDown(
                    action: action,
                    eventTime: eventTime,
                    mode: mode
                )
            },
            onShortcutUp: { [weak self] action, eventTime in
                guard let self else { return }
                if let mode = self.recordingMode(for: action) {
                    await self.shortcutModeHandler.handleShortcutUp(
                        action: action,
                        eventTime: eventTime,
                        mode: mode
                    )
                } else {
                    await self.handleGlobalShortcut(action)
                }
            },
            onShortcutInterrupted: { [weak self] action, pressedAt in
                guard let self, self.recordingMode(for: action) != nil else { return }
                await self.shortcutModeHandler.handleInterruption(action: action, pressedAt: pressedAt)
            },
            onStandaloneModifierChord: { [weak self] action in
                self?.shortcutModeHandler.clearPendingDoubleTap(for: action)
            },
            onMonitoringReset: { [weak self] actions in
                self?.shortcutModeHandler.resetShortcutStates(for: actions)
            },
            onMissedRelease: { [weak self] action in
                self?.shortcutModeHandler.recoverMissedRelease(for: action)
            },
            onPressCaptured: { [preRollPress = engine.recorder.preRollPress] action, eventTime in
                guard Self.recordingActions.contains(action) else { return }
                preRollPress.hold(at: eventTime)
            },
            reason: reason
        )
        if [ShortcutAction.primaryRecording, .secondaryRecording].contains(where: shortcutMonitor.isMonitoring) {
            hotkeyAvailability = .available
        } else if primaryShortcut == nil && secondaryShortcut == nil {
            hotkeyAvailability = .unconfigured
        } else {
            hotkeyAvailability = AXIsProcessTrusted() ? .unavailable : .needsAccessibility
        }
    }

    private var standaloneModifierActions: Set<ShortcutAction> {
        Self.standaloneModifierActions(primaryMode: primaryRecordingShortcutMode, secondaryMode: secondaryRecordingShortcutMode)
    }

    private var chordBreakerDelays: [ShortcutAction: TimeInterval] {
        Self.chordBreakerDelays(primaryMode: primaryRecordingShortcutMode, secondaryMode: secondaryRecordingShortcutMode)
    }

    /// Dictate Without Processing follows the primary shortcut's mode.
    static func standaloneModifierActions(primaryMode: Mode, secondaryMode: Mode) -> Set<ShortcutAction> {
        var actions = Set<ShortcutAction>()
        if primaryMode == .toggle || primaryMode == .doubleTap {
            actions.formUnion([.primaryRecording, .rawRecording])
        }
        if secondaryMode == .toggle || secondaryMode == .doubleTap {
            actions.insert(.secondaryRecording)
        }
        return actions
    }

    static func chordBreakerDelays(primaryMode: Mode, secondaryMode: Mode) -> [ShortcutAction: TimeInterval] {
        var delays: [ShortcutAction: TimeInterval] = [:]
        delays[.primaryRecording] = primaryMode.chordBreakerDelay
        delays[.rawRecording] = primaryMode.chordBreakerDelay
        delays[.secondaryRecording] = secondaryMode.chordBreakerDelay
        return delays
    }

    private func updateStandaloneModifierActions() {
        shortcutMonitor.updateStandaloneModifierActions(standaloneModifierActions, chordBreakerDelays: chordBreakerDelays)
    }

    private func recordingMode(for action: ShortcutAction) -> Mode? {
        switch action {
        case .primaryRecording, .rawRecording:
            return primaryRecordingShortcutMode
        case .secondaryRecording:
            return secondaryRecordingShortcutMode
        default:
            return nil
        }
    }

    private nonisolated static let recordingActions: Set<ShortcutAction> = [.primaryRecording, .secondaryRecording, .rawRecording]

    private func handleGlobalShortcut(_ action: ShortcutAction) async {
        ShortcutDiagnostics.notice("utility action=\(action.storageName) result=requested")
        switch action {
        case .pasteLastTranscription:
            LastTranscriptionService.pasteLastTranscription(from: engine.modelContext)
        case .pasteLastEnhancement:
            LastTranscriptionService.pasteLastEnhancement(from: engine.modelContext)
        case .retryLastTranscription:
            LastTranscriptionService.retryLastTranscription(
                from: engine.modelContext,
                transcriptionModelManager: engine.transcriptionModelManager,
                serviceRegistry: engine.serviceRegistry,
                enhancementService: engine.enhancementService
            )
        case .openQuickHistory:
            QuickHistoryController.shared.show(modelContext: engine.modelContext, engine: engine)
        case .quickAddToDictionary:
            DictionaryQuickAddManager.shared.toggle(modelContainer: engine.modelContext.container)
        default:
            break
        }
    }

    private func removeAllMonitoring(reason: String) {
        shortcutMonitor.stop(reason: reason)
    }

    var isShortcutConfigured: Bool {
        let isPrimaryShortcutConfigured =
            primaryRecordingShortcut != .none && ShortcutStore.shortcut(for: .primaryRecording) != nil
        let isSecondaryShortcutConfigured =
            secondaryRecordingShortcut == .none || ShortcutStore.shortcut(for: .secondaryRecording) != nil
        return isPrimaryShortcutConfigured && isSecondaryShortcutConfigured
    }

    func updateShortcutStatus() {
        // Called when a shortcut changes
        refreshShortcutMonitoring(reason: "status-update")
    }

    private func setupLifecycleDiagnostics() {
        let center = NSWorkspace.shared.notificationCenter
        for (name, reason) in [
            (NSWorkspace.willSleepNotification, "sleep"),
            (NSWorkspace.didWakeNotification, "wake"),
            (NSWorkspace.sessionDidResignActiveNotification, "session-inactive"),
            (NSWorkspace.sessionDidBecomeActiveNotification, "session-active"),
        ] {
            lifecycleObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                Task { @MainActor in
                    ShortcutDiagnostics.observeEnvironment(reason: reason, force: true)
                }
            })
        }
    }

    isolated deinit {
        if let shortcutChangeObserver {
            NotificationCenter.default.removeObserver(shortcutChangeObserver)
        }

        for observer in lifecycleObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        removeAllMonitoring(reason: "deinit")
    }
}

@MainActor
private final class RecordingShortcutModeSource {
    var primaryMode: RecordingShortcutManager.Mode

    init(primaryMode: RecordingShortcutManager.Mode) {
        self.primaryMode = primaryMode
    }
}

@MainActor
final class RecordingShortcutModeHandler {
    // Tap callbacks read this snapshot without waiting for the main actor.
    private nonisolated let heldShortcut = OSAllocatedUnfairLock<Shortcut?>(initialState: nil)

    nonisolated var heldRecordingShortcut: Shortcut? { heldShortcut.withLock { $0 } }

    private let canHandleShortcutAction: @MainActor () -> Bool
    private let isRecorderVisible: @MainActor () -> Bool
    private let recordingState: @MainActor () -> RecordingState
    private let isShortcutHeld: @MainActor (ShortcutAction) -> Bool
    private let finishHeldRecording: @MainActor () -> Void
    private let toggleRecorderPanel: @MainActor (UUID?, TimeInterval, DictationProcessing) async -> Void
    private let captureProcessing: @MainActor () -> DictationProcessing?
    private let cancelRecording: @MainActor () async -> Void
    private let retractStartSound: @MainActor () -> Void

    private var shortcutPressStartTime: TimeInterval?
    private var isHandsFreeRecording = false
    private var isShortcutPressed = false
    private var activeRecordingShortcutAction: ShortcutAction?
    private var activeRecordingShortcutMode: RecordingShortcutManager.Mode?
    private var interruptedRecordingActions: [ShortcutAction: TimeInterval] = [:]
    private var activeShortcutCanCancelAccidentalStart = false
    private var activeShortcutIsDoubleTap = false
    private var lastShortcutPressTime: TimeInterval?
    private let now: () -> TimeInterval
    private var stateRevision: UInt64 = 0
    private var pendingDoubleTapReleaseTimes: [ShortcutAction: TimeInterval] = [:]

    private let shortcutPressCooldown: TimeInterval = 0.25
    private let hybridPressThreshold: TimeInterval = 0.5
    private let doubleTapThreshold: TimeInterval = 0.7
    /// A push-to-talk release sooner than this is an accidental start, not a dictation.
    nonisolated static let shortTapThreshold: TimeInterval = 0.3

    init(
        canHandleShortcutAction: @escaping @MainActor () -> Bool,
        isRecorderVisible: @escaping @MainActor () -> Bool,
        recordingState: @escaping @MainActor () -> RecordingState,
        isShortcutHeld: @escaping @MainActor (ShortcutAction) -> Bool,
        finishHeldRecording: @escaping @MainActor () -> Void,
        toggleRecorderPanel: @escaping @MainActor (UUID?, TimeInterval, DictationProcessing) async -> Void,
        captureProcessing: @escaping @MainActor () -> DictationProcessing? = { nil },
        cancelRecording: @escaping @MainActor () async -> Void,
        retractStartSound: @escaping @MainActor () -> Void = {},
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.canHandleShortcutAction = canHandleShortcutAction
        self.isRecorderVisible = isRecorderVisible
        self.recordingState = recordingState
        self.isShortcutHeld = isShortcutHeld
        self.finishHeldRecording = finishHeldRecording
        self.toggleRecorderPanel = toggleRecorderPanel
        self.captureProcessing = captureProcessing
        self.cancelRecording = cancelRecording
        self.retractStartSound = retractStartSound
        self.now = now
    }

    func reset() {
        heldShortcut.withLock { $0 = nil }
        stateRevision &+= 1
        isShortcutPressed = false
        shortcutPressStartTime = nil
        isHandsFreeRecording = false
        activeRecordingShortcutAction = nil
        activeRecordingShortcutMode = nil
        interruptedRecordingActions.removeAll()
        activeShortcutCanCancelAccidentalStart = false
        activeShortcutIsDoubleTap = false
        clearPendingDoubleTaps()
    }

    func clearPendingDoubleTaps() {
        pendingDoubleTapReleaseTimes.removeAll()
    }

    func clearPendingDoubleTap(for action: ShortcutAction) {
        if pendingDoubleTapReleaseTimes.removeValue(forKey: action) != nil {
            logDecision(action, phase: "double-tap", result: "pending-cleared")
        }
    }

    func resetShortcutState(for action: ShortcutAction) {
        resetShortcutStates(for: [action])
    }

    func resetShortcutStates(for actions: Set<ShortcutAction>) {
        resetShortcutStates(for: actions, preservingRecording: false)
    }

    func recoverMissedRelease(for action: ShortcutAction) {
        logDecision(action, phase: "recovery", result: "missed-release")
        // Recover the gesture without stopping the recording.
        resetShortcutStates(for: [action], preservingRecording: true)
    }

    private func resetShortcutStates(for actions: Set<ShortcutAction>, preservingRecording: Bool) {
        for action in actions {
            pendingDoubleTapReleaseTimes.removeValue(forKey: action)
            interruptedRecordingActions.removeValue(forKey: action)
        }
        guard let activeRecordingShortcutAction, actions.contains(activeRecordingShortcutAction) else { return }
        heldShortcut.withLock { $0 = nil }
        let wasHoldMode = activeRecordingShortcutMode == .pushToTalk || activeRecordingShortcutMode == .hybrid
        // Finish held recordings when monitoring resets.
        let state = recordingState()
        let shouldFinishHeldRecording = !preservingRecording && isRecorderVisible()
            && wasHoldMode
            && (state == .starting || state == .recording || (state == .idle && activeShortcutCanCancelAccidentalStart))
        logDecision(activeRecordingShortcutAction, phase: "reset", result: shouldFinishHeldRecording ? "finish-held-recording" : "clear-press", detail: "preservingRecording=\(preservingRecording)")
        stateRevision &+= 1
        isShortcutPressed = false
        shortcutPressStartTime = nil
        self.activeRecordingShortcutAction = nil
        activeRecordingShortcutMode = nil
        activeShortcutCanCancelAccidentalStart = false
        activeShortcutIsDoubleTap = false
        isHandsFreeRecording = isRecorderVisible()
            && (preservingRecording || !wasHoldMode)
        if shouldFinishHeldRecording {
            finishHeldRecording()
        }
    }

    func handleShortcutDown(
        action: ShortcutAction,
        eventTime: TimeInterval,
        mode: RecordingShortcutManager.Mode,
        modeId: UUID? = nil
    ) async {
        // The shortcut kind that started a capture owns it; the other kind neither finishes it nor double-taps.
        if let owner = captureProcessing(), owner != action.dictationProcessing {
            logDecision(action, phase: "down", result: "ignored-other-owner")
            clearPendingDoubleTap(for: action)
            return
        }

        if mode != .doubleTap, let lastTrigger = lastShortcutPressTime,
            now() - lastTrigger < shortcutPressCooldown
        {
            logDecision(action, phase: "down", result: "ignored-cooldown")
            return
        }

        if isShortcutPressed, let activeAction = activeRecordingShortcutAction {
            guard !isShortcutHeld(activeAction) else {
                logDecision(action, phase: "down", result: "ignored-held-shortcut")
                return
            }
            // Let a fresh press take over the active recording.
            resetShortcutStates(for: [activeAction], preservingRecording: true)
        }

        if interruptedRecordingActions.removeValue(forKey: action) == eventTime {
            logDecision(action, phase: "down", result: "ignored-interrupted")
            return
        }

        if mode == .doubleTap && (!canHandleShortcutAction() || recordingState() == .starting) {
            logDecision(action, phase: "down", result: "ignored-engine-state")
            clearPendingDoubleTap(for: action)
            return
        }

        stateRevision &+= 1
        isShortcutPressed = true
        let shortcut = canHandleShortcutAction() ? ShortcutStore.shortcut(for: action) : nil
        heldShortcut.withLock { $0 = shortcut }
        activeRecordingShortcutAction = action
        activeRecordingShortcutMode = mode
        activeShortcutIsDoubleTap = mode == .doubleTap
        activeShortcutCanCancelAccidentalStart = mode != .doubleTap && canCurrentShortcutPressCancelAccidentalStart
        if mode != .doubleTap {
            lastShortcutPressTime = now()
        }
        shortcutPressStartTime = eventTime

        switch mode {
        case .toggle:
            guard canHandleShortcutAction() else {
                logDecision(action, phase: "down", result: "ignored-engine-state", detail: "mode=toggle")
                return
            }
            logDecision(action, phase: "down", result: "toggle-recorder", detail: "mode=toggle")
            await toggleRecorderPanel(modeId, eventTime, action.dictationProcessing)

        case .hybrid:
            if isHandsFreeRecording {
                isHandsFreeRecording = false
                guard canHandleShortcutAction() else {
                    logDecision(action, phase: "recording", result: "ignored-engine-state")
                    return
                }
                logDecision(action, phase: "down", result: "stop-hands-free", detail: "mode=\(mode.rawValue)")
                await toggleRecorderPanel(modeId, eventTime, action.dictationProcessing)
                return
            }

            if !isRecorderVisible() {
                guard canHandleShortcutAction() else {
                    logDecision(action, phase: "recording", result: "ignored-engine-state")
                    return
                }
                logDecision(action, phase: "down", result: "start-recording", detail: "mode=\(mode.rawValue)")
                await toggleRecorderPanel(modeId, eventTime, action.dictationProcessing)
            } else {
                logDecision(action, phase: "down", result: "wait-for-release", detail: "mode=\(mode.rawValue)")
            }

        case .pushToTalk:
            if !isRecorderVisible() {
                guard canHandleShortcutAction() else {
                    logDecision(action, phase: "recording", result: "ignored-engine-state")
                    return
                }
                logDecision(action, phase: "down", result: "start-recording", detail: "mode=pushToTalk")
                await toggleRecorderPanel(modeId, eventTime, action.dictationProcessing)
            } else {
                logDecision(action, phase: "down", result: "recorder-already-visible", detail: "mode=pushToTalk")
            }

        case .doubleTap:
            break
        }
    }

    func handleShortcutUp(
        action: ShortcutAction,
        eventTime: TimeInterval,
        mode: RecordingShortcutManager.Mode,
        modeId: UUID? = nil
    ) async {
        guard isShortcutPressed, activeRecordingShortcutAction == action else {
            logDecision(action, phase: "up", result: "ignored-no-matching-press")
            return
        }
        guard let pressedAt = shortcutPressStartTime, eventTime >= pressedAt else { return }
        let pressDuration = eventTime - pressedAt
        let pressStartedRecording = activeShortcutCanCancelAccidentalStart
        heldShortcut.withLock { $0 = nil }
        shortcutPressStartTime = nil
        isShortcutPressed = false
        activeRecordingShortcutAction = nil
        activeRecordingShortcutMode = nil
        activeShortcutCanCancelAccidentalStart = false
        activeShortcutIsDoubleTap = false
        let releaseRevision = stateRevision

        switch mode {
        case .toggle:
            // Release clears the toggle shortcut's pressed state.
            isHandsFreeRecording = isRecorderVisible() && (recordingState() == .starting || recordingState() == .recording)
            logDecision(action, phase: "up", result: "toggle-release", detail: "mode=toggle")

        case .pushToTalk:
            if isRecorderVisible() {
                guard canHandleShortcutAction() else {
                    logDecision(action, phase: "recording", result: "ignored-engine-state")
                    return
                }
                if pressStartedRecording && pressDuration < Self.shortTapThreshold {
                    logDecision(action, phase: "up", result: "discard-short-tap", detail: "mode=pushToTalk duration=\(String(format: "%.3f", pressDuration))")
                    retractStartSound()
                    await cancelRecording()
                    return
                }
                logDecision(action, phase: "up", result: "stop-recording", detail: "mode=pushToTalk")
                await toggleRecorderPanel(modeId, eventTime, action.dictationProcessing)
            } else {
                logDecision(action, phase: "up", result: "recorder-hidden", detail: "mode=pushToTalk")
            }

        case .hybrid:
            if pressDuration >= hybridPressThreshold && recordingState() == .recording {
                guard canHandleShortcutAction() else {
                    logDecision(action, phase: "recording", result: "ignored-engine-state")
                    return
                }
                logDecision(action, phase: "up", result: "stop-recording", detail: "mode=hybrid duration=\(String(format: "%.3f", pressDuration))")
                await toggleRecorderPanel(modeId, eventTime, action.dictationProcessing)
            } else {
                logDecision(action, phase: "up", result: "hands-free", detail: "mode=hybrid duration=\(String(format: "%.3f", pressDuration))")
                isHandsFreeRecording = true
            }

        case .doubleTap:
            guard canHandleShortcutAction(), recordingState() != .starting else {
                logDecision(action, phase: "up", result: "ignored-engine-state", detail: "mode=doubleTap")
                clearPendingDoubleTap(for: action)
                break
            }
            if pressDuration < 0 || pressDuration > doubleTapThreshold {
                logDecision(action, phase: "up", result: "ignored-tap-duration", detail: "duration=\(String(format: "%.3f", pressDuration))")
                pendingDoubleTapReleaseTimes.removeValue(forKey: action)
            } else if let firstRelease = pendingDoubleTapReleaseTimes.removeValue(forKey: action),
                eventTime - firstRelease >= 0,
                eventTime - firstRelease <= doubleTapThreshold
            {
                logDecision(action, phase: "up", result: "double-tap-triggered", detail: "interval=\(String(format: "%.3f", eventTime - firstRelease))")
                await toggleRecorderPanel(modeId, pressedAt, action.dictationProcessing)
                if stateRevision == releaseRevision {
                    isHandsFreeRecording = isRecorderVisible()
                }
            } else {
                logDecision(action, phase: "up", result: "waiting-second-tap")
                pendingDoubleTapReleaseTimes[action] = eventTime
            }
        }
    }

    func handleInterruption(action: ShortcutAction, pressedAt: TimeInterval) async {
        guard isShortcutPressed, activeRecordingShortcutAction == action else {
            if canCurrentShortcutPressCancelAccidentalStart {
                interruptedRecordingActions[action] = pressedAt
                logDecision(action, phase: "interrupted", result: "queued-before-press")
            } else {
                logDecision(action, phase: "interrupted", result: "ignored-inactive")
            }
            return
        }

        guard shortcutPressStartTime == pressedAt else { return }

        if activeShortcutIsDoubleTap {
            heldShortcut.withLock { $0 = nil }
            logDecision(action, phase: "interrupted", result: "clear-double-tap")
            stateRevision &+= 1
            isShortcutPressed = false
            shortcutPressStartTime = nil
            activeRecordingShortcutAction = nil
            activeRecordingShortcutMode = nil
            activeShortcutCanCancelAccidentalStart = false
            activeShortcutIsDoubleTap = false
            pendingDoubleTapReleaseTimes.removeValue(forKey: action)
            return
        }

        guard activeShortcutCanCancelAccidentalStart else {
            logDecision(action, phase: "interrupted", result: "ignored-existing-recording")
            return
        }
        // A capture already stopped by other means keeps its transcription.
        guard canHandleShortcutAction() else {
            logDecision(action, phase: "interrupted", result: "ignored-engine-state")
            return
        }

        logDecision(action, phase: "interrupted", result: "cancel-accidental-start")
        reset()
        retractStartSound()
        await cancelRecording()
    }

    private func logDecision(_ action: ShortcutAction, phase: String, result: String, detail: String = "") {
        ShortcutDiagnostics.notice("decision action=\(action.storageName) phase=\(phase) result=\(result) state=\(recordingState()) visible=\(isRecorderVisible()) active=\(activeRecordingShortcutAction?.storageName ?? "none") \(detail)")
    }

    var diagnosticSummary: String {
        "pressed=\(isShortcutPressed) handsFree=\(isHandsFreeRecording) active=\(activeRecordingShortcutAction?.storageName ?? "none") pendingDoubleTaps=\(pendingDoubleTapReleaseTimes.keys.map(\.storageName).sorted().joined(separator: ","))"
    }

    private var canCurrentShortcutPressCancelAccidentalStart: Bool {
        !isRecorderVisible() && recordingState() == .idle
    }
}
