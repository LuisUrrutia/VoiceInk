import AVFoundation
import XCTest

@testable import VoiceInk

/// Ports Hex's synthetic echo cases (MIT, `src/meeting_echo.rs` and `src/meeting_transcript.rs` tests).
final class MeetingEchoTests: XCTestCase {
    private let rate = 16_000

    // MARK: - Signal

    func testSpeakerBleedIsClassifiedAsBleed() {
        let system = speech(seconds: 12, seed: 11)
        let envelope = makeEnvelope(system: system, microphone: bleed(system, delayMilliseconds: 60, gain: 0.08))

        XCTAssertEqual(envelope.assess(startMilliseconds: 2_000, endMilliseconds: 5_000), .bleed)
        XCTAssertEqual(envelope.assess(startMilliseconds: 6_000, endMilliseconds: 9_500), .bleed)
    }

    func testTalkingOverTheRemoteSideIsLocal() {
        let system = speech(seconds: 12, seed: 11)
        var microphone = bleed(system, delayMilliseconds: 60, gain: 0.08)
        add(speech(seconds: 3, seed: 29), gain: 0.9, at: 5, to: &microphone)
        let envelope = makeEnvelope(system: system, microphone: microphone)

        XCTAssertEqual(envelope.assess(startMilliseconds: 5_000, endMilliseconds: 8_000), .local)
        XCTAssertEqual(envelope.assess(startMilliseconds: 1_000, endMilliseconds: 4_500), .bleed)
    }

    func testSpeechDuringRemoteSilenceIsLocal() {
        var system = speech(seconds: 12, seed: 11)
        for index in (6 * rate)..<system.count { system[index] = 0 }
        var microphone = bleed(system, delayMilliseconds: 60, gain: 0.08)
        add(speech(seconds: 4, seed: 5), gain: 0.5, at: 7, to: &microphone)

        XCTAssertEqual(makeEnvelope(system: system, microphone: microphone).assess(startMilliseconds: 7_200, endMilliseconds: 10_800), .local)
    }

    func testLateMuffledBleedIsBleedAndSpeechOverItIsLocal() {
        let system = speech(seconds: 14, seed: 11)
        var microphone = room(system, delayMilliseconds: 450, gain: 0.25)
        XCTAssertEqual(makeEnvelope(system: system, microphone: microphone).assess(startMilliseconds: 2_000, endMilliseconds: 5_000), .bleed)

        add(speech(seconds: 3, seed: 29), gain: 0.9, at: 7, to: &microphone)
        let envelope = makeEnvelope(system: system, microphone: microphone)

        XCTAssertEqual(envelope.assess(startMilliseconds: 7_000, endMilliseconds: 10_000), .local)
        XCTAssertEqual(envelope.assess(startMilliseconds: 2_000, endMilliseconds: 5_000), .bleed)
    }

    func testAShortPhraseInsideALongBleedSegmentIsNotBleed() throws {
        let system = speech(seconds: 16, seed: 11)
        var microphone = bleed(system, delayMilliseconds: 60, gain: 0.08)
        add(speech(seconds: 1.2, seed: 29), gain: 0.9, at: 8, to: &microphone)
        let envelope = makeEnvelope(system: system, microphone: microphone)

        let locality = try XCTUnwrap(envelope.locality(startMilliseconds: 1_000, endMilliseconds: 15_000))
        XCTAssertLessThan(locality.share, MeetingEchoEnvelope.bleedMaximumLocal)
        XCTAssertGreaterThanOrEqual(locality.burst, MeetingEchoEnvelope.burstMinimumFrames)
        XCTAssertNil(envelope.assess(startMilliseconds: 1_000, endMilliseconds: 15_000))
        XCTAssertEqual(envelope.assess(startMilliseconds: 1_000, endMilliseconds: 7_500), .bleed)
    }

    func testHeadphonesMakeEveryMicrophoneSoundLocal() {
        let system = speech(seconds: 12, seed: 11)
        var microphone = roomNoise(count: system.count, seed: 3)
        add(speech(seconds: 3, seed: 17), gain: 0.4, at: 4, to: &microphone)
        let envelope = makeEnvelope(system: system, microphone: microphone)

        XCTAssertEqual(envelope.assess(startMilliseconds: 4_000, endMilliseconds: 7_000), .local)
        XCTAssertNil(envelope.assess(startMilliseconds: 9_000, endMilliseconds: 11_000), "silence is undecided")
    }

