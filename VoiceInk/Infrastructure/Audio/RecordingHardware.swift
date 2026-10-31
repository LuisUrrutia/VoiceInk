import CoreAudio
import Foundation

protocol RecordingHardware: AnyObject, Sendable {
    var onAudioChunk: ((Data) -> Void)? { get set }
    var averagePower: Float { get }
    var peakPower: Float { get }
    var recordingError: Error? { get }
    var firstAudioTimestampNanoseconds: UInt64? { get }
    var preRollStartNanoseconds: UInt64? { get }
    /// Monotonic uptime through which hardware audio has been delivered for this recording.
    var capturedThroughNanoseconds: UInt64? { get }
    /// Called on the processing queue after each input block is written: the total PCM frames written so far and
    /// the capture time of that block's end, so a consumer can map written frames to capture time.
    var onCaptureProgress: ((_ writtenFrames: Int, _ capturedEndNanoseconds: UInt64) -> Void)? { get set }

    func prepare(deviceID: AudioDeviceID, selectedInputChannels: [UInt32]?) throws
    func startRecording(toOutputFile url: URL, deviceID: AudioDeviceID, selectedInputChannels: [UInt32]?) throws
    func startRecording(
        toOutputFile url: URL, deviceID: AudioDeviceID, selectedInputChannels: [UInt32]?,
        preRollPressNanoseconds: UInt64?
    ) throws
    func stopRecording()
    func switchDevice(to deviceID: AudioDeviceID, selectedInputChannels: [UInt32]?) throws
    func invalidatePreparation()
    func teardown()
    func startIdleCapture(deviceID: AudioDeviceID, selectedInputChannels: [UInt32]?) throws
    func stopIdleCapture()
    func holdPreRoll(forPressAt pressNanoseconds: UInt64)
}

extension RecordingHardware {
    var recordingError: Error? { nil }
    var firstAudioTimestampNanoseconds: UInt64? { nil }
    var preRollStartNanoseconds: UInt64? { nil }
    var capturedThroughNanoseconds: UInt64? { nil }
    var onCaptureProgress: ((_ writtenFrames: Int, _ capturedEndNanoseconds: UInt64) -> Void)? {
        get { nil }
        set {}
    }

    func startRecording(
        toOutputFile url: URL, deviceID: AudioDeviceID, selectedInputChannels: [UInt32]?,
        preRollPressNanoseconds: UInt64?
    ) throws {
        try startRecording(toOutputFile: url, deviceID: deviceID, selectedInputChannels: selectedInputChannels)
    }

    func startIdleCapture(deviceID: AudioDeviceID, selectedInputChannels: [UInt32]?) throws {}
    func stopIdleCapture() {}
    func holdPreRoll(forPressAt pressNanoseconds: UInt64) {}
}
