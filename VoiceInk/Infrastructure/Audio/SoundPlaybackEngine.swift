@preconcurrency import AVFoundation
import Foundation
import os

/// When a sound began playing on the monotonic uptime clock, and how long it lasts.
struct SoundPlayback: Equatable, Sendable {
    let startNanoseconds: UInt64
    let duration: TimeInterval
    var reference: FeedbackSoundReference? = nil
}

final class SoundPlaybackEngine: @unchecked Sendable {
    private enum Sound {
        case start
        case stop
        case esc
    }

    private let queue = DispatchQueue(label: "com.prakashjoshipax.voiceink.soundPlayback", qos: .userInitiated)
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "SoundPlaybackEngine")

    private var startSound: AVAudioPlayer?
    private var stopSound: AVAudioPlayer?
    private var escSound: AVAudioPlayer?
    private var customStartSound: AVAudioPlayer?
    private var customStopSound: AVAudioPlayer?
    private var startReference: FeedbackSoundReference?
    private var customStartReference: FeedbackSoundReference?
    private let startPlayback = OSAllocatedUnfairLock<SoundPlayback?>(initialState: nil)

    var lastStartSoundPlayback: SoundPlayback? {
        startPlayback.withLock { $0 }
    }

    func setup(
        defaultStartURL: URL?,
        defaultStopURL: URL?,
        defaultEscURL: URL?,
        customStartURL: URL?,
        customStopURL: URL?
    ) {
        queue.async { [weak self] in
            guard let self else { return }

            self.startSound = self.makePlayer(from: defaultStartURL, volume: 0.3)
            self.startReference = defaultStartURL.flatMap { try? FeedbackSoundReference.load(from: $0) }
            self.stopSound = self.makePlayer(from: defaultStopURL, volume: 0.3)
            self.escSound = self.makePlayer(from: defaultEscURL, volume: 0.2)
            self.reloadCustomSoundsOnQueue(startURL: customStartURL, stopURL: customStopURL)
        }
    }

    func reloadCustomSounds(startURL: URL?, stopURL: URL?) {
        queue.async { [weak self] in
            self?.reloadCustomSoundsOnQueue(startURL: startURL, stopURL: stopURL)
        }
    }

    func playStartSound() {
        play(.start)
    }

    func playStopSound() {
        play(.stop)
    }

    func playEscSound() {
        play(.esc)
    }

    private func reloadCustomSoundsOnQueue(startURL: URL?, stopURL: URL?) {
        if customStartSound?.isPlaying == true {
            customStartSound?.stop()
        }
        if customStopSound?.isPlaying == true {
            customStopSound?.stop()
        }

        customStartSound = makePlayer(from: startURL, volume: 1.0)
        customStartReference = startURL.flatMap { try? FeedbackSoundReference.load(from: $0) }
        customStopSound = makePlayer(from: stopURL, volume: 1.0)
    }

    private func play(_ sound: Sound) {
        queue.async { [weak self] in
            guard let self else { return }

            let player: AVAudioPlayer?
            switch sound {
            case .start:
                player = self.customStartSound ?? self.startSound
            case .stop:
                player = self.customStopSound ?? self.stopSound
            case .esc:
                player = self.escSound
            }

            guard let player, player.play(), sound == .start else { return }
            let playback = SoundPlayback(
                startNanoseconds: DispatchTime.now().uptimeNanoseconds, duration: player.duration,
                reference: self.customStartSound == nil ? self.startReference : self.customStartReference
            )
            self.startPlayback.withLock { $0 = playback }
        }
    }

    private func makePlayer(from url: URL?, volume: Float) -> AVAudioPlayer? {
        guard let url else { return nil }

        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.volume = volume
            player.prepareToPlay()
            return player
        } catch {
            logger.error("Failed to load sound: \(error, privacy: .public)")
            return nil
        }
    }
}
