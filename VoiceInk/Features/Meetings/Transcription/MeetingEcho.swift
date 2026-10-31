import Foundation

/// Speaker echo detection, ported from Hex's `meeting_echo.rs` and `suppress_echo` (MIT,
/// https://github.com/anomalyco/hex/blob/37c5dcdf81e3438ed4dad0396bd704c6b59d6eeb/src/meeting_echo.rs). When a call
/// plays through speakers, the microphone hears remote audio tens of milliseconds after the system track carries
/// it. Per-20 ms frame energies of both tracks on the meeting timeline classify a microphone span as bleed
/// (explained by delayed, attenuated system audio) or as local speech, which survives double-talk because it is
/// louder than the predicted bleed. This is not acoustic echo cancellation; the audio is unchanged.
final class MeetingEchoEnvelope {
    enum Signal: Equatable {
        /// Delayed system audio explains the microphone sound.
        case bleed
        /// The microphone carries sound the system audio does not explain.
        case local
    }

    struct Locality: Equatable {
        /// Share of the span's sound frames that are local.
        var share: Float
        /// Most local frames within any one-second window.
        var burst: Int
    }

    static let frameMilliseconds = 20
    static let silentDecibels: Float = -100
    /// Lag search, in frames, of the microphone behind the system track.
    static let lagRange = -15...30
    static let contextMilliseconds = 5_000
    static let couplingContextMilliseconds = 60_000
    static let couplingBlockFrames = 500
    /// Remote speech in the system track; digital silence is far below this.
    static let systemActiveDecibels: Float = -55
    static let minimumSystemFrames = 25
    static let activeAboveFloorDecibels: Float = 6
    static let gainPercentile: Float = 0.35
    /// Frames this far above the predicted bleed are local speech.
    static let localMarginDecibels: Float = 9
    static let reverbFrames = 8
    static let reverbDecayDecibels: Float = 1.5
    /// Below this envelope correlation the microphone does not hear the call.
    static let minimumCorrelation: Float = 0.2
    static let minimumActiveFrames = 10
    static let minimumGainFrames = 10
    static let bleedMaximumLocal: Float = 0.2
    static let localMinimumLocal: Float = 0.5
    /// Half a second of local frames within one second is someone speaking in the room.
    static let burstWindowFrames = 50
    static let burstMinimumFrames = 25

    private let system: [Float]
    private let microphone: [Float]
    private var couplings: [Int: (correlation: Float, lag: Int)?] = [:]

    /// Frame levels in dB on the meeting timeline; frame `i` starts at `i * 20` ms.
    init(system: [Float], microphone: [Float]) {
        self.system = system
        self.microphone = microphone
    }

    /// Places a track's 20 ms frame levels on the meeting timeline; frames no audio covers stay silent.
    static func frames(of samples: [Float], timeline: MeetingTrackTimeline) -> [Float] {
        let length = Int(MeetingTrackTimeline.sampleRate) * frameMilliseconds / 1_000
        var frames: [Float] = []
        var start = 0
        while start + length <= samples.count {
            var energy: Double = 0
            for index in start..<(start + length) { energy += Double(samples[index]) * Double(samples[index]) }
            // Rounded to a whole meeting sample before binning, so exact 20 ms boundaries never fall into the bin before.
            let meetingSample = Int((timeline.time(forFrame: start) * MeetingTrackTimeline.sampleRate).rounded())
            let index = meetingSample / length
            if frames.count <= index { frames += [Float](repeating: silentDecibels, count: index + 1 - frames.count) }
            frames[index] = Float(10 * log10(energy / Double(length) + 1e-10))
            start += length
        }
        return frames
    }

    /// Classifies the microphone between `start` and `end` milliseconds, or nil when there is too little sound or
    /// remote audio to tell.
    func assess(startMilliseconds start: Int, endMilliseconds end: Int) -> Signal? {
        guard let locality = locality(startMilliseconds: start, endMilliseconds: end) else { return nil }
        if locality.share >= Self.localMinimumLocal { return .local }
        if locality.share <= Self.bleedMaximumLocal && locality.burst < Self.burstMinimumFrames { return .bleed }
        return nil
    }