    func testTrackGapsArePlacedOnTheMeetingTimeline() {
        var timeline = MeetingTrackTimeline()
        timeline.record(frame: 0, at: 0)
        timeline.record(frame: 320, at: 1)

        let frames = MeetingEchoEnvelope.frames(of: [Float](repeating: 0.1, count: 640), timeline: timeline)

        XCTAssertEqual(frames.count, 51)
        XCTAssertGreaterThan(frames[0], -30)
        XCTAssertGreaterThan(frames[50], -30)
        XCTAssertEqual(frames[25], MeetingEchoEnvelope.silentDecibels)
    }

    func testContinuousAudioFillsEveryFrameWithoutFalseSilence() {
        var timeline = MeetingTrackTimeline()
        timeline.record(frame: 0, at: 0)

        let frames = MeetingEchoEnvelope.frames(of: [Float](repeating: 0.1, count: 60 * rate), timeline: timeline)

        XCTAssertEqual(frames.count, 3_000)
        XCTAssertFalse(frames.contains(MeetingEchoEnvelope.silentDecibels))
    }

    // MARK: - Words

    func testFuzzyTokensMatchOnlyWhenSimilarEnoughAndLongEnough() {
        XCTAssertTrue(MeetingEchoSuppression.tokensMatch("support", "suport"))
        XCTAssertTrue(MeetingEchoSuppression.tokensMatch("aisdk", "aick"))
        XCTAssertFalse(MeetingEchoSuppression.tokensMatch("beta", "better"))
        XCTAssertFalse(MeetingEchoSuppression.tokensMatch("ai", "aj"))
        XCTAssertTrue(MeetingEchoSuppression.tokensMatch("ai", "ai"))
    }

    func testMisheardEchoIsDroppedOnlyBecauseOfFuzzyMatching() {
        let entries = [
            entry(.them, 2_000, 4_000, "Configuration deployment tomorrow"),
            entry(.you, 2_100, 4_100, "Configurations deploymant tomorow"),
        ]

        let result = MeetingEchoSuppression.suppress(entries) { _, _ in nil }

        XCTAssertEqual(result.dropped, 1)
        XCTAssertEqual(result.entries.map(\.speaker), [.them])
    }

    func testWordMatchingOnlyConsidersRemoteSpeechWithinOneAndAHalfSeconds() {
        let entries = [
            entry(.them, 1_000, 2_000, "Ship the beta on Friday"),
            // Starts 1.4 s after the remote line ends: an echo window match.
            entry(.you, 3_400, 4_400, "Ship the beta on Friday"),
            // Repeats the same words 20 s later: the user quoting them, not echo.
            entry(.you, 22_000, 23_000, "Ship the beta on Friday"),
        ]

        let result = MeetingEchoSuppression.suppress(entries) { _, _ in nil }

        XCTAssertEqual(result.dropped, 1)
        XCTAssertEqual(result.entries.map { Int($0.start * 1_000) }, [1_000, 22_000])
    }

