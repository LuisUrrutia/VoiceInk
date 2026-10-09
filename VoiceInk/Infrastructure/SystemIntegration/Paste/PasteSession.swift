import AppKit

struct PastePolicy: Equatable {
    let method: PasteMethod
    let settleDelay: TimeInterval
    let usesRemoteClipboard: Bool

    static func resolve(for application: PasteApplication, preferredMethod: PasteMethod, pushedClipboard: Bool = false)
        -> PastePolicy
    {
        let remote = application.bundleIdentifier == "com.apple.ScreenSharing"
        let localSettleDelay: TimeInterval = preferredMethod == .standard ? 0.02 : 0.05
        return PastePolicy(
            method: remote ? .appleScript : preferredMethod,
            settleDelay: remote ? (pushedClipboard ? 0.2 : 0.8) : localSettleDelay,
            usesRemoteClipboard: remote
        )
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

        let previousContents = ownership.flatMap { owns($0) ? $0.savedContents : nil } ?? snapshot()
        let id = UUID().uuidString
        guard ClipboardManager.setClipboard(text, transient: restoreClipboard, sessionID: id, on: pasteboard) else {
            environment.reportFailure(String(localized: "Could not copy the transcription to the clipboard."))
            return finish(.commandNotPosted)
        }
        let owner = ClipboardOwnership(id: id, changeCount: pasteboard.changeCount, savedContents: previousContents)
        ownership = owner
        let supersededPush = pendingRemotePush
        supersededPush?.cancel()

        func mayContinue() -> Bool { !canceled() && owns(owner) }
        func fail(_ result: CursorPaster.PasteResult) -> CursorPaster.PasteOutcome {
            if owns(owner) {
                ClipboardManager.setClipboard(text, on: pasteboard)
                ownership = nil
            }
            if result != .cancelled {
                environment.reportFailure(
                    String(localized: "Could not paste into the destination application. The transcription is on the clipboard.")
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

            var policy = PastePolicy.resolve(for: target, preferredMethod: preferredMethod)
            if policy.usesRemoteClipboard,
                let command = remotePushCommand?.trimmingCharacters(in: .whitespacesAndNewlines),
                !command.isEmpty
            {
                do {
                    let push = Task { try await environment.pushClipboard(command, text) }
                    pendingRemotePush = push
                    try await withTaskCancellationHandler {
                        try await push.value
                    } onCancel: {
                        push.cancel()
                    }
                    if owns(owner) { pendingRemotePush = nil }
                    policy = PastePolicy.resolve(for: target, preferredMethod: preferredMethod, pushedClipboard: true)
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
            let posted = await environment.postPaste(policy.method, canPost)
            guard posted else { return fail(canceled() ? .cancelled : .commandNotPosted) }
            timing?.mark(.pasteCommandPosted)

            let generation = await environment.autoLearn(text, target.processID, posted)
            if sendKey.isEnabled {
                try await environment.wait(0.15)
                if canPost() {
                    if let generation { await environment.cancelAutoLearn(generation) }
                    if canPost() { environment.send(sendKey, policy) }
                }
            }
            if restoreClipboard { scheduleRestore(owner, delay: restoreDelay) }
            unreachedOutcome = .skipped
            return CursorPaster.PasteOutcome(result: .commandPosted, autoLearnGeneration: generation, target: target)
        } catch {
            if restoreClipboard { scheduleRestore(owner, delay: restoreDelay) }
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
            do { try await environment.wait(max(delay, 0.25)) } catch { return }
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
