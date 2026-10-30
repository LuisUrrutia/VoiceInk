import AppKit
import Carbon
import Foundation
import os

class CursorPaster {
    private static let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "CursorPaster")

    enum PasteResult: Equatable {
        case commandPosted
        case commandNotPosted
        case commandPartiallyPosted
        case targetUnavailable
        case cancelled

        var didPostPasteCommand: Bool { self == .commandPosted }
    }

    struct PasteOutcome {
        let result: PasteResult
        let autoLearnGeneration: UInt64?
        let target: PasteApplication?
    }

    private static let pasteShortcutEventDelay: TimeInterval = 0.01
    // Smart punctuation reads the focused field, which needs settled focus.
    private static let smartPunctuationFocusDelay: TimeInterval = 0.20
    private static let textContextReader = PasteTextContextReader()

    @MainActor private static let session = PasteSession(
        pasteboard: .general,
        environment: PasteSession.Environment(
            frontmost: { .frontmost },
            isRunning: { $0.runningApplication != nil },
            activate: { $0.runningApplication?.activate() ?? false },
            wait: { try await Task.sleep(for: .seconds($0)) },
            pushClipboard: { command, text in
                _ = try await CustomCommandDeliveryRunner.run(
                    command: command, timeout: 3,
                    context: CustomCommandDeliveryContext(transcript: text, includesTranscriptEnvironment: false)
                )
            },
            postPaste: { method, canPost in
                guard canPost() else { return false }
                return await deliverWithDiagnostics(method) { sessionID in
                    if method == .appleScript {
                        return pasteUsingAppleScript(sessionID: sessionID) ? .commandPosted : .commandNotPosted
                    }
                    return await pasteFromClipboard(sessionID: sessionID, canPost: canPost)
                }.didPostPasteCommand
            },
            typeText: { method, text, sendKey, canPost in
                guard canPost() else { return (.commandNotPosted, nil) }
                var failure: String?
                let result = await deliverWithDiagnostics(method) { _ in
                    let typed = await typeText(text, method: method, sendKey: sendKey, canContinue: canPost)
                    failure = typed.failure
                    return typed.result
                }
                return (result, failure)
            },
            adjustText: { text, target, method in
                await adjustedText(text, target: target, method: method)
            },
            autoLearn: { text, processID, posted in
                guard AutoLearnSettings.isEnabled else { return nil }
                return await AutoLearnService.shared.pasteDidFinish(
                    text: text, processID: processID, commandPosted: posted
                )
            },
            cancelAutoLearn: { await AutoLearnService.shared.cancelForAutoSend(generation: $0) },
            send: { key, policy in
                if policy.usesRemoteClipboard { performSendUsingAppleScript(key) }
                else { performSendKey(key) }
            },
            reportFailure: {
                logger.error("Paste delivery failed")
                NotificationManager.shared.showNotification(title: $0, type: .warning, duration: 5)
            }
        )
    )

    static func pasteAtCursor(_ text: String) {
        Task { @MainActor in _ = await startPasteAtCursor(text).value }
    }

    @MainActor
    @discardableResult
    static func startPasteAtCursor(
        _ text: String, deliverySession: RecordingDeliverySession? = nil, sendKey: FinishAndSendKey = .none
    ) -> Task<PasteOutcome, Never> {
        let task = Task { @MainActor in
            await session.paste(
                text,
                destination: deliverySession?.destination ?? .currentApplication,
                restoreClipboard: UserDefaults.standard.bool(forKey: "restoreClipboardAfterPaste"),
                restoreDelay: UserDefaults.standard.double(forKey: "clipboardRestoreDelay"),
                preferredMethod: PasteMethod.current(),
                remotePushCommand: UserDefaults.standard.string(forKey: PasteTargetSettings.remoteClipboardPushCommandKey),
                sendKey: sendKey,
                timing: deliverySession?.timing,
                shouldCancel: { deliverySession?.isCancelled == true }
            )
        }
        deliverySession?.own(task)
        return task
    }

    /// Text for the resolved destination; the saved transcript stays unchanged.
    @MainActor
    private static func adjustedText(_ text: String, target: PasteApplication, method: PasteMethod) async -> String {
        var result = method.usesClipboard ? text : DirectTextTyper.normalizedText(text)
        if UserDefaults.standard.bool(forKey: SmartPunctuation.settingsKey) {
            await wait(smartPunctuationFocusDelay)
            if let snapshot = await textContextReader.read(processID: target.processID) {
                let adjusted = SmartPunctuation.adjusted(result, context: snapshot.context)
                if adjusted != result {
                    let current = await textContextReader.read(processID: target.processID)
                    if NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processID,
                        PasteTextContextReader.matches(snapshot, current) {
                        result = adjusted
                    }
                }
            }
        }
        if method == .remoteTyping, let prepared = RemoteTextTyper.textForTyping(result) {
            // Auto Learn should observe what was actually typed.
            result = prepared
        }
        return result
    }

    @MainActor
    private static func deliverWithDiagnostics(
        _ method: PasteMethod, _ deliver: (String) async -> PasteResult
    ) async -> PasteResult {
        let startedAt = ProcessInfo.processInfo.systemUptime
        let sessionID = UUID().uuidString
        let application = NSWorkspace.shared.frontmostApplication
        let appIdentifier = application?.bundleIdentifier ?? "unknown"
        let focusDiagnostics = PasteFocusDiagnostics(sessionID: sessionID)
        focusDiagnostics.captureAroundPaste(processID: application?.processIdentifier, appIdentifier: appIdentifier)
        let result = await deliver(sessionID)
        focusDiagnostics.captureAfterPaste(
            commandPosted: result.didPostPasteCommand,
            commandProcessID: application?.processIdentifier
        )
        logger.notice(
            "Paste id=\(sessionID, privacy: .public) app=\(appIdentifier, privacy: .public) method=\(method.rawValue, privacy: .public) commandPosted=\(result.didPostPasteCommand, privacy: .public) elapsedMs=\(elapsedMilliseconds(since: startedAt), privacy: .public)"
        )
        return result
    }

    @MainActor
    private static func typeText(
        _ text: String, method: PasteMethod, sendKey: FinishAndSendKey, canContinue: () -> Bool
    ) async -> (result: PasteResult, failure: String?) {
        switch method {
        case .remoteTyping:
            switch await RemoteTextTyper.type(text, sendKey: sendKey, canContinue: canContinue) {
            case .posted:
                return (.commandPosted, nil)
            case .notPosted:
                let failure = text.isEmpty
                    ? nil : String(localized: "Remote typing could not start. Check Accessibility access and keyboard layout.")
                return (.commandNotPosted, failure)
            case .unsupportedCharacters:
                return (.commandNotPosted, String(localized: "Remote typing could not find any characters it can type."))
            case .partiallyPosted:
                return (
                    .commandPartiallyPosted,
                    String(localized: "Remote typing was interrupted. Check the destination before retrying.")
                )
            }
        case .directTyping:
            // Never retry partial typing: a retry could duplicate text.
            switch await DirectTextTyper.type(text, canContinue: canContinue) {
            case .posted: return (.commandPosted, nil)
            case .notPosted: return (.commandNotPosted, nil)
            case .partiallyPosted: return (.commandPartiallyPosted, nil)
            }
        case .standard, .appleScript:
            return (.commandNotPosted, nil)
        }
    }

    // MARK: - AppleScript paste

    // "X – QWERTY ⌘" layouts remap to QWERTY when Command is held, so keystroke "v" resolves
    // the wrong key code. key code 9 (physical V) bypasses layout translation for those layouts.
    private static func makeScript(_ source: String) -> NSAppleScript? {
        let script = NSAppleScript(source: source)
        var error: NSDictionary?
        script?.compileAndReturnError(&error)
        return script
    }

    private static let pasteScriptKeystroke = makeScript(
        "tell application \"System Events\" to keystroke \"v\" using command down")
    private static let pasteScriptKeyCode = makeScript(
        "tell application \"System Events\" to key code 9 using command down")

    @MainActor
    private static var layoutSwitchesToQWERTYOnCommand: Bool {
        let source = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        guard let nameRef = TISGetInputSourceProperty(source, kTISPropertyLocalizedName) else { return false }
        return (Unmanaged<CFString>.fromOpaque(nameRef).takeUnretainedValue() as String).hasSuffix("⌘")
    }

    @MainActor
    private static func pasteUsingAppleScript(sessionID: String) -> Bool {
        guard let script = layoutSwitchesToQWERTYOnCommand ? pasteScriptKeyCode : pasteScriptKeystroke else {
            logger.error("AppleScript paste script is unavailable id=\(sessionID, privacy: .public)")
            return false
        }

        var error: NSDictionary?
        script.executeAndReturnError(&error)
        if let error {
            logger.error("AppleScript paste failed id=\(sessionID, privacy: .public): \(String(describing: error), privacy: .public)")
        }
        return error == nil
    }

    // MARK: - CGEvent paste

    // Posts Cmd+V via CGEvent without modifying the active input source.
    @MainActor
    private static func pasteFromClipboard(sessionID: String, canPost: () -> Bool) async -> PasteResult {
        guard AXIsProcessTrusted() else {
            logger.error("Accessibility permission is required to paste with simulated key events id=\(sessionID, privacy: .public)")
            return .commandNotPosted
        }

        let source = CGEventSource(stateID: .privateState)

        guard let cmdDown = CGEvent(keyboardEventSource: source, virtualKey: 0x37, keyDown: true),
            let vDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true),
            let vUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false),
            let cmdUp = CGEvent(keyboardEventSource: source, virtualKey: 0x37, keyDown: false)
        else {
            logger.error("Failed to create Cmd+V keyboard events id=\(sessionID, privacy: .public)")
            return .commandNotPosted
        }

        cmdDown.flags = .maskCommand
        vDown.flags = .maskCommand
        vUp.flags = .maskCommand
        cmdUp.flags = []

        guard canPost() else { return .commandNotPosted }
        cmdDown.post(tap: .cghidEventTap)
        defer { cmdUp.post(tap: .cghidEventTap) }
        await wait(pasteShortcutEventDelay)
        guard canPost() else { return .commandNotPosted }
        vDown.post(tap: .cghidEventTap)
        await wait(pasteShortcutEventDelay)
        vUp.post(tap: .cghidEventTap)
        await wait(pasteShortcutEventDelay)

        return .commandPosted
    }

    private static func elapsedMilliseconds(since start: TimeInterval) -> Int {
        Int((ProcessInfo.processInfo.systemUptime - start) * 1_000)
    }

    private static func wait(_ seconds: TimeInterval) async {
        guard seconds > 0 else { return }
        let nanoseconds = UInt64(seconds * 1_000_000_000)
        try? await Task.sleep(nanoseconds: nanoseconds)
    }

    @MainActor
    private static func performSendUsingAppleScript(_ key: FinishAndSendKey) {
        let modifiers: String
        switch key {
        case .none: return
        case .enter: modifiers = ""
        case .shiftEnter: modifiers = " using shift down"
        case .commandEnter: modifiers = " using command down"
        }
        let script = makeScript("tell application \"System Events\" to key code 36" + modifiers)
        var error: NSDictionary?
        script?.executeAndReturnError(&error)
        if script == nil || error != nil { logger.error("Screen Sharing send command failed") }
    }

    // MARK: - Send Key

    static func performSendKey(_ key: FinishAndSendKey) {
        guard key.isEnabled else { return }
        guard AXIsProcessTrusted() else { return }

        let source = CGEventSource(stateID: .privateState)
        let enterDown = CGEvent(keyboardEventSource: source, virtualKey: 0x24, keyDown: true)
        let enterUp = CGEvent(keyboardEventSource: source, virtualKey: 0x24, keyDown: false)

        switch key {
        case .none: return
        case .enter: break
        case .shiftEnter:
            enterDown?.flags = .maskShift
            enterUp?.flags = .maskShift
        case .commandEnter:
            enterDown?.flags = .maskCommand
            enterUp?.flags = .maskCommand
        }

        enterDown?.post(tap: .cghidEventTap)
        enterUp?.post(tap: .cghidEventTap)
    }
}
