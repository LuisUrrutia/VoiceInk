import Foundation

/// The tones that follow one recording's Stop: the stop tone, then at most one done or error tone.
struct DictationFeedback {
    enum Tone: Equatable {
        case stop
        case done
        case error
    }

    /// A paste that lands sooner already follows the stop tone closely enough to need no confirmation.
    static let doneMinimumAfterStop: TimeInterval = 2

    private(set) var stopTime: TimeInterval?
    private(set) var isFinished = false

    mutating func recordingStopped(at time: TimeInterval) -> Tone? {
        guard stopTime == nil, !isFinished else { return nil }
        stopTime = time
        return .stop
    }

    mutating func pasteFinished(_ result: CursorPaster.PasteResult, at time: TimeInterval) -> Tone? {
        guard !isFinished, result != .cancelled else { return nil }
        isFinished = true
        guard result.didPostPasteCommand else { return .error }
        guard let stopTime, time - stopTime >= Self.doneMinimumAfterStop else { return nil }
        return .done
    }

    mutating func failed() -> Tone? {
        guard !isFinished else { return nil }
        isFinished = true
        return .error
    }

    @MainActor static func playWithSoundManager(_ tone: Tone) {
        switch tone {
        case .stop:
            SoundManager.shared.playStopSound()
        case .done:
            SoundManager.shared.playDoneSound()
        case .error:
            SoundManager.shared.playErrorSound()
        }
    }
}