    func locality(startMilliseconds start: Int, endMilliseconds end: Int) -> Locality? {
        let first = start / Self.frameMilliseconds
        let last = max(end / Self.frameMilliseconds, first + 1)
        func around(_ margin: Int) -> Range<Int> {
            let lower = max(0, start - margin) / Self.frameMilliseconds
            let upper = max(min((end + margin) / Self.frameMilliseconds, microphone.count), last)
            return lower..<upper
        }
        let context = around(Self.contextMilliseconds)
        let best = coupling(first: first, last: last)

        var floorValues = context.map(microphoneLevel)
        guard let floor = Self.percentile(&floorValues, 0.1) else { return nil }
        let active = (first..<last).filter { microphoneLevel($0) >= floor + Self.activeAboveFloorDecibels }
        // Without remote audio nearby, or when the microphone does not hear it, nothing explains the sound.
        guard let lag = best.flatMap({ $0.correlation >= Self.minimumCorrelation ? $0.lag : nil }) else {
            return active.count >= Self.minimumActiveFrames
                ? Locality(share: 1, burst: min(active.count, Self.burstWindowFrames)) : nil
        }

        func remote(at frame: Int) -> Float {
            let source = frame - lag
            var level = Self.silentDecibels
            for reverb in 0...Self.reverbFrames {
                level = max(level, systemLevel(source - reverb) - Float(reverb) * Self.reverbDecayDecibels)
            }
            return max(level, systemLevel(source + 1) - Self.reverbDecayDecibels)
        }
        func spanGain(_ span: Range<Int>, minimumFrames: Int) -> Float? {
            var loud = span.map { systemLevel($0 - lag) }.filter { $0 > Self.systemActiveDecibels }
            guard loud.count >= minimumFrames, let threshold = Self.percentile(&loud, 0.5) else { return nil }
            var differences = span.filter { systemLevel($0 - lag) >= threshold }.map { microphoneLevel($0) - remote(at: $0) }
            // A low percentile, so the user's own speech over loud remote frames does not inflate the estimate.
            return Self.percentile(&differences, Self.gainPercentile)
        }
        // Estimating before and after the span keeps a mute or volume change on one side from skewing it.
        let sides = [
            spanGain(context.lowerBound..<max(context.lowerBound, first), minimumFrames: Self.minimumGainFrames),
            spanGain(min(last, context.upperBound)..<context.upperBound, minimumFrames: Self.minimumGainFrames),
        ].compactMap { $0 }
        guard let gain = sides.max() ?? spanGain(context, minimumFrames: 1) else { return nil }

        let local = active.filter { microphoneLevel($0) > max(gain + remote(at: $0), floor) + Self.localMarginDecibels }
        if active.count < Self.minimumActiveFrames {
            let remoteFrames = (first..<last).filter { remote(at: $0) > Self.systemActiveDecibels }.count
            return local.isEmpty && remoteFrames * 2 >= last - first ? Locality(share: 0, burst: 0) : nil
        }
        var burst = 0
        var from = 0
        for (to, frame) in local.enumerated() {
            while local[from] <= frame - Self.burstWindowFrames { from += 1 }
            burst = max(burst, to + 1 - from)
        }
        return Locality(share: Float(local.count) / Float(active.count), burst: burst)
    }

    /// The best envelope correlation and lag of the microphone behind the system track around `first..<last`.
    private func coupling(first: Int, last: Int) -> (correlation: Float, lag: Int)? {
        let block = (first + last) / 2 / Self.couplingBlockFrames
        if let cached = couplings[block] { return cached }
        let center = block * Self.couplingBlockFrames + Self.couplingBlockFrames / 2
        let reach = Self.couplingContextMilliseconds / Self.frameMilliseconds
        let frames = max(0, center - reach)..<max(max(0, center - reach), min(center + reach, microphone.count))
        var best: (correlation: Float, lag: Int)?
        for lag in Self.lagRange {
            let pairs = frames.map { (microphoneLevel($0), systemLevel($0 - lag)) }.filter { $0.1 > Self.systemActiveDecibels }
            guard pairs.count >= Self.minimumSystemFrames else { continue }
            let correlation = Self.pearson(pairs)
            if best.map({ correlation > $0.correlation }) ?? true { best = (correlation, lag) }
        }
        // The whole recording is known, so every estimate is final.
        couplings[block] = best
        return best
    }

    private func microphoneLevel(_ frame: Int) -> Float {
        frame >= 0 && frame < microphone.count ? microphone[frame] : Self.silentDecibels
    }

    private func systemLevel(_ frame: Int) -> Float {
        frame >= 0 && frame < system.count ? system[frame] : Self.silentDecibels
    }

    static func pearson(_ pairs: [(Float, Float)]) -> Float {
        let count = Float(pairs.count)
        let meanX = pairs.reduce(0) { $0 + $1.0 / count }
        let meanY = pairs.reduce(0) { $0 + $1.1 / count }
        var covariance: Float = 0
        var varianceX: Float = 0
        var varianceY: Float = 0
        for (x, y) in pairs {
            covariance += (x - meanX) * (y - meanY)
            varianceX += (x - meanX) * (x - meanX)
            varianceY += (y - meanY) * (y - meanY)
        }
        let denominator = (varianceX * varianceY).squareRoot()
        return denominator <= .ulpOfOne ? 0 : covariance / denominator
    }

    static func percentile(_ values: inout [Float], _ fraction: Float) -> Float? {
        guard !values.isEmpty else { return nil }
        values.sort()
        return values[Int((Float(values.count - 1) * fraction).rounded())]
    }
}

