import Foundation
import XCTest
@testable import VoiceInk

final class UnifiedStreamPauseCapTests: XCTestCase {
    private let head = UnifiedStreamPauseCap.headSamples
    private let tail = UnifiedStreamPauseCap.tailSamples

    func testLongDigitalSilenceKeepsOnlyTheHeadAndTail() {
        let before = speech(seconds: 1, seed: 1)
        let after = speech(seconds: 1, seed: 2)
        var cap = UnifiedStreamPauseCap()

        let heard = feedAll(&cap, before + silence(seconds: 10) + after)

        XCTAssertEqual(heard.count, before.count + head + tail + after.count)
        XCTAssertEqual(Array(heard.prefix(before.count)), before)
        XCTAssertTrue(heard[before.count..<before.count + head + tail].allSatisfy { $0 == 0 })
        XCTAssertEqual(Array(heard.suffix(after.count)), after)
        XCTAssertEqual(cap.droppedSamples, 160_000 - head - tail)
    }

    func testPausesUpToHeadAndTailAreUntouched() {
        let audio = speech(seconds: 1, seed: 3) + silence(samples: head + tail) + speech(seconds: 1, seed: 4)
        var cap = UnifiedStreamPauseCap()

        XCTAssertEqual(feedAll(&cap, audio), audio)
        XCTAssertEqual(cap.droppedSamples, 0)
    }

    func testSteadyNoiseFloorIsCutLikeSilence() {
        let noise = gaussian(count: 16_000 * 12, rmsDBFS: -50, seed: 5)
        var audio = noise
        let before = speech(seconds: 1, seed: 6)
        let after = speech(seconds: 1, seed: 7)
        audio.replaceSubrange(0..<before.count, with: zip(before, noise).map(+))
        let resume = audio.count - after.count
        audio.replaceSubrange(resume..<audio.count, with: zip(after, noise[resume...]).map(+))
        var cap = UnifiedStreamPauseCap()

        let heard = feedAll(&cap, audio)

        // The floor settles within a few frames of the pause, so all but that settling is cut.
        XCTAssertLessThan(heard.count, before.count + head + tail + after.count + 16_000 / 2)
        XCTAssertGreaterThanOrEqual(heard.count, before.count + head + tail + after.count)
        XCTAssertEqual(Array(heard.suffix(after.count)), Array(audio.suffix(after.count)))
    }

    func testQuietSpeechOverSteadyNoiseIsNeverCut() {
        // Hex issue 458: speech about 8 dB above -35 dBFS room noise, with natural word gaps, for 17 s.
        let noise = gaussian(count: 16_000 * 17, rmsDBFS: -35, seed: 8)
        let speechBursts = (0..<noise.count).map { index -> Float in
            let inWord = (index / 4_800) % 3 != 2
            return inWord ? Float(sin(Double(index) * 0.07)) * decibels(-27) * Float(2).squareRoot() : 0
        }
        let audio = zip(noise, speechBursts).map(+)
        var cap = UnifiedStreamPauseCap()

        XCTAssertEqual(feedAll(&cap, audio) + cap.finish(), audio)
        XCTAssertEqual(cap.droppedSamples, 0)
    }

    func testNoiseFloorFallsAtOnceAndRisesSlowly() {
        var classifier = QuietFrameClassifier()
        let loud = Array(repeating: decibels(-20), count: 320)
        let quiet = Array(repeating: decibels(-60), count: 320)

        XCTAssertTrue(classifier.isQuiet(loud), "The first frame sets the floor")
        XCTAssertTrue(classifier.isQuiet(quiet), "The floor falls to a quieter frame immediately")
        XCTAssertFalse(classifier.isQuiet(loud), "A sudden rise above the floor is not quiet")
        for _ in 0..<620 { _ = classifier.isQuiet(loud) }
        // After about 12 s at 3 dB/s the floor has risen to within the 4 dB margin of the steady level.
        XCTAssertTrue(classifier.isQuiet(loud))
    }

    func testIrregularChunksMatchOneBlock() {
        let audio = speech(seconds: 1, seed: 9) + silence(seconds: 6) + speech(seconds: 1, seed: 10) + silence(seconds: 4)
        var whole = UnifiedStreamPauseCap()
        let expected = whole.feed(audio) + whole.finish()

        for sizes in [[171, 170, 171], [1], [319, 1, 640, 7]] {
            var cap = UnifiedStreamPauseCap()
            var heard: [Float] = []
            var index = 0
            var turn = 0
            while index < audio.count {
                let end = min(audio.count, index + sizes[turn % sizes.count])
                heard += cap.feed(Array(audio[index..<end]))
                index = end
                turn += 1
            }
            heard += cap.finish()
            XCTAssertEqual(heard, expected, "chunk sizes \(sizes)")
        }
    }

    func testTrailingPauseKeepsOnlyItsHeadAndShortEndingKeepsPartialFrame() {
        let words = speech(seconds: 1, seed: 11)
        var long = UnifiedStreamPauseCap()
        let longHeard = feedAll(&long, words + silence(seconds: 5) + silence(samples: 100)) + long.finish()
        XCTAssertEqual(longHeard.count, words.count + head)

        var short = UnifiedStreamPauseCap()
        let shortAudio = words + silence(samples: 100)
        XCTAssertEqual(feedAll(&short, shortAudio) + short.finish(), shortAudio)
    }

    // MARK: - Fixtures

    private func feedAll(_ cap: inout UnifiedStreamPauseCap, _ audio: [Float]) -> [Float] {
        stride(from: 0, to: audio.count, by: 171).flatMap { cap.feed(Array(audio[$0..<min(audio.count, $0 + 171)])) }
    }

    /// Syllable-like level changes: one -40 dBFS frame in five, the rest at -20 dBFS, ending loud.
    private func speech(seconds: Int, seed: UInt64) -> [Float] {
        let loud = gaussian(count: 16_000 * seconds, rmsDBFS: -20, seed: seed)
        return loud.enumerated().map { index, sample in (index / 320) % 5 == 0 ? sample * decibels(-20) : sample }
    }

    private func silence(seconds: Int) -> [Float] { silence(samples: 16_000 * seconds) }
    private func silence(samples: Int) -> [Float] { [Float](repeating: 0, count: samples) }

    private func gaussian(count: Int, rmsDBFS: Float, seed: UInt64) -> [Float] {
        var state = seed &* 0x9E37_79B9_7F4A_7C15 | 1
        func uniform() -> Float {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return max(Float.leastNonzeroMagnitude, Float(state >> 40) / Float(1 << 24))
        }
        let rms = decibels(rmsDBFS)
        return (0..<count).map { _ in rms * (-2 * log(uniform())).squareRoot() * cos(2 * .pi * uniform()) }
    }
}

private func decibels(_ value: Float) -> Float { pow(10, value / 20) }
