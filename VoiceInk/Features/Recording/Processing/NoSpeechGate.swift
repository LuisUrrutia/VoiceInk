import AVFoundation
import Foundation
import os

/// Reports whether 16 kHz mono audio contains speech, or nil when no detector is available.
@MainActor
protocol SpeechDetecting: AnyObject {
    func containsSpeech(in samples: [Float]) async throws -> Bool?
}

enum NoSpeechGateSettings {
    static let isEnabledKey = "DiscardRecordingsWithoutSpeech"

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: isEnabledKey)
    }
}

/// Discards live captures without speech before any model runs, because models invent
/// phrases such as "thank you" for silence. Adapted from Hex's `dictate.silence-gate`.
enum NoSpeechGate {
    static let sampleRate = 16_000.0
    /// Quiet-room noise floors sit below this level; whispered speech sits well above it.
    static let silenceThresholdDBFS: Float = -50
    static let levelWindowDuration: TimeInterval = 0.03
    /// Silero's usual 0.5 misses whispers near -43 dBFS that pass the level gate.
    static let speechProbabilityThreshold: Float = 0.4
    /// Keeps a short "Ok" while rejecting clicks, keys and room noise.
    static let minimumSpeechDuration: TimeInterval = 0.16
    /// Recording requests play their start sound immediately; later sounds, such as a Settings preview,
    /// are not this recording's start sound.
    static let startSoundRequestWindowNanoseconds: UInt64 = 1_000_000_000

    enum Decision: String, Sendable {
        case speech, detectorUnavailable, nearSilent, noSpeech

        var discardsRecording: Bool {
            self == .nearSilent || self == .noSpeech
        }
    }

    struct Evaluation: Equatable, Sendable {
        let decision: Decision
        let levelDBFS: Float
        let audioDuration: TimeInterval
        let detectorDuration: TimeInterval?
    }