    func testManifestsWithoutAnEchoCountStillLoad() throws {
        let manifest = MeetingManifest(title: "Old")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder.meetingManifest.encode(manifest)) as? [String: Any])
        object.removeValue(forKey: "echoSuppressedUtterances")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let decoded = try decoder.decode(MeetingManifest.self, from: JSONSerialization.data(withJSONObject: object))

        XCTAssertNil(decoded.echoSuppressedUtterances)
        XCTAssertEqual(decoded.id, manifest.id)
    }

    func testSpeakerEchoOfRemoteSpeechIsDropped() {
        let entries = [
            entry(.them, 10_000, 12_400, "Does it have AISDK support?"),
            entry(.you, 10_300, 12_900, "Does it have AICK support?"),
            entry(.you, 13_100, 15_000, "Yes, since version two."),
        ]

        let result = MeetingEchoSuppression.suppress(entries) { _, _ in nil }

        XCTAssertEqual(result.dropped, 1)
        XCTAssertEqual(result.entries.map(\.text), ["Does it have AISDK support?", "Yes, since version two."])
    }

    func testWordLevelEchoIsDroppedAsOneUtterance() {
        var entries = [entry(.them, 5_000, 7_000, "AICK support is coming next week")]
        for (index, word) in ["AISDK", "support", "is", "coming", "next", "week"].enumerated() {
            let start = 5_200 + index * 300
            entries.append(entry(.you, start, start + 250, word))
        }

        let result = MeetingEchoSuppression.suppress(entries) { _, _ in nil }

        XCTAssertEqual(result.dropped, 1)
        XCTAssertEqual(result.entries.count, 1)
    }

    func testTheSignalOverridesWordMatchingBothWays() {
        let entries = [
            entry(.them, 1_000, 3_000, "We could make twenty games."),
            entry(.you, 1_100, 3_000, "We can make plenty."),
            entry(.them, 10_000, 11_000, "Yeah, totally."),
            entry(.you, 10_050, 11_000, "Yeah, totally."),
        ]

        let result = MeetingEchoSuppression.suppress(entries) { start, _ in start < 5_000 ? .bleed : .local }

        XCTAssertEqual(result.dropped, 1)
        XCTAssertEqual(result.entries.map { "\($0.speaker.rawValue)@\(Int($0.start * 1_000))" }, ["them@1000", "them@10000", "you@10050"])
    }

    func testSyntheticSpeakerBleedIsDroppedAndDoubleTalkKept() {
        let system = speech(seconds: 12, seed: 11)
        var microphone = bleed(system, delayMilliseconds: 80, gain: 0.1)
        add(speech(seconds: 3, seed: 29), gain: 0.9, at: 7, to: &microphone)
        let envelope = makeEnvelope(system: system, microphone: microphone)
        let entries = [
            entry(.them, 1_000, 4_000, "Ship the beta on Friday."),
            entry(.you, 1_100, 4_000, "Shipped a better Friday."),
            entry(.them, 7_000, 10_000, "Then we tell everyone."),
            entry(.you, 7_000, 10_000, "Wait, which beta?"),
        ]

        let result = MeetingEchoSuppression.suppress(entries) { envelope.assess(startMilliseconds: $0, endMilliseconds: $1) }

        XCTAssertEqual(result.dropped, 1)
        XCTAssertTrue(result.entries.contains { $0.text == "Wait, which beta?" })
        XCTAssertFalse(result.entries.contains { $0.text == "Shipped a better Friday." })
    }

    func testALocalSentenceInsideAnEchoUtteranceIsKept() {
        let entries = [
            entry(.them, 1_000, 9_000, "That's why I'm gonna get the plugin registry out. I wake up."),
            entry(.you, 1_100, 4_000, "That's why I'm gonna get the plugin registry out."),
            entry(.you, 4_300, 6_500, "Also, can you add some knobs?"),
            entry(.you, 6_800, 9_000, "Yeah, I wake up."),
        ]

        let result = MeetingEchoSuppression.suppress(entries) { start, end in
            (start, end) == (4_300, 6_500) ? .local : .bleed
        }

        XCTAssertEqual(result.dropped, 1)
        XCTAssertEqual(result.entries.filter { $0.speaker == .you }.map(\.text), ["Also, can you add some knobs?"])
    }

    // MARK: - Transcriber

    func testAMeetingWithSpeakerBleedKeepsOnlyThemAndCountsTheEcho() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MeetingEchoTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(rootURL: root, movesToTrash: false)
        var manifest = MeetingManifest(title: "Echo")
        _ = try store.createDirectory(for: manifest.id)
        let system = speech(seconds: 12, seed: 11)
        try write(system, to: store.audioURL(for: manifest.id, track: .system))
        try write(bleed(system, delayMilliseconds: 60, gain: 0.08), to: store.audioURL(for: manifest.id, track: .microphone))
        for kind in MeetingManifest.TrackKind.allCases { manifest.updateTrack(kind) { $0.timeline.record(frame: 0, at: 0) } }
        let model = try XCTUnwrap(TranscriptionModelRegistry.models.first { $0.name == "parakeet-tdt-0.6b-v3" })

        let result = try await MeetingTranscriber(
            transcriber: SameWordsTranscriber(), model: model, context: TranscriptionRequestContext(languages: ["en"])
        ).transcribe(manifest, store: store)

        XCTAssertFalse(result.turns.isEmpty)
        XCTAssertTrue(result.turns.allSatisfy { $0.speaker == .them })
        XCTAssertGreaterThanOrEqual(result.echoSuppressedUtterances, 1)
    }

    func testSilencedDictationsDoNotHideSpeakerBleedElsewhere() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MeetingEchoTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(rootURL: root, movesToTrash: false)
        var manifest = MeetingManifest(title: "Echo")
        _ = try store.createDirectory(for: manifest.id)
        let system = speech(seconds: 60, seed: 11)
        try write(system, to: store.audioURL(for: manifest.id, track: .system))
        try write(bleed(system, delayMilliseconds: 60, gain: 0.08), to: store.audioURL(for: manifest.id, track: .microphone))
        for kind in MeetingManifest.TrackKind.allCases { manifest.updateTrack(kind) { $0.timeline.record(frame: 0, at: 0) } }
        manifest.dictationIntervals = [.init(start: 0, end: 10), .init(start: 20, end: 30), .init(start: 40, end: 50)]
        let model = try XCTUnwrap(TranscriptionModelRegistry.models.first { $0.name == "parakeet-tdt-0.6b-v3" })

        let result = try await MeetingTranscriber(
            transcriber: SameWordsTranscriber(), model: model, context: TranscriptionRequestContext(languages: ["en"])
        ).transcribe(manifest, store: store)

        XCTAssertTrue(result.turns.allSatisfy { $0.speaker == .them })
        XCTAssertGreaterThanOrEqual(result.echoSuppressedUtterances, 1)
    }

    private func write(_ samples: [Float], to url: URL) throws {
        let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatInt16, interleaved: true)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        for (index, sample) in samples.enumerated() {
            buffer.int16ChannelData![0][index] = Int16(max(-1, min(1, sample)) * 32_767)
        }
        try file.write(from: buffer)
    }

    // MARK: - Fixtures

    private func entry(_ speaker: MeetingTranscriptEntry.Speaker, _ start: Int, _ end: Int, _ text: String) -> MeetingTranscriptEntry {
        MeetingTranscriptEntry(speaker: speaker, start: Double(start) / 1_000, end: Double(end) / 1_000, text: text)
    }

    private func makeEnvelope(system: [Float], microphone: [Float]) -> MeetingEchoEnvelope {
        var timeline = MeetingTrackTimeline()
        timeline.record(frame: 0, at: 0)
        return MeetingEchoEnvelope(
            system: MeetingEchoEnvelope.frames(of: system, timeline: timeline),
            microphone: MeetingEchoEnvelope.frames(of: microphone, timeline: timeline)
        )
    }

    /// Hex's deterministic pseudo-speech: noise shaped by syllable-like bursts whose rhythm depends on `seed`.
    private func speech(seconds: Float, seed: UInt32) -> [Float] {
        var state = max(seed &* 2_654_435_761, 1)
        func noise() -> Float {
            state ^= state << 13
            state ^= state >> 17
            state ^= state << 5
            return (Float(state) / Float(UInt32.max)) * 2 - 1
        }
        let count = Int(seconds * Float(rate))
        let syllable = 0.11 + Float(seed % 7) * 0.013
        return (0..<count).map { index in
            let time = Float(index) / Float(rate)
            let phase = (time / syllable).truncatingRemainder(dividingBy: 1)
            let word = (UInt32((time / (syllable * (3 + Float(seed % 3)))).rounded(.down)) + seed) % 4
            let envelope: Float = word == 0 ? 0.02 : sin(phase * .pi)
            return noise() * 0.2 * envelope
        }
    }

    private func roomNoise(count: Int, seed: UInt32) -> [Float] {
        var state = max(seed &* 747_796_405, 1)
        return (0..<count).map { _ in
            state ^= state << 13
            state ^= state >> 17
            state ^= state << 5
            return ((Float(state) / Float(UInt32.max)) * 2 - 1) * 0.001
        }
    }

    /// The microphone hears the system audio `delayMilliseconds` later, attenuated.
    private func bleed(_ system: [Float], delayMilliseconds: Int, gain: Float) -> [Float] {
        let delay = delayMilliseconds * rate / 1_000
        var microphone = roomNoise(count: system.count, seed: 3)
        for (index, sample) in system.enumerated() where index + delay < microphone.count {
            microphone[index + delay] += sample * gain
        }
        return microphone
    }

    /// A muffled, reverberant copy: one-pole low-pass plus a decaying tail.
    private func room(_ system: [Float], delayMilliseconds: Int, gain: Float) -> [Float] {
        var low: Float = 0
        var wet = system.map { sample -> Float in
            low += 0.15 * (sample - low)
            return low
        }
        let echo = rate * 35 / 1_000
        for index in echo..<wet.count { wet[index] += wet[index - echo] * 0.55 }
        return bleed(wet, delayMilliseconds: delayMilliseconds, gain: gain)
    }

    private func add(_ samples: [Float], gain: Float, at second: Int, to target: inout [Float]) {
        for (offset, sample) in samples.enumerated() where second * rate + offset < target.count {
            target[second * rate + offset] += sample * gain
        }
    }
}

/// Hears the same sentence in every chunk, as a model would hear speaker bleed of remote speech.
private final class SameWordsTranscriber: TimedSpeechTranscribing {
    func transcribeTimed(
        samples: [Float], model: any TranscriptionModel, context: TranscriptionRequestContext
    ) async throws -> [TimedTranscriptSegment] {
        TimedTranscriptSegment.untimed("Ship the beta on Friday", sampleCount: samples.count)
    }

    func speechRegions(in samples: [Float]) async throws -> [Range<Int>]? { nil }
    func releaseResources() async {}
}
