import AppKit
import Combine
import Foundation
import MediaRemoteAdapter
import SwiftUI

@MainActor
class PlaybackController: ObservableObject {
    static let shared = PlaybackController()
    private var mediaController: MediaRemoteAdapter.MediaController
    private struct OwnedPause {
        let id = UUID()
        let bundleID: String
        let stateRevision: UInt64
    }

    private var ownedPause: OwnedPause?
    private var recordingSessionID = UUID()
    private var mediaStateRevision: UInt64 = 0
    private var isMediaPlaying = false
    private var lastKnownTrackInfo: TrackInfo?
    private var stateRequests: [UUID: CheckedContinuation<TrackInfo?, Never>] = [:]

    nonisolated static let pauseBrowserMediaKey = "isPauseBrowserMediaEnabled"

    @Published var isPauseMediaEnabled: Bool = UserDefaults.standard.bool(forKey: "isPauseMediaEnabled") {
        didSet {
            UserDefaults.standard.set(isPauseMediaEnabled, forKey: "isPauseMediaEnabled")

            if isPauseMediaEnabled {
                startMediaTracking()
            } else {
                stopMediaTracking()
            }
        }
    }

    /// Applies only with Pause Media; requesting its permission belongs to the settings control.
    @Published var isPauseBrowserMediaEnabled: Bool = UserDefaults.standard.bool(forKey: PlaybackController.pauseBrowserMediaKey) {
        didSet {
            UserDefaults.standard.set(isPauseBrowserMediaEnabled, forKey: Self.pauseBrowserMediaKey)
            if !isPauseBrowserMediaEnabled { browserMediaPauser.forgetPause() }
        }
    }

    private let browserMediaPauser: BrowserMediaPauser
    private var pausesBrowserMedia: Bool { isPauseMediaEnabled && isPauseBrowserMediaEnabled }

    private init() {
        mediaController = MediaRemoteAdapter.MediaController()
        browserMediaPauser = BrowserMediaPauser(
            permission: TCCSystemAudioRecordingPermission(),
            commands: MediaRemoteBrowserMediaCommands(mediaController: mediaController),
            makeListener: { CoreAudioBrowserAudioListener($0) }
        )

        setupMediaControllerCallbacks()

        if isPauseMediaEnabled {
            startMediaTracking()
        }
    }

    private func setupMediaControllerCallbacks() {
        mediaController.onTrackInfoReceived = { [weak self] trackInfo in
            // MediaRemoteAdapter delivers its callbacks on the main queue.
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isMediaPlaying = trackInfo?.payload.isPlaying ?? false
                self.lastKnownTrackInfo = trackInfo
                self.mediaStateRevision &+= 1

            }
        }

        mediaController.onListenerTerminated = {}
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
        lastKnownTrackInfo = nil
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
            if let currentApp = lastKnownTrackInfo?.payload.bundleIdentifier,
                currentApp != ownedPause.bundleID {
                self.ownedPause = nil
            } else if lastKnownTrackInfo?.payload.isPlaying != true {
                return
            }
        }
        guard isMediaPlaying, lastKnownTrackInfo?.payload.isPlaying == true else {
            return
        }
        guard let bundleId = lastKnownTrackInfo?.payload.bundleIdentifier else {
            return
        }

        try? await Task.sleep(nanoseconds: 50_000_000)
        guard !Task.isCancelled, sessionID == recordingSessionID, isPauseMediaEnabled else {
            return
        }
        guard lastKnownTrackInfo?.payload.bundleIdentifier == bundleId,
            lastKnownTrackInfo?.payload.isPlaying == true else {
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
        let delay = MediaController.shared.audioResumptionDelay

        // The adapter debounces state changes. Keep ownership while its pause update arrives.
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while canRestore(pause, sessionID: sessionID),
            ProcessInfo.processInfo.systemUptime < deadline {
            if mediaStateRevision > pause.stateRevision,
                lastKnownTrackInfo?.payload.bundleIdentifier == pause.bundleID,
                lastKnownTrackInfo?.payload.isPlaying == false {
                break
            }
            if let currentApp = lastKnownTrackInfo?.payload.bundleIdentifier,
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
        let currentTrackInfo = await fetchCurrentTrackInfo()
        guard canRestore(pause, sessionID: sessionID) else { return }
        guard isAppStillRunning(bundleId: pause.bundleID) else {
            ownedPause = nil
            return
        }
        guard let currentTrackInfo, let currentBundleId = currentTrackInfo.payload.bundleIdentifier else {
            // Do not blindly toggle or forget a pause if the state lookup failed.
            return
        }
        guard currentBundleId == pause.bundleID else {
            ownedPause = nil
            return
        }
        guard currentTrackInfo.payload.isPlaying != true else {
            ownedPause = nil
            return
        }
        guard currentTrackInfo.payload.isPlaying == false else {
            return
        }

        Self.sendMediaPlayPauseKey()
        ownedPause = nil
    }

    private func restoreBrowserPlayback(sessionID: UUID) async {
        let delay = MediaController.shared.audioResumptionDelay
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

    private func fetchCurrentTrackInfo() async -> TrackInfo? {
        let requestID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: nil)
                    return
                }
                stateRequests[requestID] = continuation
                mediaController.getTrackInfo { [weak self] trackInfo in
                    MainActor.assumeIsolated {
                        self?.finishStateRequest(requestID, trackInfo: trackInfo)
                    }
                }
                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    self?.finishStateRequest(requestID, trackInfo: nil)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.finishStateRequest(requestID, trackInfo: nil)
            }
        }
    }

    private func finishStateRequest(_ requestID: UUID, trackInfo: TrackInfo?) {
        stateRequests.removeValue(forKey: requestID)?.resume(returning: trackInfo)
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

    private func isAppStillRunning(bundleId: String) -> Bool {
        let runningApps = NSWorkspace.shared.runningApplications
        return runningApps.contains { $0.bundleIdentifier == bundleId }
    }
}

/// MediaRemote's explicit play and pause through the adapter's listener process.
private struct MediaRemoteBrowserMediaCommands: BrowserMediaCommandSending, @unchecked Sendable {
    // The adapter serializes commands on its own queue.
    let mediaController: MediaRemoteAdapter.MediaController

    func send(_ command: BrowserMediaCommand) -> Bool {
        switch command {
        case .play: mediaController.play()
        case .pause: mediaController.pause()
        }
        return true
    }
}
