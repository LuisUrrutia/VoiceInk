import AppKit

struct PastePolicy: Equatable {
    let method: PasteMethod
    let settleDelay: TimeInterval
    let usesRemoteClipboard: Bool

    static func resolve(
        for application: PasteApplication, preferredMethod: PasteMethod, pushedClipboard: Bool = false,
        losesSyntheticPaste: Bool = false
    ) -> PastePolicy {
        // Remote typing is meant for remote viewers, so it bypasses clipboard synchronization.
        if application.bundleIdentifier == "com.apple.ScreenSharing", preferredMethod != .remoteTyping {
            return PastePolicy(method: .appleScript, settleDelay: pushedClipboard ? 0.2 : 0.8, usesRemoteClipboard: true)
        }
        // No settle delay closes Chromium 155/156's paste race, so these destinations get typed text.
        let method = losesSyntheticPaste && preferredMethod.usesClipboard ? .directTyping : preferredMethod
        let settleDelay: TimeInterval
        switch method {
        case .standard, .directTyping: settleDelay = 0.02
        case .appleScript: settleDelay = 0.05
        case .remoteTyping: settleDelay = 0.2
        }
        return PastePolicy(method: method, settleDelay: settleDelay, usesRemoteClipboard: false)
    }
}

@MainActor
final class PasteSession {
    struct Environment {
        var frontmost: () -> PasteApplication?
        var isRunning: (PasteApplication) -> Bool
        var activate: (PasteApplication) -> Bool
        var wait: (TimeInterval) async throws -> Void
        var pushClipboard: (String, String) async throws -> Void
        var postPaste: (PasteMethod, @escaping () -> Bool) async -> Bool
        /// Typing methods return their result and an optional cause for the failure notification.
        var typeText: (PasteMethod, String, FinishAndSendKey, @escaping () -> Bool) async
            -> (result: CursorPaster.PasteResult, failure: String?) = { _, _, _, _ in (.commandNotPosted, nil) }
        var adjustText: (String, PasteApplication, PasteMethod) async -> String = { text, _, _ in text }
        var losesSyntheticPaste: (PasteApplication) -> Bool = { _ in false }
        var autoLearn: (String, pid_t, Bool) async -> UInt64?
        var cancelAutoLearn: (UInt64) async -> Void
        var send: (FinishAndSendKey, PastePolicy) -> Void
        var reportFailure: (String) -> Void
    }

    private typealias Snapshot = [[(NSPasteboard.PasteboardType, Data)]]
    private struct ClipboardOwnership {
        let id: String
        let changeCount: Int
        let savedContents: Snapshot
    }

    private let pasteboard: NSPasteboard
    private let environment: Environment
    private var ownership: ClipboardOwnership?
    private var pendingRemotePush: Task<Void, Error>?
    private var latestRequest: UInt64 = 0

    init(pasteboard: NSPasteboard, environment: Environment) {
        self.pasteboard = pasteboard
        self.environment = environment
    }

