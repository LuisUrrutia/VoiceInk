import AVFoundation
import Foundation

enum AudioDecoder {
    static let sampleRate = 16_000.0
    static let maximumSamples = 2 * 60 * 60 * 16_000

    enum InvalidAudio: LocalizedError {
        case empty, tooLong, invalidSamples
        var errorDescription: String? {
            switch self {
            case .empty: return "Audio is empty"
            case .tooLong: return "Audio exceeds the two-hour memory limit; split the file first"
            case .invalidSamples: return "Audio contains invalid samples"
            }
        }
    }

    static func decode(_ url: URL) async throws -> [Float] {
        do {
            return try readFile(url)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as InvalidAudio {
            throw error
        } catch {
            do {
                return try await readAsset(url)
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as InvalidAudio {
                throw error
            } catch {
                throw CLIError.message("Cannot decode audio using AVFoundation: \(error.localizedDescription)")
            }
        }
    }

    static func readFile(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        guard file.length > 0, file.processingFormat.channelCount > 0 else {
            throw InvalidAudio.empty
        }
        guard Double(file.length) / file.processingFormat.sampleRate <= 7200 else {
            throw InvalidAudio.tooLong
        }
        let sourceFormat = file.processingFormat
        guard let monoFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                            sampleRate: sourceFormat.sampleRate, channels: 1, interleaved: false),
              let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                              sampleRate: sampleRate, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: monoFormat, to: targetFormat),
              let input = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: 8192),
              let mono = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: 8192),
              let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: 4096) else {
            throw CLIError.message("Cannot create audio converter")
        }
        var samples: [Float] = []
        var readError: Error?
        while true {
            try Task.checkCancellation()
            var conversionError: NSError?
            let status = converter.convert(to: output, error: &conversionError) { requested, state in
                if file.framePosition >= file.length {
                    state.pointee = .endOfStream
                    return nil
                }
                do {
                    try file.read(into: input, frameCount: min(8192, requested))
                    guard input.frameLength > 0, let channels = input.floatChannelData,
                          let destination = mono.floatChannelData?[0] else {
                        throw CLIError.message("Invalid decoded audio buffer")
                    }
                    mono.frameLength = input.frameLength
                    for frame in 0..<Int(input.frameLength) {
                        var sum: Float = 0
                        for channel in 0..<Int(sourceFormat.channelCount) { sum += channels[channel][frame] }
                        destination[frame] = sum / Float(sourceFormat.channelCount)
                    }
                    state.pointee = .haveData
                    return mono
                } catch {
                    readError = error
                    state.pointee = .endOfStream
                    return nil
                }
            }
            if let readError { throw readError }
            if let conversionError { throw conversionError }
            guard status != .error else { throw CLIError.message("Audio conversion failed") }
            try append(output, to: &samples)
            if status == .endOfStream { break }
            guard output.frameLength > 0 else { throw CLIError.message("Audio converter made no progress") }
        }
        guard !samples.isEmpty else { throw InvalidAudio.empty }
        return samples
    }

    private static func append(_ buffer: AVAudioPCMBuffer, to samples: inout [Float]) throws {
        guard samples.count + Int(buffer.frameLength) <= maximumSamples else {
            throw InvalidAudio.tooLong
        }
        if let data = buffer.floatChannelData?[0] {
            samples.append(contentsOf: UnsafeBufferPointer(start: data, count: Int(buffer.frameLength)))
        }
        guard samples.suffix(Int(buffer.frameLength)).allSatisfy(\.isFinite) else {
            throw InvalidAudio.invalidSamples
        }
    }

    private static func readAsset(_ url: URL) async throws -> [Float] {
        let asset = AVURLAsset(url: url)
        let duration = CMTimeGetSeconds(try await asset.load(.duration))
        guard duration.isFinite, duration > 0 else { throw InvalidAudio.empty }
        guard duration <= 7200 else { throw InvalidAudio.tooLong }
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw CLIError.message("Cannot decode audio: \(url.path)")
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw CLIError.message("Unsupported media audio") }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? CLIError.message("Cannot start audio decoder") }
        defer { if reader.status == .reading { reader.cancelReading() } }
        var samples: [Float] = []
        while let buffer = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let description = CMSampleBufferGetFormatDescription(buffer),
                  let stream = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee,
                  stream.mFormatID == kAudioFormatLinearPCM, stream.mChannelsPerFrame == 1,
                  stream.mSampleRate == sampleRate, stream.mBitsPerChannel == 32,
                  stream.mFormatFlags & kAudioFormatFlagIsFloat != 0,
                  stream.mFormatFlags & kAudioFormatFlagIsBigEndian == 0,
                  let block = CMSampleBufferGetDataBuffer(buffer) else {
                throw CLIError.message("Invalid decoded media format")
            }
            let bytes = CMBlockBufferGetDataLength(block)
            if bytes == 0 { continue }
            guard bytes % MemoryLayout<Float>.size == 0,
                  samples.count + bytes / 4 <= maximumSamples else {
                throw CLIError.message("Invalid or oversized audio")
            }
            var chunk = [Float](repeating: 0, count: bytes / 4)
            let status = chunk.withUnsafeMutableBytes {
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: bytes, destination: $0.baseAddress!)
            }
            guard status == kCMBlockBufferNoErr, chunk.allSatisfy(\.isFinite) else {
                throw CLIError.message("Cannot read decoded audio")
            }
            samples.append(contentsOf: chunk)
        }
        guard reader.status == .completed, !samples.isEmpty else {
            throw reader.error ?? CLIError.message("Audio is empty or corrupt")
        }
        return samples
    }
}
