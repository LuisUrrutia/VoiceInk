import AVFoundation
import XCTest

@testable import VoiceInk

final class ContinuousAudioConverterTests: XCTestCase {
    func testDurationAcrossHundredsOfRegularAndIrregularBlocks() throws {
        for rate in [48_000.0, 44_100.0, 16_000.0] {
            for sizes in [[512], [1, 7, 511, 13, 1023, 29, 333]] {
                let frameCount = sizes.reduce(0, +) * 600
                let input = tone(rate: rate, frequency: 1000, count: frameCount)

                let output = try convert(input, rate: rate, sizes: sizes)

                // One output frame covers rounding of the total duration, never each block.
                XCTAssertEqual(
                    Double(output.count / 2), Double(frameCount) * 16_000 / rate, accuracy: 1,
                    "rate=\(rate), blocks=\(sizes)"
                )
            }
        }
    }

    func testToneHasNoCallbackBoundaryModulation() throws {
        for rate in [48_000.0, 44_100.0] {
            let input = tone(rate: rate, frequency: 1000, count: Int(rate) * 2)
            let reference = pcm(try convert(input, rate: rate, sizes: [input.count]))

            let output = pcm(try convert(input, rate: rate, sizes: [512, 7, 1019, 1, 333]))

            XCTAssertEqual(output.count, reference.count)
            for (actual, expected) in zip(output, reference) {
                XCTAssertEqual(actual, expected, accuracy: 2 / 32768.0)
            }
            let interior = Array(output.dropFirst(128).dropLast(128))
            let residual = interior.enumerated().map { index, sample in
                sample - 0.5 * sin(2 * Double.pi * 1000 * Double(index + 128) / 16_000)
            }
            // RMS residual < -54 dBFS includes PCM16 rounding and passband ripple.
            XCTAssertLessThan(rms(residual), 0.002)
            XCTAssertEqual(rms(interior), 0.5 / sqrt(2), accuracy: 0.002)
        }
    }

    func testFrequenciesAboveOutputNyquistAreSuppressed() throws {
        for rate in [48_000.0, 44_100.0] {
            for frequency in [9000.0, 12_000.0, 20_000.0] {
                let input = tone(rate: rate, frequency: frequency, count: Int(rate))

                let output = pcm(try convert(input, rate: rate, sizes: [512, 3, 787]))

                // At least 45 dB attenuation relative to a 0.5-amplitude sine, excluding edge transients.
                XCTAssertLessThan(rms(Array(output.dropFirst(128).dropLast(128))), 0.002)
            }
        }
    }

    func testStereoDownmixAndAlreadySelectedChannels() throws {
        let left = tone(rate: 48_000, frequency: 1000, count: 48_000)
        let right = left.map { -$0 / 2 }
        let stereo = zip(left, right).flatMap { [$0, $1] }
        let mono = zip(left, right).map { ($0 + $1) / 2 }

        let mixed = try convert(stereo, rate: 48_000, channels: 2, sizes: [512, 7])
        let expected = try convert(mono, rate: 48_000, sizes: [512, 7])
        let selected = try convert(left, rate: 48_000, sizes: [512, 7])

        XCTAssertEqual(mixed, expected)
        XCTAssertEqual(rms(pcm(selected)), 0.5 / sqrt(2), accuracy: 0.002)
        XCTAssertEqual(rms(pcm(mixed)), 0.125 / sqrt(2), accuracy: 0.002)
        XCTAssertEqual(
            AudioInputChannelSelection.resolve(deviceChannelCount: 4, preferredStereoChannels: [3, 4])
                .deviceChannelIndices,
            [2, 3]
        )
    }

    func testSilenceEmptyInputClippingAndVeryShortClips() throws {
        for rate in [48_000.0, 44_100.0, 16_000.0] {
            XCTAssertTrue(try convert([], rate: rate, sizes: [512]).isEmpty)
            for count in [1, 2, 3, 7, 31, 512] {
                let silence = try convert([Float](repeating: 0, count: count), rate: rate, sizes: [1, 7])
                XCTAssertEqual(Double(silence.count / 2), Double(count) * 16_000 / rate, accuracy: 1)
                XCTAssertTrue(silence.allSatisfy { $0 == 0 })
            }
        }
        let output = pcm(try convert([0, 0.5, -0.5, 2, -2], rate: 16_000, sizes: [1]))
        XCTAssertEqual(output.count, 5)
        for (actual, expected) in zip(output, [0, 0.5, -0.5, 32767.0 / 32768, -1]) {
            XCTAssertEqual(actual, expected, accuracy: 1 / 32768.0)
        }
    }

