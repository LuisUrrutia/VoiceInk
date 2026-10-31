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
            name: NSNotification.Name("CustomSoundsChanged"),
            object: nil
        )
    }

    private func setupSounds() {
        let customSoundManager = CustomSoundManager.shared
        playbackEngine.setup(
            defaultStartURL: customSoundManager.builtInSoundURL(for: .start),
            defaultStopURL: customSoundManager.builtInSoundURL(for: .stop),
            defaultEscURL: CustomSoundManager.BuiltInSound.sound7.bundleURL,
            customStartURL: customSoundManager.getCustomSoundURL(for: .start),
            customStopURL: customSoundManager.getCustomSoundURL(for: .stop)
        )
    }

    @objc private func reloadCustomSounds() {
        setupSounds()
    }

    func playStartSound() {
        guard CustomSoundManager.shared.isSoundEnabled(for: .start) else { return }
        playbackEngine.playStartSound()
    }

    /// The gate can subtract a matched playback waveform without dropping overlapping speech.
    var lastStartSoundPlayback: SoundPlayback? {
        playbackEngine.lastStartSoundPlayback
    }

    func playStopSound() {
        guard CustomSoundManager.shared.isSoundEnabled(for: .stop) else { return }
        let mediaController = MediaController.shared
        guard mediaController.isRestoringLoweredOutput else {
            playbackEngine.playStopSound()
            return
        }
        // A lowered output would play the tone quietly; the caller's delivery does not wait.
        Task { [playbackEngine] in
            await mediaController.waitForLoweredOutputRestoration()
            playbackEngine.playStopSound()
        }
    }

    func playEscSound() {
        guard CustomSoundManager.shared.hasAnyRecordingSoundEnabled else { return }
        playbackEngine.playEscSound()
    }
}
