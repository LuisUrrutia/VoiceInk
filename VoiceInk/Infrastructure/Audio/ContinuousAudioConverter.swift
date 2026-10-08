import AVFoundation
import AudioToolbox
import Foundation

/// Owned by the non-realtime processing queue for one continuous input format.
final class ContinuousAudioConverter {
    let sampleRate: Double
    let channelCount: UInt32
    // Converter property access inside its input block is reentrant; cache the format before conversion.
    private let inputFormat: AVAudioFormat
    private let converter: AVAudioConverter
    private let output: AVAudioPCMBuffer
    private var pendingSamples: [Float] = []
    private var inputOffset = 0
    private var suppliedInput: AVAudioPCMBuffer?
    private var hasInput = false
    private var isFinished = false

    init(sampleRate: Double, channelCount: UInt32, outputFrameCapacity: UInt32 = 1024) throws {
        guard sampleRate.isFinite, sampleRate > 0, channelCount > 0,
              outputFrameCapacity > 0,
              let inputFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false
              ),
              let outputFormat = AVAudioFormat(
                commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true
              ),
              let converter = AVAudioConverter(from: inputFormat, to: outputFormat),
              let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outputFrameCapacity)
        else { throw RecordingAudioError.invalidFormat }

        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.inputFormat = inputFormat
        self.converter = converter
        self.output = output
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        converter.dither = false
    }

    func append(
        _ samples: UnsafeBufferPointer<Float>,
        frameCount: UInt32,
        emit: (Data) throws -> Void
    ) throws {
        guard !isFinished else { throw RecordingAudioError.finished }
        guard samples.count == Int(frameCount) * Int(channelCount) else {
            throw RecordingAudioError.invalidSamples
        }
        guard frameCount > 0 else { return }

        for frame in 0..<Int(frameCount) {
            var mono: Float = 0
            for channel in 0..<Int(channelCount) {
                let sample = samples[frame * Int(channelCount) + channel]
                guard sample.isFinite else { throw RecordingAudioError.invalidSamples }
                mono += sample / Float(channelCount)
            }
            pendingSamples.append(mono)
        }
        hasInput = true
        try convert(ending: false, emit: emit)
    }

    func finish(emit: (Data) throws -> Void) throws {
        guard !isFinished else { return }
        guard hasInput else {
            isFinished = true
            return
        }
        try convert(ending: true, emit: emit)
    }

    func reset() {
        converter.reset()
        pendingSamples.removeAll(keepingCapacity: true)
        inputOffset = 0
        suppliedInput = nil
        hasInput = false
        isFinished = false
    }

    private func convert(ending: Bool, emit: (Data) throws -> Void) throws {
        defer {
            pendingSamples.removeFirst(inputOffset)
            inputOffset = 0
        }

        while true {
            output.frameLength = 0
            var conversionError: NSError?
            var inputError: Error?
            let status = converter.convert(to: output, error: &conversionError) { requested, status in
                let available = self.pendingSamples.count - self.inputOffset
                guard available > 0 else {
                    status.pointee = ending ? .endOfStream : .noDataNow
                    return nil
                }
                let count = min(Int(requested), available)
                guard count > 0,
                      let input = AVAudioPCMBuffer(
                        pcmFormat: self.inputFormat, frameCapacity: UInt32(count)
                      ), let channel = input.floatChannelData?[0]
                else {
                    inputError = RecordingAudioError.invalidSamples
                    status.pointee = .noDataNow
                    return nil
                }

                input.frameLength = UInt32(count)
                self.pendingSamples.withUnsafeBufferPointer { samples in
                    channel.update(from: samples.baseAddress! + self.inputOffset, count: count)
                }
                self.inputOffset += count
                // Core Audio may retain input until the next request, including across conversion calls.
                self.suppliedInput = input
                status.pointee = .haveData
                return input
            }
            if let inputError { throw inputError }
            if let conversionError { throw conversionError }
            guard status != .error else { throw RecordingAudioError.conversionFailed }

            if output.frameLength > 0 {
                let buffer = output.audioBufferList.pointee.mBuffers
                guard let bytes = buffer.mData else { throw RecordingAudioError.conversionFailed }
                try emit(Data(bytes: bytes, count: Int(output.frameLength) * MemoryLayout<Int16>.size))
            }

            switch status {
            case .haveData:
                continue
            case .inputRanDry:
                if ending {
                    guard output.frameLength > 0 else { throw RecordingAudioError.conversionFailed }
                    continue
                }
                return
            case .endOfStream:
                guard ending else { throw RecordingAudioError.conversionFailed }
                isFinished = true
                return
            case .error:
                throw RecordingAudioError.conversionFailed
            @unknown default:
                throw RecordingAudioError.conversionFailed
            }
        }
    }
}

enum RecordingAudioError: LocalizedError {
    case invalidFormat
    case invalidSamples
    case conversionFailed
    case finished
    case fileOperation(String, OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidFormat: return String(localized: "Could not configure recording audio conversion")
        case .invalidSamples: return String(localized: "Invalid recording audio samples")
        case .conversionFailed: return String(localized: "Recording audio conversion failed")
        case .finished: return String(localized: "Recording audio is already finalized")
        case .fileOperation(let operation, let status):
            return "Recording audio file \(operation) failed (\(status))"
        }
    }
}