    func testSmallOutputBuffersDrainAllTailAndResetRemovesOldState() throws {
        let input = tone(rate: 44_100, frequency: 1000, count: 4417)
        let converter = try ContinuousAudioConverter(sampleRate: 44_100, channelCount: 1, outputFrameCapacity: 7)
        var output = Data()
        try input.withUnsafeBufferPointer {
            try converter.append($0, frameCount: UInt32(input.count)) { output.append($0) }
        }
        let beforeStop = output.count

        try converter.finish { output.append($0) }
        let afterStop = output.count
        try converter.finish { output.append($0) }
        converter.reset()
        var next = Data()
        let silence = [Float](repeating: 0, count: 882)
        try silence.withUnsafeBufferPointer {
            try converter.append($0, frameCount: UInt32(silence.count)) { next.append($0) }
        }
        try converter.finish { next.append($0) }

        XCTAssertGreaterThan(afterStop - beforeStop, 7 * 2)
        XCTAssertEqual(output.count, afterStop)
        XCTAssertEqual(output, try convert(input, rate: 44_100, sizes: [512]))
        XCTAssertEqual(next.count / 2, 320)
        XCTAssertTrue(next.allSatisfy { $0 == 0 })
    }

    func testVeryShortSignalRetainsStopTailAndDownsampledClippingSaturates() throws {
        for rate in [48_000.0, 44_100.0] {
            let converter = try ContinuousAudioConverter(sampleRate: rate, channelCount: 1)
            let impulse: [Float] = [0, 0, 0, 0.5, 0, 0, 0]
            var output = Data()
            try impulse.withUnsafeBufferPointer {
                try converter.append($0, frameCount: 7) { output.append($0) }
            }
            XCTAssertTrue(output.isEmpty)

            try converter.finish { output.append($0) }

            XCTAssertEqual(Double(output.count / 2), 7 * 16_000 / rate, accuracy: 1)
            XCTAssertTrue(pcm(output).contains { abs($0) > 1 / 32768.0 })
            XCTAssertEqual(output, try convert(impulse, rate: rate, sizes: [1]))

            for (inputLevel, clipped) in [(Float(2), 32767.0 / 32768), (Float(-2), -1.0)] {
                let input = [Float](repeating: inputLevel, count: Int(rate))
                let samples = pcm(try convert(input, rate: rate, sizes: [512, 7]))
                XCTAssertTrue(samples.dropFirst(128).dropLast(128).allSatisfy { $0 == clipped })
            }
        }
    }

    func testWAVAndStreamingIncludeIdenticalFinalTailAcrossFormatSwitch() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("recording.wav")
        let writer = try RecordingAudioWriter(url: url, sampleRate: 48_000, channelCount: 1)
        var streamed = Data()
        writer.onAudioChunk = { streamed.append($0) }
        let first = tone(rate: 48_000, frequency: 1000, count: 4807)
        let second = tone(rate: 44_100, frequency: 2000, count: 4421)
        let third = [Float](repeating: 0, count: 1600)

        for (input, rate) in [(first, 48_000.0), (second, 44_100.0), (third, 16_000.0)] {
            try input.withUnsafeBufferPointer {
                try writer.append($0, frameCount: UInt32(input.count), sampleRate: rate, channelCount: 1)
            }
        }
        try writer.changeFormat(sampleRate: 48_000, channelCount: 1)
        let final = tone(rate: 48_000, frequency: 1000, count: 512)
        try final.withUnsafeBufferPointer {
            try writer.append($0, frameCount: 512, sampleRate: 48_000, channelCount: 1)
        }
        let beforeStop = streamed.count
        try writer.finish()
        let afterStop = streamed.count
        try writer.finish()

        var expected = try convert(first, rate: 48_000, sizes: [first.count])
        expected.append(try convert(second, rate: 44_100, sizes: [second.count]))
        expected.append(try convert(third, rate: 16_000, sizes: [third.count]))
        expected.append(try convert(final, rate: 48_000, sizes: [final.count]))
        XCTAssertGreaterThan(afterStop, beforeStop)
        XCTAssertEqual(streamed, expected)
        XCTAssertEqual(try wavPCM(at: url), streamed)
        XCTAssertEqual(try AVAudioFile(forReading: url).length, Int64(streamed.count / 2))
        XCTAssertNil(writer.failure)

