import AVFoundation
import Foundation
import os

/// Transcribes a recorded meeting's two tracks on a local model and produces its turns. Chunks are cut at
/// speech regions, so the model never holds a whole meeting, and a dictation in progress is waited for
/// between chunks.
struct MeetingTranscriber {
    var transcriber: any TimedSpeechTranscribing
    var model: any TranscriptionModel
    var context: TranscriptionRequestContext
    /// Returns once no dictation is recording or processing, or after its own bound.
    var waitForDictation: () async -> Void = {}

    private static let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "MeetingTranscriber")

    func transcribe(_ manifest: MeetingManifest, store: MeetingStore) async throws -> [MeetingTranscriptEntry] {
        var entries: [MeetingTranscriptEntry] = []
        for kind in MeetingManifest.TrackKind.allCases {
            guard let track = manifest.track(kind) else { continue }
            let url = store.audioURL(for: manifest.id, track: kind)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            var samples = try Self.readSamples(from: url)
            if kind == .microphone {
                // Models without word times cannot drop dictated words afterwards, so their audio is silenced first.
                Self.silence(manifest.dictationIntervals, in: &samples, timeline: track.timeline)
            }
            var segments = try await transcribeTrack(samples)
            segments = segments.map { Self.meetingTime($0, timeline: track.timeline) }
            if kind == .microphone {
                segments = MeetingTranscript.removingDictation(from: segments, intervals: manifest.dictationIntervals)
            }
            entries += segments.map {
                MeetingTranscriptEntry(speaker: .init(kind), start: $0.start, end: $0.end, text: $0.text, words: $0.words)
            }
            Self.logger.notice("Transcribed meeting track=\(kind.rawValue, privacy: .public) segments=\(segments.count, privacy: .public)")
        }
        return MeetingTranscript.turns(entries)
    }

    /// Segments in seconds from the start of the track's file.
    func transcribeTrack(_ samples: [Float]) async throws -> [TimedTranscriptSegment] {
        let regions = try await transcriber.speechRegions(in: samples) ?? MeetingTranscript.energyRegions(in: samples)
        var segments: [TimedTranscriptSegment] = []
        for chunk in MeetingTranscript.chunks(from: regions) {
            try Task.checkCancellation()
            await waitForDictation()
            let chunkSamples = Array(samples[chunk])
            let offset = Double(chunk.lowerBound) / MeetingTrackTimeline.sampleRate
            segments += try await transcriber.transcribeTimed(samples: chunkSamples, model: model, context: context)
                .map { $0.shifted(by: offset) }
        }
        return segments
    }

    /// Zeroes the samples captured during each interval; the file itself is unchanged.
    static func silence(_ intervals: [MeetingManifest.Interval], in samples: inout [Float], timeline: MeetingTrackTimeline) {
        for interval in intervals {
            let start = min(samples.count, timeline.frame(forTime: interval.start))
            let end = min(samples.count, timeline.frame(forTime: interval.end))
            guard start < end else { continue }
            for index in start..<end { samples[index] = 0 }
        }
    }

    static func meetingTime(_ segment: TimedTranscriptSegment, timeline: MeetingTrackTimeline) -> TimedTranscriptSegment {
        TimedTranscriptSegment(
            text: segment.text, start: timeline.time(forSeconds: segment.start), end: timeline.time(forSeconds: segment.end),
            words: segment.words.map {
                TimedTranscriptWord(text: $0.text, start: timeline.time(forSeconds: $0.start), end: timeline.time(forSeconds: $0.end))
            }
        )
    }

    static func readSamples(from url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard file.processingFormat.sampleRate == MeetingTrackTimeline.sampleRate, file.length > 0,
            let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))
        else { return [] }
        try file.read(into: buffer)
        guard let channel = buffer.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }
}

/// Which installed model transcribes meetings: the current model when it is local, else a local model that
/// reports word times (they place turns and dictation exclusion precisely), else any local model.
enum MeetingTranscriptionModelChoice {
    static func choose(current: (any TranscriptionModel)?, usable: [any TranscriptionModel]) -> (any TranscriptionModel)? {
        let local = usable.filter { $0.provider == .fluidAudio || $0.provider == .whisper }
        if let current, let match = local.first(where: { $0.name == current.name && $0.provider == current.provider }) {
            return match
        }
        return local.first(where: reportsWordTimes) ?? local.first
    }

    static func reportsWordTimes(_ model: any TranscriptionModel) -> Bool {
        model.provider == .fluidAudio
            && !FluidAudioModelManager.isParakeetUnifiedModel(named: model.name)
            && !FluidAudioModelManager.isNemotronModel(named: model.name)
    }
}
