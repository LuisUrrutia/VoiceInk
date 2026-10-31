import AudioToolbox
import CoreAudio
import Foundation
import os

/// What a meeting track recorded once its capture stopped.
struct MeetingTrackCaptureResult: Equatable, Sendable {
    var timeline = MeetingTrackTimeline()
    var droppedBuffers = 0
    var heardSignal = false
    var failure: String?
}

/// Other participants' audio: every process's output except VoiceInk's own.
protocol SystemAudioCapturing: AnyObject, Sendable {
    /// Monotonic uptime of the last delivered buffer, for stall detection.
    var lastDeliveryNanoseconds: UInt64? { get }
    func start(writingTo url: URL, meetingStartNanoseconds: UInt64) throws
    /// Replaces a stalled tap while keeping the same file and timeline.
    func restart() throws
    func stop() -> MeetingTrackCaptureResult
}

enum SystemAudioCaptureError: LocalizedError {
    case coreAudio(String, OSStatus)
    case unsupportedFormat
    case notStarted

    var errorDescription: String? {
        switch self {
        case .coreAudio(let operation, let status): "System audio \(operation) failed (\(status))"
        case .unsupportedFormat: String(localized: "The system audio tap delivers an unsupported format")
        case .notStarted: String(localized: "System audio capture has not started")
        }
    }
}

