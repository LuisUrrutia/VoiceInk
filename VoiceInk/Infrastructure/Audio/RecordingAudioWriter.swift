import AudioToolbox
import Foundation

/// Serial processing boundary shared by disk and streaming, including converter tails.
final class RecordingAudioWriter {
    private var file: ExtAudioFileRef?
    private var converter: ContinuousAudioConverter
    var onAudioChunk: ((Data) -> Void)?
    private(set) var failure: Error?

    init(url: URL, sampleRate: Double, channelCount: UInt32) throws {
        converter = try ContinuousAudioConverter(sampleRate: sampleRate, channelCount: channelCount)
        var format = AudioStreamBasicDescription(
            mSampleRate: 16_000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2,
            mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0
        )
        let status = ExtAudioFileCreateWithURL(
            url as CFURL, kAudioFileWAVEType, &format, nil, AudioFileFlags.eraseFile.rawValue, &file
        )
        guard status == noErr, file != nil else {
            throw RecordingAudioError.fileOperation("creation", status)
        }
    }

    deinit {
        if let file { ExtAudioFileDispose(file) }
    }

    func append(
        _ samples: UnsafeBufferPointer<Float>, frameCount: UInt32,
        sampleRate: Double, channelCount: UInt32
    ) throws {
        if let failure { throw failure }
        do {
            guard file != nil else { throw RecordingAudioError.finished }
            if converter.sampleRate != sampleRate || converter.channelCount != channelCount {
                try changeFormat(sampleRate: sampleRate, channelCount: channelCount)
            }
            try converter.append(samples, frameCount: frameCount, emit: write)
        } catch {
            failure = error
            throw error
        }
    }

    func changeFormat(sampleRate: Double, channelCount: UInt32) throws {
        if let failure { throw failure }
        do {
            guard file != nil else { throw RecordingAudioError.finished }
            let replacement = try ContinuousAudioConverter(sampleRate: sampleRate, channelCount: channelCount)
            try converter.finish(emit: write)
            converter = replacement
        } catch {
            failure = error
            throw error
        }
    }

    func finish() throws {
        if let file {
            do {
                if failure == nil { try converter.finish(emit: write) }
            } catch {
                failure = error
            }
            let status = ExtAudioFileDispose(file)
            self.file = nil
            if status != noErr, failure == nil {
                failure = RecordingAudioError.fileOperation("close", status)
            }
        }
        if let failure { throw failure }
    }

    private func write(_ data: Data) throws {
        guard let file else { throw RecordingAudioError.finished }
        let status = data.withUnsafeBytes { bytes in
            var buffers = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(
                    mNumberChannels: 1, mDataByteSize: UInt32(bytes.count),
                    mData: UnsafeMutableRawPointer(mutating: bytes.baseAddress)
                )
            )
            return ExtAudioFileWrite(file, UInt32(bytes.count / MemoryLayout<Int16>.size), &buffers)
        }
        guard status == noErr else { throw RecordingAudioError.fileOperation("write", status) }
        onAudioChunk?(data)
    }
}