    private static let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "NoSpeechGate")

    /// Evaluates a closed WAV up to release, subtracting only confidently matched feedback audio.
    /// Returns nil when the file cannot be read; callers then keep the recording.
    static func evaluate(
        audioURL: URL, startSound: SoundPlayback? = nil, startSoundOffsetFrames: Int? = nil,
        releasedFrameCount: Int? = nil,
        detector: SpeechDetecting?
    ) async -> Evaluation? {
        let audio = await Task.detached(priority: .userInitiated) {
            guard var audio = try? releasedAudio(at: audioURL, releasedFrameCount: releasedFrameCount) else {
                return nil as (samples: [Float], sampleRate: Double)?
            }
            if audio.sampleRate == sampleRate, let reference = startSound?.reference, let startSoundOffsetFrames {
                let matched = reference.suppress(in: &audio.samples, expectedOffsetFrames: startSoundOffsetFrames)
                logger.debug("No-speech gate start_sound_matched=\(matched, privacy: .public)")
            }
            return audio
        }.value
        guard let audio else {
            logger.notice("No-speech gate skipped: the recording could not be read")
            return nil
        }
        return await evaluate(samples: audio.samples, sampleRate: audio.sampleRate, detector: detector)
    }

    /// Evaluates audio that already ends at the release.
    static func evaluate(samples: [Float], sampleRate: Double, detector: SpeechDetecting?) async -> Evaluation {
        let windowSize = max(1, Int((sampleRate * levelWindowDuration).rounded()))
        let level = loudestWindowLevel(in: samples, windowSize: windowSize)
        let audioDuration = sampleRate > 0 ? Double(samples.count) / sampleRate : 0
        guard level >= silenceThresholdDBFS else {
            let evaluation = Evaluation(
                decision: .nearSilent, levelDBFS: level, audioDuration: audioDuration, detectorDuration: nil
            )
            log(evaluation)
            return evaluation
        }

        // The detector requires 16 kHz audio; any other rate keeps the full-audio fallback.
        guard let detector, sampleRate == Self.sampleRate else {
            let evaluation = Evaluation(
                decision: .detectorUnavailable, levelDBFS: level, audioDuration: audioDuration, detectorDuration: nil
            )
            log(evaluation)
            return evaluation
        }
        let start = DispatchTime.now().uptimeNanoseconds
        let decision: Decision
        do {
            switch try await detector.containsSpeech(in: samples) {
            case true?: decision = .speech
            case false?: decision = .noSpeech
            case nil: decision = .detectorUnavailable
            }
        } catch {
            logger.notice("No-speech gate detector failed; keeping the recording: \(error, privacy: .public)")
            decision = .detectorUnavailable
        }
        let detectorDuration = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
        let evaluation = Evaluation(
            decision: decision, levelDBFS: level, audioDuration: audioDuration, detectorDuration: detectorDuration
        )
        log(evaluation)
        return evaluation
    }

    static func startSoundOffsetFrames(
        playback: SoundPlayback?, requestNanoseconds: UInt64, firstAudioNanoseconds: UInt64?,
        sampleRate: Double = sampleRate
    ) -> Int? {
        guard let playback, let firstAudioNanoseconds, playback.startNanoseconds >= requestNanoseconds,
            playback.startNanoseconds - requestNanoseconds <= startSoundRequestWindowNanoseconds
        else { return nil }
        let delta = playback.startNanoseconds >= firstAudioNanoseconds
            ? Double(playback.startNanoseconds - firstAudioNanoseconds)
            : -Double(firstAudioNanoseconds - playback.startNanoseconds)
        return Int((delta * sampleRate / 1_000_000_000).rounded())
    }

    /// The loudest window's DC-removed RMS level in dBFS, floored at -120 dBFS.
    nonisolated static func loudestWindowLevel(in samples: [Float], windowSize: Int) -> Float {
        var loudest = 0.0
        var start = samples.startIndex
        while start < samples.endIndex {
            let end = min(start + windowSize, samples.endIndex)
            let count = Double(end - start)
            var sum = 0.0
            for index in start..<end { sum += Double(samples[index]) }
            let mean = sum / count
            var variance = 0.0
            for index in start..<end {
                let deviation = Double(samples[index]) - mean
                variance += deviation * deviation
            }
            loudest = max(loudest, (variance / count).squareRoot())
            start = end
        }
        return Float(20 * log10(max(loudest, 1e-6)))
    }

    private nonisolated static func releasedAudio(
        at url: URL, releasedFrameCount: Int?
    ) throws -> (samples: [Float], sampleRate: Double) {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let released = releasedFrameCount.map { min(Int64(max(0, $0)), file.length) } ?? file.length
        let frameCount = AVAudioFrameCount(clamping: released)
        let sampleRate = file.processingFormat.sampleRate
        guard frameCount > 0 else { return ([], sampleRate) }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frameCount) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        try file.read(into: buffer, frameCount: frameCount)
        guard let channel = buffer.floatChannelData?[0] else { throw CocoaError(.fileReadCorruptFile) }
        return (Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength))), sampleRate)
    }

    private static func log(_ evaluation: Evaluation) {
        let level = evaluation.levelDBFS
        let audioMilliseconds = Int((evaluation.audioDuration * 1_000).rounded())
        let detectorMilliseconds = evaluation.detectorDuration.map { String(Int(($0 * 1_000).rounded())) } ?? "none"
        let message = "decision=\(evaluation.decision.rawValue) level_dbfs=\(String(format: "%.1f", level)) threshold_dbfs=\(String(format: "%.1f", silenceThresholdDBFS)) audio_ms=\(audioMilliseconds) vad_ms=\(detectorMilliseconds)"
        if evaluation.decision.discardsRecording {
            logger.notice("Discarded recording without speech: \(message, privacy: .public)")
        } else {
            logger.debug("Kept recording: \(message, privacy: .public)")
        }
    }
}
