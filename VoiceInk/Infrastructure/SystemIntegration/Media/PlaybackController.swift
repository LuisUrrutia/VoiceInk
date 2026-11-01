import AppKit
import Combine
import Foundation
import MediaRemoteAdapter
import SwiftUI

struct NowPlayingState: Equatable {
    let bundleIdentifier: String?
    let isPlaying: Bool?
}

/// The Now Playing reads and commands PlaybackController uses from MediaRemote.
protocol NowPlayingMediaControlling: AnyObject {
    /// Delivered on the main queue.
    var onStateReceived: ((NowPlayingState?) -> Void)? { get set }
    func startListening()
    func stopListening()
    func pause()
    func fetchState(_ onReceive: @escaping (NowPlayingState?) -> Void)
}

@MainActor
class PlaybackController: ObservableObject {
    static let shared = PlaybackController.live()
    private let mediaController: any NowPlayingMediaControlling
    private let defaults: UserDefaults
    private let sendPlayPauseKey: @MainActor () -> Void
    private let isApplicationRunning: @MainActor (String) -> Bool
    private let resumptionDelay: @MainActor () -> Double
    private struct OwnedPause {
        let id = UUID()
        let bundleID: String
        let stateRevision: UInt64
    }

    private var ownedPause: OwnedPause?
    private var recordingSessionID = UUID()
    private var mediaStateRevision: UInt64 = 0
    private var isMediaPlaying = false
    private var lastKnownState: NowPlayingState?
    private var stateRequests: [UUID: CheckedContinuation<NowPlayingState?, Never>] = [:]

    nonisolated static let pauseBrowserMediaKey = "isPauseBrowserMediaEnabled"

    @Published var isPauseMediaEnabled: Bool {
        didSet {
            defaults.set(isPauseMediaEnabled, forKey: "isPauseMediaEnabled")

            if isPauseMediaEnabled {
                startMediaTracking()
            } else {
                stopMediaTracking()
            }
        }
    }

    /// Applies only with Pause Media; requesting its permission belongs to the settings control.
    @Published var isPauseBrowserMediaEnabled: Bool {
        didSet {
            defaults.set(isPauseBrowserMediaEnabled, forKey: Self.pauseBrowserMediaKey)
            if !isPauseBrowserMediaEnabled { browserMediaPauser.forgetPause() }
        }
    }

    private let browserMediaPauser: BrowserMediaPauser
    private var pausesBrowserMedia: Bool { isPauseMediaEnabled && isPauseBrowserMediaEnabled }

    init(
        mediaController: any NowPlayingMediaControlling,
        browserMediaPauser: BrowserMediaPauser,
        defaults: UserDefaults = .standard,
        sendPlayPauseKey: @escaping @MainActor () -> Void,
        isApplicationRunning: @escaping @MainActor (String) -> Bool,
        resumptionDelay: @escaping @MainActor () -> Double
    ) {
        self.mediaController = mediaController
        self.browserMediaPauser = browserMediaPauser
        self.defaults = defaults
        self.sendPlayPauseKey = sendPlayPauseKey
        self.isApplicationRunning = isApplicationRunning
        self.resumptionDelay = resumptionDelay
        isPauseMediaEnabled = defaults.bool(forKey: "isPauseMediaEnabled")
        isPauseBrowserMediaEnabled = defaults.bool(forKey: Self.pauseBrowserMediaKey)

        setupMediaControllerCallbacks()

        if isPauseMediaEnabled {
            startMediaTracking()
        }
    }