/// Drops microphone entries that echo remote speech, as Hex's `suppress_echo` does.
enum MeetingEchoSuppression {
    /// Remote speech this close to a microphone utterance can be its echo.
    static let echoWindowMilliseconds = 1_500
    /// Microphone entries closer than this are judged together.
    static let utteranceGapMilliseconds = 700
    /// Entries with at least this many words are also judged on their own.
    static let sentenceWords = 3
    static let echoSimilarity: Float = 0.6

    /// An utterance is echo when the signal says delayed system audio explains it, or when its words repeat
    /// overlapping remote speech unless the signal shows local speech (double-talk). Returns the kept entries and
    /// the number of dropped utterances.
    static func suppress(
        _ entries: [MeetingTranscriptEntry], signal: (Int, Int) -> MeetingEchoEnvelope.Signal?
    ) -> (entries: [MeetingTranscriptEntry], dropped: Int) {
        let system = entries.filter { $0.speaker == .them }
        let microphone = entries.indices.filter { entries[$0].speaker == .you }.sorted {
            milliseconds(entries[$0].start) < milliseconds(entries[$1].start)
        }
        var utterances: [[Int]] = []
        for index in microphone {
            if let last = utterances.last?.last,
                milliseconds(entries[index].start) - milliseconds(entries[last].end) <= utteranceGapMilliseconds
            {
                utterances[utterances.count - 1].append(index)
            } else {
                utterances.append([index])
            }
        }
        func isEcho(_ spoken: [String], _ start: Int, _ end: Int, judgeWords: Bool) -> Bool {
            switch signal(start, end) {
            case .bleed: true
            case .local: false
            case nil: judgeWords && echoScore(spoken, start: start, end: end, remote: system) >= echoSimilarity
            }
        }
        var dropped = Set<Int>()
        var droppedUtterances = 0
        for utterance in utterances {
            let spoken = utterance.flatMap { tokens(entries[$0].text) }
            let start = milliseconds(entries[utterance[0]].start)
            let end = utterance.map { milliseconds(entries[$0].end) }.max() ?? start
            if isEcho(spoken, start, end, judgeWords: true) {
                droppedUtterances += 1
                // Bleed can run into the user's own sentence; a sentence the signal shows is local survives.
                for index in utterance {
                    let entry = entries[index]
                    if tokens(entry.text).count < sentenceWords
                        || signal(milliseconds(entry.start), milliseconds(entry.end)) != .local
                    {
                        dropped.insert(index)
                    }
                }
                continue
            }
            guard utterance.count > 1 else { continue }
            for index in utterance {
                let entry = entries[index]
                let words = tokens(entry.text)
                if isEcho(words, milliseconds(entry.start), milliseconds(entry.end), judgeWords: words.count >= sentenceWords) {
                    droppedUtterances += 1
                    dropped.insert(index)
                }
            }
        }
        let kept = entries.indices.filter { !dropped.contains($0) }.map { entries[$0] }
        return (kept, droppedUtterances)
    }

    static func milliseconds(_ seconds: TimeInterval) -> Int { Int((seconds * 1_000).rounded()) }

    /// The share of `spoken` that remote speech within the echo window contains.
    static func echoScore(_ spoken: [String], start: Int, end: Int, remote: [MeetingTranscriptEntry]) -> Float {
        let lower = start - echoWindowMilliseconds
        let upper = end + echoWindowMilliseconds
        let remoteTokens = remote.filter { milliseconds($0.start) < upper && lower < milliseconds($0.end) }
            .flatMap { tokens($0.text) }
        guard !remoteTokens.isEmpty, !spoken.isEmpty else { return 0 }
        let matched = spoken.filter { token in remoteTokens.contains { tokensMatch(token, $0) } }.count
        return Float(matched) / Float(spoken.count)
    }

    static func tokens(_ text: String) -> [String] {
        text.split { !$0.isLetter && !$0.isNumber }.map { $0.lowercased() }
    }

    static func tokensMatch(_ left: String, _ right: String) -> Bool {
        if left == right { return true }
        let left = Array(left)
        let right = Array(right)
        guard left.count >= 3, right.count >= 3 else { return false }
        return 1 - Float(editDistance(left, right)) / Float(max(left.count, right.count)) >= echoSimilarity
    }

    static func editDistance(_ left: [Character], _ right: [Character]) -> Int {
        var previous = Array(0...right.count)
        var current = [Int](repeating: 0, count: right.count + 1)
        for (row, leftCharacter) in left.enumerated() {
            current[0] = row + 1
            for (column, rightCharacter) in right.enumerated() {
                current[column + 1] = min(
                    previous[column] + (leftCharacter == rightCharacter ? 0 : 1), previous[column + 1] + 1, current[column] + 1
                )
            }
            swap(&previous, &current)
        }
        return previous[right.count]
    }
}
