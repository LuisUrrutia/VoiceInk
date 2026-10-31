import Foundation
import os

/// The explicit system media commands. Never the toggle: it can start other media.
enum BrowserMediaCommand: Equatable, Sendable {
    case play, pause
}

protocol BrowserMediaCommandSending: Sendable {
    func send(_ command: BrowserMediaCommand) -> Bool
}

/// Which browser processes a listener hears.
enum BrowserAudioProcesses: Sendable {
    /// Only those with open output; an unknown output state counts as open.
    case playing
    /// Every running browser: a paused one closes its output a few seconds later.
    case all
}

/// One listen over the browsers' own output. Build one per pause or resume.
protocol BrowserAudioListening: AnyObject {
    /// A browser is using the microphone: probably a call.
    func isBrowserUsingMicrophone() -> Bool
    /// The peak of the browsers' output over `window`, in dBFS; nil when it cannot listen.
    func peakDBFS(over window: Duration) async -> Float?
    /// A browser process runs and every one has closed its audio output.
    func isBrowserOutputClosed() -> Bool
    func close()
}

/// Lets a pause or play be abandoned until it is sent, and never after.
final class BrowserMediaCommandGate: @unchecked Sendable {
    private enum State { case open, sent, abandoned }
    private let state = OSAllocatedUnfairLock(initialState: State.open)

    /// Returns false once abandoned; after a successful claim, abandoning has no effect.
    func claimSend() -> Bool {
        state.withLock { state in
            guard state == .open else { return state == .sent }
            state = .sent
            return true
        }
    }

    func abandon() {
        state.withLock { state in
            if state == .open { state = .abandoned }
        }
    }

    var isAbandoned: Bool { state.withLock { $0 == .abandoned } }
}

/// Adapted from Hex's `browser_media`: pause a browser only when it is audibly playing,
/// and play it again only after it went silent right after VoiceInk's own pause.
enum BrowserMediaSequence {
    /// Sound: a peak above this in every listen window.
    static let soundDBFS: Float = -60
    /// Silence: a peak below this in consecutive windows soon after the pause.
    static let silenceDBFS: Float = -90
    static let window: Duration = .milliseconds(100)
    static let listenWindows = 3
    /// The silence must start in the first windows after the pause: a sound
    /// that ends later on its own is not the pause reaching the browser.
    static let confirmWindows = 5
    static let silentWindows = 2
    static let resumeListen: Duration = .milliseconds(300)
    /// After play the browser must sound within this many windows, or the play
    /// reached another app and is paused again.
    static let playCheckWindows = 20
    /// A browser that closed its output opens it again within this many windows of play.
    static let openCheckWindows = 10

    enum ResumeOutcome: Equatable {
        case resumed
        /// The browser played again on its own, or VoiceInk could not hear it: no play.
        case leftAlone
        /// Play reached no browser, so VoiceInk paused again.
        case pausedAgain
        /// Sent play; the browser could not be heard afterward.
        case unconfirmed
        case commandRefused
        /// Abandoned before play was sent, so the pause stays owned.
        case abandoned
    }

    private static let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "BrowserMedia")

    /// Returns true when VoiceInk paused a sounding browser and saw it go silent.
    static func pause(
        _ audio: some BrowserAudioListening,
        commands: some BrowserMediaCommandSending,
        gate: BrowserMediaCommandGate
    ) async -> Bool {
        if audio.isBrowserUsingMicrophone() {
            logger.info("Left the browser alone: it is using the microphone")
            return false
        }
        for _ in 0..<listenWindows {
            guard !gate.isAbandoned else { return false }
            guard let peak = await audio.peakDBFS(over: window) else {
                logger.info("Left the browser alone: cannot hear it")
                return false
            }
            guard peak > soundDBFS else {
                logger.info("Left the browser alone: it is silent")
                return false
            }
        }
        guard gate.claimSend() else { return false }
        guard commands.send(.pause) else {
            logger.info("The system refused the pause command")
            return false
        }
        var silent = 0
        for _ in 0..<confirmWindows {
            if let peak = await audio.peakDBFS(over: window), peak < silenceDBFS {
                silent += 1
                if silent == silentWindows {
                    logger.info("Paused the browser")
                    return true
                }
            } else {
                silent = 0
            }
        }
        logger.info("Sent pause but the browser still plays; it will not get play")
        return false
    }

    static func resume(
        _ audio: some BrowserAudioListening,
        commands: some BrowserMediaCommandSending,
        gate: BrowserMediaCommandGate
    ) async -> ResumeOutcome {
        var heard = true
        switch await audio.peakDBFS(over: resumeListen) {
        case let peak? where peak <= soundDBFS:
            break
        case .some:
            logger.info("The browser already plays again; sent no play")
            return .leftAlone
        // A pause longer than about 10 s closes the browser's output, and a
        // tap on closed outputs delivers nothing: that browser is still paused.
        case nil where audio.isBrowserOutputClosed():
            heard = false
        case nil:
            logger.info("Cannot hear the browser; sent no play")
            return .leftAlone
        }
        guard gate.claimSend() else { return .abandoned }
        guard commands.send(.play) else {
            logger.info("The system refused the play command")
            return .commandRefused
        }
        // The output opens again about 300 ms after play.
        for window in 1...playCheckWindows {
            switch await audio.peakDBFS(over: Self.window) {
            case let peak? where peak > soundDBFS:
                logger.info("Resumed the browser")
                return .resumed
            case .some:
                heard = true
            case nil where !heard:
                if window == openCheckWindows, audio.isBrowserOutputClosed() {
                    return pauseAgain(commands)
                }
            case nil:
                logger.info("Sent play but cannot hear the browser any more")
                return .unconfirmed
            }
        }
        if !heard, !audio.isBrowserOutputClosed() {
            logger.info("Sent play but cannot hear the browser")
            return .unconfirmed
        }
        return pauseAgain(commands)
    }

    /// A closed or reloaded tab stays silent, and play went to whatever macOS
    /// now treats as playing: pause that once.
    private static func pauseAgain(_ commands: some BrowserMediaCommandSending) -> ResumeOutcome {
        logger.info("The browser stayed silent after play; sent pause again")
        _ = commands.send(.pause)
        return .pausedAgain
    }
}

