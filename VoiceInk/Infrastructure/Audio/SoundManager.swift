import Foundation
import SwiftUI

@MainActor
class SoundManager: ObservableObject {
    static let shared = SoundManager()

    private let playbackEngine = SoundPlaybackEngine()

    private init() {
        setupSounds()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(reloadCustomSounds),
            name: CustomSoundManager.soundsDidChange,
            object: CustomSoundManager.shared
        )
    }

    private func setupSounds() {
        let customSoundManager = CustomSoundManager.shared
        var sources: [SoundPlaybackEngine.Sound: [SoundPlaybackEngine.Source]] = [:]
        for type in CustomSoundManager.SoundType.allCases {
            var candidates: [SoundPlaybackEngine.Source] = []
            if let customURL = customSoundManager.getCustomSoundURL(for: type) {
                candidates.append(.init(url: customURL, volume: 1.0))
            }
            if let sound = customSoundManager.builtInSound(for: type), let url = sound.url {
                candidates.append(.init(url: url, volume: sound.playbackVolume))
            }
            sources[Self.engineSound(for: type)] = candidates
        }
        sources[.esc] = CustomSoundManager.BuiltInSound.sound7.url.map { [.init(url: $0, volume: 0.2)] } ?? []
        playbackEngine.setup(sources)
    }

    @objc private func reloadCustomSounds() {
        setupSounds()
    }

    private static func engineSound(for type: CustomSoundManager.SoundType) -> SoundPlaybackEngine.Sound {
        switch type {
        case .start:
            return .start
        case .stop:
            return .stop
        case .done:
            return .done
        case .error:
            return .error
        }
    }

    /// Recording starts immediately; only the tone waits, so `retractStartSound()` can silence an accidental start.
    func scheduleStartSound() {
        guard CustomSoundManager.shared.isSoundEnabled(for: .start) else { return }
        playbackEngine.scheduleStart()
    }

    func retractStartSound() {
        playbackEngine.retractStart()
    }

    /// The gate can subtract a matched playback waveform without dropping overlapping speech.
    var lastStartSoundPlayback: SoundPlayback? {
        playbackEngine.lastStartSoundPlayback
    }

    func playStopSound() {
        play(.stop)
    }

    func playDoneSound() {
        play(.done)
    }

    func playErrorSound() {
        play(.error)
    }

    func preview(_ type: CustomSoundManager.SoundType) {
        guard CustomSoundManager.shared.isSoundEnabled(for: type) else { return }
        playbackEngine.play(Self.engineSound(for: type))
    }

    func playEscSound() {
        guard CustomSoundManager.shared.hasAnyRecordingSoundEnabled else { return }
        playbackEngine.play(.esc)
    }

    private func play(_ type: CustomSoundManager.SoundType) {
        guard CustomSoundManager.shared.isSoundEnabled(for: type) else { return }
        let sound = Self.engineSound(for: type)
        let mediaController = MediaController.shared
        guard mediaController.isRestoringLoweredOutput else {
            playbackEngine.play(sound)
            return
        }
        // A lowered output would play the tone quietly; the caller's delivery does not wait.
        Task { [playbackEngine] in
            await mediaController.waitForLoweredOutputRestoration()
            playbackEngine.play(sound)
        }
    }
}