        let nextURL = directory.appendingPathComponent("next.wav")
        let next = try RecordingAudioWriter(url: nextURL, sampleRate: 48_000, channelCount: 1)
        let silence = [Float](repeating: 0, count: 4800)
        try silence.withUnsafeBufferPointer {
            try next.append($0, frameCount: 4800, sampleRate: 48_000, channelCount: 1)
        }
        try next.finish()
        let nextPCM = try wavPCM(at: nextURL)
        XCTAssertEqual(nextPCM.count / 2, 1600)
        XCTAssertTrue(nextPCM.allSatisfy { $0 == 0 })
    }

    func testSetupAndProcessingFailuresAreThrownAndRemainFailedOnClose() throws {
        XCTAssertThrowsError(try ContinuousAudioConverter(sampleRate: 0, channelCount: 1))
        XCTAssertThrowsError(try ContinuousAudioConverter(sampleRate: .nan, channelCount: 1))
        XCTAssertThrowsError(try ContinuousAudioConverter(sampleRate: 48_000, channelCount: 0))
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("failed.wav")
        XCTAssertThrowsError(try RecordingAudioWriter(
            url: directory.appendingPathComponent("absent/recording.wav"),
            sampleRate: 48_000, channelCount: 1
        ))
        let writer = try RecordingAudioWriter(url: url, sampleRate: 48_000, channelCount: 1)
        var streamed = Data()
        writer.onAudioChunk = { streamed.append($0) }
        let samples: [Float] = [.nan]

        XCTAssertThrowsError(try samples.withUnsafeBufferPointer {
            try writer.append($0, frameCount: 1, sampleRate: 48_000, channelCount: 1)
        })
        XCTAssertThrowsError(try writer.finish())

        XCTAssertNotNil(writer.failure)
        XCTAssertTrue(streamed.isEmpty)
        XCTAssertEqual(try AVAudioFile(forReading: url).length, 0)
        let converter = try ContinuousAudioConverter(sampleRate: 16_000, channelCount: 1)
        let valid: [Float] = [0.5]
        XCTAssertThrowsError(try valid.withUnsafeBufferPointer {
            try converter.append($0, frameCount: 1) { _ in throw RecordingAudioError.conversionFailed }
        })
    }

    private func tone(rate: Double, frequency: Double, count: Int) -> [Float] {
        (0..<count).map { Float(0.5 * sin(2 * Double.pi * frequency * Double($0) / rate)) }
    }

    private func convert(
        _ input: [Float], rate: Double, channels: UInt32 = 1, sizes: [Int]
    ) throws -> Data {
        let converter = try ContinuousAudioConverter(sampleRate: rate, channelCount: channels)
        var output = Data()
        var offset = 0
        var block = 0
        let frames = input.count / Int(channels)
        try input.withUnsafeBufferPointer { samples in
            while offset < frames {
                let count = min(sizes[block % sizes.count], frames - offset)
                let start = offset * Int(channels)
                let slice = UnsafeBufferPointer(rebasing: samples[start..<start + count * Int(channels)])
                try converter.append(slice, frameCount: UInt32(count)) { output.append($0) }
                offset += count
                block += 1
            }
        }
        try converter.append(UnsafeBufferPointer<Float>(start: nil, count: 0), frameCount: 0) {
            output.append($0)
        }
        try converter.finish { output.append($0) }
        return output
    }

    private func pcm(_ data: Data) -> [Double] {
        data.withUnsafeBytes { bytes in
            stride(from: 0, to: bytes.count, by: 2).map {
                Double(Int16(littleEndian: bytes.loadUnaligned(fromByteOffset: $0, as: Int16.self))) / 32768
            }
        }
    }

    private func rms(_ samples: [Double]) -> Double {
        sqrt(samples.reduce(0) { $0 + $1 * $1 } / Double(samples.count))
    }

    private func makeDirectory() throws -> URL {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let directory = root.appendingPathComponent(".tmp/audio-resampling-tests/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func wavPCM(at url: URL) throws -> Data {
        let data = try Data(contentsOf: url)
        var offset = 12
        while offset + 8 <= data.count {
            let length = data.withUnsafeBytes {
                Int(UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: offset + 4, as: UInt32.self)))
            }
            let start = offset + 8
            guard start + length <= data.count else { break }
            if String(data: data[offset..<offset + 4], encoding: .ascii) == "data" {
                return data.subdata(in: start..<start + length)
            }
            offset = start + length + length % 2
        }
        throw RecordingAudioError.conversionFailed
    }
}