    private func setupMediaControllerCallbacks() {
        mediaController.onStateReceived = { [weak self] state in
            // MediaRemoteAdapter delivers its callbacks on the main queue.
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isMediaPlaying = state?.isPlaying ?? false
                self.lastKnownState = state
                self.mediaStateRevision &+= 1

            }
        }
    }

    private static func live() -> PlaybackController {
        let adapter = MediaRemoteNowPlaying()
        return PlaybackController(
            mediaController: adapter,
            browserMediaPauser: BrowserMediaPauser(
                permission: TCCSystemAudioRecordingPermission(),
                commands: MediaRemoteCommandSender(),
                makeListener: { CoreAudioBrowserAudioListener($0) }
            ),
            sendPlayPauseKey: sendMediaPlayPauseKey,
            isApplicationRunning: { bundleID in
                NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == bundleID }
            },
            resumptionDelay: { MediaController.shared.audioResumptionDelay }
        )
    }

    private func startMediaTracking() {
        mediaController.startListening()
    }

    private func stopMediaTracking() {
        recordingSessionID = UUID()
        ownedPause = nil
        browserMediaPauser.forgetPause()
        mediaController.stopListening()
        isMediaPlaying = false
        lastKnownState = nil
    }

    func beginRecordingSession() -> UUID {
        recordingSessionID = UUID()
        // A new recording inherits a pause whose restoration has not completed.
        browserMediaPauser.abandonPendingResume()
        return recordingSessionID
    }

    /// One pause is owned at a time: a browser pause and a Now Playing pause would
    /// both resume through the same system command.
    func pauseMedia(sessionID: UUID) async {
        await browserMediaPauser.settle()
        guard !browserMediaPauser.ownsPause else { return }
        await pauseNowPlayingMedia(sessionID: sessionID)
        guard ownedPause == nil, pausesBrowserMedia, sessionID == recordingSessionID, !Task.isCancelled else {
            return
        }
        await browserMediaPauser.pause()
    }

    private func pauseNowPlayingMedia(sessionID: UUID) async {
        guard sessionID == recordingSessionID, !Task.isCancelled, isPauseMediaEnabled else {
            return
        }
        if let ownedPause {
            if let currentApp = lastKnownState?.bundleIdentifier,
                currentApp != ownedPause.bundleID {
                self.ownedPause = nil
            } else if lastKnownState?.isPlaying != true {
                return
            }
        }
        guard isMediaPlaying, lastKnownState?.isPlaying == true else {
            return
        }
        guard let bundleId = lastKnownState?.bundleIdentifier else {
            return
        }

        try? await Task.sleep(nanoseconds: 50_000_000)
        guard !Task.isCancelled, sessionID == recordingSessionID, isPauseMediaEnabled else {
            return
        }
        guard lastKnownState?.bundleIdentifier == bundleId,
            lastKnownState?.isPlaying == true else {
            return
        }

        // Own only commands actually queued, not a cancelled 50 ms pre-pause delay.
        ownedPause = OwnedPause(bundleID: bundleId, stateRevision: mediaStateRevision)
        mediaController.pause()
    }

    func resumeMedia(sessionID: UUID) async {
        guard sessionID == recordingSessionID, !Task.isCancelled, isPauseMediaEnabled else {
            return
        }
        await browserMediaPauser.settle()
        if browserMediaPauser.ownsPause {
            await restoreBrowserPlayback(sessionID: sessionID)
            return
        }
        guard let pause = ownedPause else {
            return
        }
        // Recorder owns the cancellable restoration task; no nested task is needed.
        await restorePlayback(pause: pause, sessionID: sessionID)
    }

    private func canRestore(_ pause: OwnedPause, sessionID: UUID) -> Bool {
        !Task.isCancelled && isPauseMediaEnabled
            && sessionID == recordingSessionID && ownedPause?.id == pause.id
    }

    private func restorePlayback(pause: OwnedPause, sessionID: UUID) async {
        let delay = resumptionDelay()

        // The adapter debounces state changes. Keep ownership while its pause update arrives.
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while canRestore(pause, sessionID: sessionID),
            ProcessInfo.processInfo.systemUptime < deadline {
            if mediaStateRevision > pause.stateRevision,
                lastKnownState?.bundleIdentifier == pause.bundleID,
                lastKnownState?.isPlaying == false {
                break
            }
            if let currentApp = lastKnownState?.bundleIdentifier,
                currentApp != pause.bundleID {
                break
            }
            do {
                try await Task.sleep(nanoseconds: 25_000_000)
            } catch {
                return
            }
        }

        guard canRestore(pause, sessionID: sessionID) else { return }
        if delay > 0 {
            do {
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            } catch {
                return
            }
        }
        guard canRestore(pause, sessionID: sessionID) else { return }

        // Re-read live state after the delay: a global toggle must not pause media
        // the user already resumed, or act on another player.
        let currentState = await fetchCurrentState()
        guard canRestore(pause, sessionID: sessionID) else { return }
        guard isApplicationRunning(pause.bundleID) else {
            ownedPause = nil
            return
        }
        guard let currentState, let currentBundleId = currentState.bundleIdentifier else {
            // Do not blindly toggle or forget a pause if the state lookup failed.
            return
        }
        guard currentBundleId == pause.bundleID else {
            ownedPause = nil
            return
        }
        guard currentState.isPlaying != true else {
            ownedPause = nil
            return
        }
        guard currentState.isPlaying == false else {
            return
        }

        sendPlayPauseKey()
        ownedPause = nil
    }

    private func restoreBrowserPlayback(sessionID: UUID) async {
        let delay = resumptionDelay()
        if delay > 0 {
            do {
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            } catch {
                return
            }
        }
        guard !Task.isCancelled, pausesBrowserMedia, sessionID == recordingSessionID else { return }
        await browserMediaPauser.resume()
    }

    private func fetchCurrentState() async -> NowPlayingState? {
        let requestID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: nil)
                    return
                }
                stateRequests[requestID] = continuation
                mediaController.fetchState { [weak self] state in
                    MainActor.assumeIsolated {
                        self?.finishStateRequest(requestID, state: state)
                    }
                }
                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    self?.finishStateRequest(requestID, state: nil)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.finishStateRequest(requestID, state: nil)
            }
        }
    }

    private func finishStateRequest(_ requestID: UUID, state: NowPlayingState?) {
        stateRequests.removeValue(forKey: requestID)?.resume(returning: state)
    }

    /// Simulate the hardware media Play/Pause key (NX_KEYTYPE_PLAY = 16).
    /// Some apps (e.g. Plexamp) ignore the MediaRemote `play` command but
    /// respond to the same HID key event the physical F8 key produces.
    private static func sendMediaPlayPauseKey() {
        func post(down: Bool) {
            let flags: UInt = down ? 0xa00 : 0xb00
            let data1 = Int((16 << 16) | ((down ? 0xa : 0xb) << 8))
            let event = NSEvent.otherEvent(
                with: .systemDefined,
                location: .zero,
                modifierFlags: NSEvent.ModifierFlags(rawValue: flags),
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                subtype: 8,
                data1: data1,
                data2: -1
            )
            event?.cgEvent?.post(tap: .cghidEventTap)
        }
        post(down: true)
        post(down: false)
    }
}

