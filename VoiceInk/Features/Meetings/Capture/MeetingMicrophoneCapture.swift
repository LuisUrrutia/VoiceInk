import Combine
import CoreAudio
import Foundation
import os

/// A microphone capture that runs beside dictation: its own AUHAL instance, outside the dictation's
/// `RecordingDeviceSession`, following the same device resolution (selection, closed lid, requirements,
/// temporary choice and Bluetooth avoidance). A device change switches inputs and keeps the open WAV.
@MainActor
final class MeetingMicrophoneCapture {
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "MeetingMicrophone")
    private let deviceManager: AudioDeviceManager
    private let makeHardware: () -> any RecordingHardware
    private let queue = DispatchQueue(label: "com.prakashjoshipax.voiceink.meetingMicrophone", qos: .userInitiated)
    private let progress = OSAllocatedUnfairLock(initialState: Progress())
    private var hardware: (any RecordingHardware)?
    private var deviceCancellable: AnyCancellable?
    private(set) var activeDeviceID: AudioDeviceID?

    private struct Progress {
        var result = MeetingTrackCaptureResult()
        var meetingStartNanoseconds: UInt64 = 0
    }

    init(
        deviceManager: AudioDeviceManager = .shared,
        makeHardware: @escaping () -> any RecordingHardware = { CoreAudioRecorder() }
    ) {
        self.deviceManager = deviceManager
        self.makeHardware = makeHardware
    }

    func start(writingTo url: URL, meetingStartNanoseconds: UInt64) async throws {
        guard let deviceID = deviceManager.resolveCurrentRecordingDevice().deviceID else {
            throw Recorder.RecorderError.noUsableMicrophone(
                internalMicrophoneBlockedByClosedLid: deviceManager.isClamshellClosed
            )
        }
        progress.withLock { $0 = Progress(meetingStartNanoseconds: meetingStartNanoseconds) }
        let hardware = makeHardware()
        hardware.onAudioChunk = { [progress] data in Self.recordLevel(of: data, into: progress) }
        hardware.onCaptureProgress = { [progress] writtenFrames, capturedEnd in
            Self.record(writtenFrames: writtenFrames, capturedEnd: capturedEnd, into: progress)
        }
        let channels = deviceManager.selectedInputChannels(for: deviceID)
        try await perform { try hardware.startRecording(toOutputFile: url, deviceID: deviceID, selectedInputChannels: channels) }
        self.hardware = hardware
        activeDeviceID = deviceID
        followDeviceChanges()
    }

    func stop() async -> MeetingTrackCaptureResult {
        deviceCancellable = nil
        guard let hardware else { return progress.withLock { $0.result } }
        self.hardware = nil
        activeDeviceID = nil
        let failure = await withCheckedContinuation { continuation in
            queue.async {
                hardware.stopRecording()
                hardware.onAudioChunk = nil
                hardware.onCaptureProgress = nil
                continuation.resume(returning: hardware.recordingError)
                hardware.teardown()
            }
        }
        return progress.withLock { progress in
            if let failure, progress.result.failure == nil { progress.result.failure = failure.localizedDescription }
            return progress.result
        }
    }

    /// Closes the WAV before the process exits; nothing may suspend during termination.
    func stopForTermination() -> MeetingTrackCaptureResult {
        deviceCancellable = nil
        if let hardware {
            self.hardware = nil
            queue.sync {
                hardware.stopRecording()
                hardware.onAudioChunk = nil
                hardware.onCaptureProgress = nil
            }
        }
        return progress.withLock { $0.result }
    }

    /// Re-resolves the input whenever the device manager publishes a change, such as a new selection, an
    /// unplugged device or the lid closing.
    private func followDeviceChanges() {
        deviceCancellable = deviceManager.objectWillChange
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { @MainActor in await self?.switchToResolvedDevice() }
            }
    }

    func switchToResolvedDevice() async {
        guard let hardware, let deviceID = deviceManager.resolveCurrentRecordingDevice().deviceID,
            deviceID != activeDeviceID
        else { return }
        let channels = deviceManager.selectedInputChannels(for: deviceID)
        do {
            try await perform { try hardware.switchDevice(to: deviceID, selectedInputChannels: channels) }
            guard self.hardware === hardware else { return }
            activeDeviceID = deviceID
            logger.notice("Meeting microphone switched deviceID=\(deviceID, privacy: .public)")
        } catch {
            logger.error("Meeting microphone switch failed: \(error, privacy: .public)")
        }
    }

    private func perform(_ work: @escaping @Sendable () throws -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    try work()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Runs on the recorder's processing queue with the exact PCM16 written to the WAV.
    nonisolated private static func recordLevel(of data: Data, into progress: OSAllocatedUnfairLock<Progress>) {
        let heard = data.withUnsafeBytes { bytes in bytes.bindMemory(to: Int16.self).contains { $0 != 0 } }
        if heard { progress.withLock { $0.result.heardSignal = true } }
    }

    /// The written frame count ends where that input block's capture ended, whatever the converter's chunking.
    nonisolated private static func record(
        writtenFrames: Int, capturedEnd: UInt64, into progress: OSAllocatedUnfairLock<Progress>
    ) {
        progress.withLock { progress in
            let end = Double(Int64(bitPattern: capturedEnd &- progress.meetingStartNanoseconds)) / 1_000_000_000
            progress.result.timeline.record(frame: writtenFrames, at: end)
        }
    }
}
