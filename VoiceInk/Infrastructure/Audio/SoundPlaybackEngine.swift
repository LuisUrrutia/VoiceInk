@preconcurrency import AVFoundation
import CoreAudio
import Foundation
import os

/// When a sound began playing on the monotonic uptime clock, and how long it lasts.
struct SoundPlayback: Equatable, Sendable {
    let startNanoseconds: UInt64
    let duration: TimeInterval
    var reference: FeedbackSoundReference? = nil
}

protocol SoundPlayer: AnyObject {
    var isPlaying: Bool { get }
    var duration: TimeInterval { get }
    var volume: Float { get set }
    var currentTime: TimeInterval { get set }
    @discardableResult func prepareToPlay() -> Bool
    @discardableResult func play() -> Bool
    func stop()
    func setVolume(_ volume: Float, fadeDuration: TimeInterval)
}

extension AVAudioPlayer: SoundPlayer {}

final class SoundPlaybackEngine: @unchecked Sendable {
    enum Sound: CaseIterable {
        case start
        case stop
        case done
        case error
        case esc
    }

    struct Source: Equatable {
        let url: URL
        let volume: Float
    }

    /// Leaves time for a chord to cancel an accidental start before the tone is heard.
    static let startDelay: TimeInterval = 0.05
    static let retractionFadeDuration: TimeInterval = 0.02

    private struct LoadedPlayer {
        let player: SoundPlayer
        let source: Source
        let outputGeneration: Int
        var reference: FeedbackSoundReference?
    }

    private let queue = DispatchQueue(label: "com.prakashjoshipax.voiceink.soundPlayback", qos: .userInitiated)
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "SoundPlaybackEngine")
    private let makePlayer: (URL) throws -> SoundPlayer

    private var sources: [Sound: [Source]] = [:]
    private var players: [Sound: LoadedPlayer] = [:]
    private var outputGeneration = 0
    private var pendingStart: DispatchWorkItem?
    private var startGeneration = 0
    private var outputListener: AudioObjectPropertyListenerBlock?
    private let startPlayback = OSAllocatedUnfairLock<SoundPlayback?>(initialState: nil)

    var lastStartSoundPlayback: SoundPlayback? {
        startPlayback.withLock { $0 }
    }

    init(
        makePlayer: @escaping (URL) throws -> SoundPlayer = { try AVAudioPlayer(contentsOf: $0) },
        observesDefaultOutput: Bool = true
    ) {
        self.makePlayer = makePlayer
        if observesDefaultOutput {
            observeDefaultOutput()
        }
    }

    deinit {
        guard let outputListener else { return }
        var address = Self.defaultOutputAddress
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, outputListener)
    }

    /// Each sound plays its first source that loads, so a missing custom file falls back to its built-in sound.
    func setup(_ sources: [Sound: [Source]]) {
        queue.async { [weak self] in
            guard let self else { return }
            self.sources = sources
            self.players.removeAll()
            for sound in Sound.allCases {
                self.load(sound)
            }
        }
    }

    func play(_ sound: Sound) {
        queue.async { [weak self] in
            self?.playOnQueue(sound)
        }
    }

    func scheduleStart(after delay: TimeInterval = startDelay) {
        queue.async { [weak self] in
            guard let self else { return }
            self.pendingStart?.cancel()
            let item = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.pendingStart = nil
                self.playOnQueue(.start)
            }
            self.pendingStart = item
            self.queue.asyncAfter(deadline: .now() + delay, execute: item)
        }
    }

    /// Silences a start tone that has not begun and fades out one that is playing.
    func retractStart(fadeDuration: TimeInterval = retractionFadeDuration) {
        queue.async { [weak self] in
            guard let self else { return }
            if let pendingStart = self.pendingStart {
                pendingStart.cancel()
                self.pendingStart = nil
                return
            }
            guard let loaded = self.players[.start], loaded.player.isPlaying else { return }
            let generation = self.startGeneration
            loaded.player.setVolume(0, fadeDuration: fadeDuration)
            self.queue.asyncAfter(deadline: .now() + fadeDuration) { [weak self] in
                guard let self, self.startGeneration == generation else { return }
                loaded.player.stop()
                loaded.player.currentTime = 0
                loaded.player.setVolume(loaded.source.volume, fadeDuration: 0)
            }
        }
    }

    /// A prepared player that already played stays silent after the default output changes, so rebuild players.
    func defaultOutputDidChange() {
        queue.async { [weak self] in
            self?.reloadForOutputChange()
        }
    }

    func waitUntilIdle() {
        queue.sync {}
    }

    private func playOnQueue(_ sound: Sound) {
        if sound == .start {
            startGeneration &+= 1
        }
        let current = players[sound].flatMap { $0.outputGeneration == outputGeneration ? $0 : nil }
        guard let loaded = current ?? load(sound) else { return }
        let player = loaded.player
        if player.isPlaying {
            player.stop()
        }
        player.currentTime = 0
        // Also ends a retraction fade still in progress.
        player.setVolume(loaded.source.volume, fadeDuration: 0)
        guard player.play(), sound == .start else { return }
        let playback = SoundPlayback(
            startNanoseconds: DispatchTime.now().uptimeNanoseconds, duration: player.duration,
            reference: loaded.reference
        )
        startPlayback.withLock { $0 = playback }
    }

    private func reloadForOutputChange() {
        outputGeneration &+= 1
        // A playing sound keeps its player; the next play rebuilds it.
        for sound in Sound.allCases where players[sound]?.player.isPlaying != true {
            load(sound)
        }
    }

    @discardableResult
    private func load(_ sound: Sound) -> LoadedPlayer? {
        let previous = players[sound]
        for source in sources[sound] ?? [] {
            do {
                let player = try makePlayer(source.url)
                player.volume = source.volume
                player.prepareToPlay()
                var loaded = LoadedPlayer(player: player, source: source, outputGeneration: outputGeneration)
                // The speech gate subtracts the recorded start tone; output rebuilds reuse its decoded reference.
                if sound == .start {
                    loaded.reference = previous?.source == source
                        ? previous?.reference : try? FeedbackSoundReference.load(from: source.url)
                }
                players[sound] = loaded
                return loaded
            } catch {
                logger.error("Failed to load sound: \(error, privacy: .public)")
            }
        }
        players[sound] = nil
        return nil
    }

    private static var defaultOutputAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private func observeDefaultOutput() {
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.reloadForOutputChange()
        }
        var address = Self.defaultOutputAddress
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, queue, listener
        )
        if status == noErr {
            outputListener = listener
        } else {
            logger.error("Failed to observe the default output device: \(status, privacy: .public)")
        }
    }
}