    func paste(
        _ text: String,
        destination: PasteDestination = .currentApplication,
        restoreClipboard: Bool,
        restoreDelay: TimeInterval,
        preferredMethod: PasteMethod,
        remotePushCommand: String?,
        sendKey: FinishAndSendKey = .none,
        timing: RecordingTimingTrace? = nil,
        shouldCancel: @escaping () -> Bool = { false }
    ) async -> CursorPaster.PasteOutcome {
        var unreachedOutcome = RecordingTimingTrace.Outcome.canceled
        defer {
            for phase in [RecordingTimingTrace.Phase.destinationReady, .clipboardSettled, .pasteCommandPosted] {
                timing?.mark(phase, outcome: unreachedOutcome)
            }
        }
        func finish(_ result: CursorPaster.PasteResult) -> CursorPaster.PasteOutcome {
            unreachedOutcome = result == .cancelled ? .canceled : .failed
            return outcome(result)
        }
        let canceled = { Task.isCancelled || shouldCancel() }
        guard !canceled() else { return finish(.cancelled) }

        latestRequest &+= 1
        let request = latestRequest
        var owner: ClipboardOwnership?
        func takeClipboard(_ value: String) -> Bool {
            let previousContents = ownership.flatMap { owns($0) ? $0.savedContents : nil } ?? snapshot()
            let id = UUID().uuidString
            guard ClipboardManager.setClipboard(value, transient: restoreClipboard, sessionID: id, on: pasteboard) else {
                return false
            }
            let newOwner = ClipboardOwnership(id: id, changeCount: pasteboard.changeCount, savedContents: previousContents)
            owner = newOwner
            ownership = newOwner
            return true
        }
        let copyFailure = String(localized: "Could not copy the transcription to the clipboard.")
        let supersededPush = pendingRemotePush
        supersededPush?.cancel()

        func mayContinue() -> Bool {
            !canceled() && request == latestRequest && (owner.map { owns($0) } ?? true)
        }
        func fail(_ result: CursorPaster.PasteResult, cause: String? = nil) -> CursorPaster.PasteOutcome {
            if request == latestRequest {
                if let owner {
                    if owns(owner) {
                        ClipboardManager.setClipboard(text, on: pasteboard)
                        ownership = nil
                    }
                } else if result != .cancelled {
                    // Typing leaves the clipboard untouched, so failures need the same recovery copy.
                    ClipboardManager.setClipboard(text, on: pasteboard)
                }
            }
            if result != .cancelled {
                environment.reportFailure(
                    cause ?? String(localized: "Could not paste into the destination application. The transcription is on the clipboard.")
                )
            }
            return finish(result)
        }

        do {
            // A newer command must wait for the older process to stop writing the remote clipboard.
            _ = await supersededPush?.result
            guard mayContinue() else { return fail(.cancelled) }
            let target: PasteApplication
            switch destination {
            case .currentApplication:
                guard let current = environment.frontmost() else { return fail(.targetUnavailable) }
                target = current
            case .originalApplication(let original):
                guard let original, environment.isRunning(original) else { return fail(.targetUnavailable) }
                target = original
                if environment.frontmost() != target {
                    guard mayContinue(), environment.activate(target) else { return fail(.targetUnavailable) }
                    let activationDeadline = ContinuousClock.now.advanced(by: .seconds(0.6))
                    for _ in 0..<20 {
                        guard mayContinue() else { return fail(.cancelled) }
                        if environment.frontmost() == target { break }
                        if ContinuousClock.now >= activationDeadline { break }
                        guard environment.isRunning(target) else { return fail(.targetUnavailable) }
                        try await environment.wait(0.03)
                    }
                }
            }

            guard mayContinue() else { return fail(.cancelled) }
            guard environment.frontmost() == target, environment.isRunning(target) else {
                return fail(.targetUnavailable)
            }
            timing?.mark(.destinationReady)

            let losesSyntheticPaste = environment.losesSyntheticPaste(target)
            var policy = PastePolicy.resolve(
                for: target, preferredMethod: preferredMethod, losesSyntheticPaste: losesSyntheticPaste
            )
            if policy.method.usesClipboard {
                guard takeClipboard(text) else { return fail(.commandNotPosted, cause: copyFailure) }
            }
            let deliveredText = await environment.adjustText(text, target, policy.method)
            guard mayContinue() else { return fail(.cancelled) }
            if deliveredText != text, owner != nil {
                guard takeClipboard(deliveredText) else { return fail(.commandNotPosted, cause: copyFailure) }
            }

            if policy.usesRemoteClipboard,
                let command = remotePushCommand?.trimmingCharacters(in: .whitespacesAndNewlines),
                !command.isEmpty
            {
                do {
                    let push = Task { try await environment.pushClipboard(command, deliveredText) }
                    pendingRemotePush = push
                    try await withTaskCancellationHandler {
                        try await push.value
                    } onCancel: {
                        push.cancel()
                    }
                    if mayContinue() { pendingRemotePush = nil }
                    policy = PastePolicy.resolve(
                        for: target, preferredMethod: preferredMethod, pushedClipboard: true,
                        losesSyntheticPaste: losesSyntheticPaste
                    )
                } catch is CancellationError {
                    return fail(.cancelled)
                } catch {
                    environment.reportFailure(
                        String(localized: "Remote clipboard push failed. Trying Screen Sharing clipboard synchronization.")
                    )
                }
            }

            try await environment.wait(policy.settleDelay)
            guard mayContinue() else { return fail(.cancelled) }
            let canPost = {
                mayContinue() && self.environment.frontmost() == target && self.environment.isRunning(target)
            }
            guard canPost() else { return fail(.targetUnavailable) }
            timing?.mark(.clipboardSettled)
            if policy.method.usesClipboard {
                let posted = await environment.postPaste(policy.method, canPost)
                guard posted else { return fail(canceled() ? .cancelled : .commandNotPosted) }
            } else {
                let typed = await environment.typeText(policy.method, deliveredText, sendKey, canPost)
                guard typed.result == .commandPosted else {
                    // Partial typing is always reported because part of the text may have been inserted.
                    let interrupted = typed.result == .commandNotPosted && !mayContinue()
                    return fail(interrupted ? .cancelled : typed.result, cause: typed.failure)
                }
            }
            timing?.mark(.pasteCommandPosted)

            let generation = await environment.autoLearn(deliveredText, target.processID, true)
            if sendKey.isEnabled {
                try await environment.wait(0.15)
                if canPost() {
                    if let generation { await environment.cancelAutoLearn(generation) }
                    if canPost() { environment.send(sendKey, policy) }
                }
            }
            if restoreClipboard, let owner { scheduleRestore(owner, delay: restoreDelay) }
            unreachedOutcome = .skipped
            return CursorPaster.PasteOutcome(result: .commandPosted, autoLearnGeneration: generation, target: target)
        } catch {
            if restoreClipboard, let owner { scheduleRestore(owner, delay: restoreDelay) }
            return finish(.cancelled)
        }
    }

    private func outcome(_ result: CursorPaster.PasteResult) -> CursorPaster.PasteOutcome {
        CursorPaster.PasteOutcome(result: result, autoLearnGeneration: nil, target: nil)
    }

    private func owns(_ owner: ClipboardOwnership) -> Bool {
        pasteboard.changeCount == owner.changeCount
            && pasteboard.string(forType: ClipboardManager.pasteSessionType) == owner.id
    }

    private func snapshot() -> Snapshot {
        (pasteboard.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
    }

    private func scheduleRestore(_ owner: ClipboardOwnership, delay: TimeInterval) {
        Task { @MainActor in
            do { try await environment.wait(min(max(delay, 0.25), 5)) } catch { return }
            guard owns(owner) else { return }
            pasteboard.clearContents()
            let items = owner.savedContents.map { contents in
                let item = NSPasteboardItem()
                for (type, data) in contents { item.setData(data, forType: type) }
                return item
            }
            if !items.isEmpty { pasteboard.writeObjects(items) }
            if ownership?.id == owner.id { ownership = nil }
        }
    }
}