/// A private Core Audio process tap read through a private aggregate device. The IOProc runs on a serial queue
/// (not the realtime thread), which converts to 16 kHz PCM16 and writes the WAV.
final class ProcessTapSystemAudioCapture: SystemAudioCapturing, @unchecked Sendable {
    /// Peaks at or above one PCM16 step count as heard; a denied tap delivers exact zeros.
    static let heardPeakThreshold: Float = 1.0 / 32_768

    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "SystemAudioCapture")
    private let queue = DispatchQueue(label: "com.prakashjoshipax.voiceink.meetingSystemAudio", qos: .userInitiated)
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    // Confined to `queue`.
    private var writer: RecordingAudioWriter?
    private var tap = TapObjects()
    private var meetingStartNanoseconds: UInt64 = 0
    private var mono: [Float] = []

    private struct State {
        var result = MeetingTrackCaptureResult()
        var lastDeliveryNanoseconds: UInt64?
    }

    private struct TapObjects {
        var tapID = AudioObjectID(kAudioObjectUnknown)
        var aggregateID = AudioObjectID(kAudioObjectUnknown)
        var ioProcID: AudioDeviceIOProcID?
        var format = AudioStreamBasicDescription()
    }

    var lastDeliveryNanoseconds: UInt64? { state.withLock { $0.lastDeliveryNanoseconds } }

    func start(writingTo url: URL, meetingStartNanoseconds: UInt64) throws {
        try queue.sync {
            self.meetingStartNanoseconds = meetingStartNanoseconds
            state.withLock { $0 = State() }
            let objects = try makeTap()
            do {
                writer = try RecordingAudioWriter(
                    url: url, sampleRate: objects.format.mSampleRate, channelCount: 1
                )
                tap = objects
                try startIO()
            } catch {
                destroy(objects)
                tap = TapObjects()
                writer = nil
                throw error
            }
        }
    }

    func restart() throws {
        stopIO()
        try queue.sync {
            guard writer != nil else { throw SystemAudioCaptureError.notStarted }
            destroy(tap)
            tap = TapObjects()
            tap = try makeTap()
            try startIO()
            logger.notice("System audio tap restarted")
        }
    }

    func stop() -> MeetingTrackCaptureResult {
        stopIO()
        return queue.sync {
            destroy(tap)
            tap = TapObjects()
            if let writer {
                do {
                    try writer.finish()
                } catch {
                    record(failure: error)
                }
            }
            writer = nil
            return state.withLock { $0.result }
        }
    }

    deinit {
        destroy(tap)
    }

    // MARK: - Core Audio objects

    private func makeTap() throws -> TapObjects {
        var objects = TapObjects()
        let excluded = ownProcessObject().map { [$0] } ?? []
        let description = CATapDescription(monoGlobalTapButExcludeProcesses: excluded)
        description.name = "VoiceInk meeting system audio"
        description.isPrivate = true
        description.muteBehavior = .unmuted

        var tapID = AudioObjectID(kAudioObjectUnknown)
        try check(AudioHardwareCreateProcessTap(description, &tapID), "tap creation")
        objects.tapID = tapID

        do {
            var format = AudioStreamBasicDescription()
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            try check(AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &format), "tap format")
            guard format.mFormatID == kAudioFormatLinearPCM, format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
                format.mBitsPerChannel == 32, format.mSampleRate > 0
            else { throw SystemAudioCaptureError.unsupportedFormat }
            objects.format = format

            let aggregate: [String: Any] = [
                kAudioAggregateDeviceNameKey: "VoiceInk Meeting System Audio",
                kAudioAggregateDeviceUIDKey: "com.prakashjoshipax.voiceink.meeting-tap.\(UUID().uuidString)",
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceTapListKey: [
                    [kAudioSubTapUIDKey: description.uuid.uuidString, kAudioSubTapDriftCompensationKey: true]
                ],
            ]
            var aggregateID = AudioObjectID(kAudioObjectUnknown)
            try check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID), "aggregate creation")
            objects.aggregateID = aggregateID

            var ioProcID: AudioDeviceIOProcID?
            try check(
                AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, queue) { [weak self] _, input, inputTime, _, _ in
                    self?.handle(input, at: inputTime.pointee)
                },
                "IOProc creation"
            )
            objects.ioProcID = ioProcID
            return objects
        } catch {
            destroy(objects)
            throw error
        }
    }

    /// Stops outside `queue`: the IOProc runs on it, so stopping from inside could wait on itself.
    private func stopIO() {
        let objects = queue.sync { tap }
        guard let ioProcID = objects.ioProcID else { return }
        AudioDeviceStop(objects.aggregateID, ioProcID)
    }

    private func startIO() throws {
        guard let ioProcID = tap.ioProcID else { throw SystemAudioCaptureError.notStarted }
        try check(AudioDeviceStart(tap.aggregateID, ioProcID), "start")
    }

    private func destroy(_ objects: TapObjects) {
        if objects.aggregateID != kAudioObjectUnknown {
            if let ioProcID = objects.ioProcID {
                AudioDeviceStop(objects.aggregateID, ioProcID)
                AudioDeviceDestroyIOProcID(objects.aggregateID, ioProcID)
            }
            AudioHardwareDestroyAggregateDevice(objects.aggregateID)
        }
        if objects.tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(objects.tapID)
        }
    }

    private func ownProcessObject() -> AudioObjectID? {
        var pid = getpid()
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object
        )
        return status == noErr && object != kAudioObjectUnknown ? object : nil
    }

    private func check(_ status: OSStatus, _ operation: String) throws {
        guard status == noErr else { throw SystemAudioCaptureError.coreAudio(operation, status) }
    }

    // MARK: - IOProc (on `queue`)

    private func handle(_ input: UnsafePointer<AudioBufferList>, at time: AudioTimeStamp) {
        guard let writer else { return }
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard let frameCount = mixToMono(buffers), frameCount > 0 else {
            if !buffers.isEmpty { state.withLock { $0.result.droppedBuffers += 1 } }
            return
        }

        let startNanoseconds = hostNanoseconds(time) ?? DispatchTime.now().uptimeNanoseconds
        let peak = mono.prefix(frameCount).reduce(Float(0)) { max($0, abs($1)) }
        do {
            try mono.withUnsafeBufferPointer { samples in
                try writer.append(
                    UnsafeBufferPointer(rebasing: samples[0..<frameCount]), frameCount: UInt32(frameCount),
                    sampleRate: tap.format.mSampleRate, channelCount: 1
                )
            }
        } catch {
            record(failure: error)
            return
        }
        // Written frames end where this buffer's capture ended, as for the microphone track.
        let bufferStart = Double(Int64(bitPattern: startNanoseconds &- meetingStartNanoseconds)) / 1_000_000_000
        let bufferEnd = bufferStart + Double(frameCount) / tap.format.mSampleRate
        let writtenFrames = writer.writtenFrames
        state.withLock {
            $0.result.timeline.record(frame: writtenFrames, at: bufferEnd)
            if peak >= Self.heardPeakThreshold { $0.result.heardSignal = true }
            $0.lastDeliveryNanoseconds = DispatchTime.now().uptimeNanoseconds
        }
    }

    /// Mixes one cycle's float buffers into `mono`; nil for a layout this capture cannot read.
    private func mixToMono(_ buffers: UnsafeMutableAudioBufferListPointer) -> Int? {
        let planes = buffers.compactMap { buffer -> (UnsafeBufferPointer<Float>, Int)? in
            guard let data = buffer.mData else { return nil }
            let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            return (UnsafeBufferPointer(start: data.assumingMemoryBound(to: Float.self), count: count),
                    max(Int(buffer.mNumberChannels), 1))
        }
        guard !planes.isEmpty else { return nil }
        let frameCount = planes.map { $0.0.count / $0.1 }.min() ?? 0
        if mono.count < frameCount { mono = [Float](repeating: 0, count: frameCount) }
        let channelTotal = Float(planes.reduce(0) { $0 + $1.1 })
        for frame in 0..<frameCount {
            var sum: Float = 0
            for (samples, channels) in planes {
                for channel in 0..<channels { sum += samples[frame * channels + channel] }
            }
            let value = sum / channelTotal
            mono[frame] = value.isFinite ? value : 0
        }
        return frameCount
    }

    private func hostNanoseconds(_ time: AudioTimeStamp) -> UInt64? {
        guard time.mFlags.contains(.hostTimeValid), time.mHostTime > 0, timebase.denom > 0 else { return nil }
        let product = time.mHostTime.multipliedReportingOverflow(by: UInt64(timebase.numer))
        guard !product.overflow else { return nil }
        return product.partialValue / UInt64(timebase.denom)
    }

    private func record(failure error: Error) {
        logger.error("System audio capture failed: \(error, privacy: .public)")
        state.withLock { if $0.result.failure == nil { $0.result.failure = error.localizedDescription } }
    }
}