/// Owns at most one browser pause across overlapping recordings. Callers decide
/// whether Pause Media and this setting apply; this type only sequences the work.
@MainActor
final class BrowserMediaPauser {
    typealias ListenerFactory = @Sendable (BrowserAudioProcesses) -> any BrowserAudioListening

    private let permission: any SystemAudioRecordingPermissionChecking
    private let commands: any BrowserMediaCommandSending
    private let makeListener: ListenerFactory
    private(set) var ownsPause = false
    private var pending: Task<Void, Never>?
    private var pendingGate: BrowserMediaCommandGate?
    private var generation: UInt64 = 0
    private nonisolated static let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "BrowserMedia")

    init(
        permission: any SystemAudioRecordingPermissionChecking,
        commands: any BrowserMediaCommandSending,
        makeListener: @escaping ListenerFactory
    ) {
        self.permission = permission
        self.commands = commands
        self.makeListener = makeListener
    }

    /// Cancelling the caller abandons the pause until it is sent; a sent pause is still confirmed.
    func pause() async {
        await settle()
        guard !ownsPause else { return }
        let gate = BrowserMediaCommandGate()
        await withTaskCancellationHandler {
            guard !Task.isCancelled else { return }
            let task = startWork(gate: gate) { [permission, commands, makeListener] in
                // An unknown answer skips: a tap could open the macOS prompt mid-dictation.
                guard permission.authorization() == .granted else {
                    Self.logger.info("Left the browser alone: System Audio Recording is not allowed")
                    return false
                }
                let audio = makeListener(.playing)
                defer { audio.close() }
                return await BrowserMediaSequence.pause(audio, commands: commands, gate: gate)
            } finish: { owner, paused in
                if paused { owner.ownsPause = true }
            }
            await task.value
        } onCancel: {
            gate.abandon()
        }
    }

    /// Cancelling the caller keeps the pause owned until play is sent.
    func resume() async {
        await settle()
        guard ownsPause else { return }
        let gate = BrowserMediaCommandGate()
        await withTaskCancellationHandler {
            guard !Task.isCancelled else { return }
            let task = startWork(gate: gate) { [commands, makeListener] in
                let audio = makeListener(.all)
                defer { audio.close() }
                return await BrowserMediaSequence.resume(audio, commands: commands, gate: gate)
            } finish: { owner, outcome in
                if outcome != .abandoned { owner.ownsPause = false }
            }
            await task.value
        } onCancel: {
            gate.abandon()
        }
    }

    /// Waits for a pause in progress, so its ownership is known.
    func settle() async {
        while let task = pending {
            await task.value
            if pending == task { return }
        }
    }

    /// A new recording abandons a resume that has not sent play, inheriting the pause.
    func abandonPendingResume() {
        pendingGate?.abandon()
    }

    /// A turned-off setting gives up the pause without playing.
    func forgetPause() {
        pendingGate?.abandon()
        generation &+= 1
        ownsPause = false
    }

    private func startWork<Result: Sendable>(
        gate: BrowserMediaCommandGate,
        _ work: @escaping @Sendable () async -> Result,
        finish: @escaping @MainActor (BrowserMediaPauser, Result) -> Void
    ) -> Task<Void, Never> {
        let generation = generation
        let task = Task { @MainActor [weak self] in
            // A @Sendable closure is nonisolated, so the CoreAudio work runs off the main actor.
            let result = await work()
            guard let self, self.generation == generation else { return }
            finish(self, result)
        }
        pending = task
        pendingGate = gate
        return task
    }
}