/// MediaRemoteAdapter's listener process, reduced to the state PlaybackController reads.
private final class MediaRemoteNowPlaying: NowPlayingMediaControlling {
    private let adapter = MediaRemoteAdapter.MediaController()

    var onStateReceived: ((NowPlayingState?) -> Void)? {
        didSet {
            adapter.onTrackInfoReceived = onStateReceived.map { receive in { receive(Self.state($0)) } }
        }
    }

    init() {
        adapter.onListenerTerminated = {}
    }

    func startListening() { adapter.startListening() }
    func stopListening() { adapter.stopListening() }
    func pause() { adapter.pause() }
    func fetchState(_ onReceive: @escaping (NowPlayingState?) -> Void) {
        adapter.getTrackInfo { onReceive(Self.state($0)) }
    }

    private static func state(_ trackInfo: TrackInfo?) -> NowPlayingState? {
        trackInfo.map { NowPlayingState(bundleIdentifier: $0.payload.bundleIdentifier, isPlaying: $0.payload.isPlaying) }
    }
}

/// MediaRemote's explicit play and pause, sent synchronously so the browser sequence starts
/// confirming after the command and sees a refusal. The adapter's queued commands report neither.
struct MediaRemoteCommandSender: BrowserMediaCommandSending, @unchecked Sendable {
    typealias SendCommand = @convention(c) (UInt32, CFDictionary?) -> UInt8

    private static let resolved: SendCommand? = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY),
            let symbol = dlsym(handle, "MRMediaRemoteSendCommand")
        else { return nil }
        return unsafeBitCast(symbol, to: SendCommand.self)
    }()

    private let sendCommand: SendCommand?

    init(sendCommand: SendCommand? = MediaRemoteCommandSender.resolved) {
        self.sendCommand = sendCommand
    }

    /// `kMRPlay` is 0 and `kMRPause` is 1; a missing symbol refuses every command.
    func send(_ command: BrowserMediaCommand) -> Bool {
        guard let sendCommand else { return false }
        return sendCommand(command == .play ? 0 : 1, nil) != 0
    }
}
