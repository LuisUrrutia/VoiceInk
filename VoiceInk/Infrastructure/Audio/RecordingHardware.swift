import CoreAudio
import Foundation

protocol RecordingHardware: AnyObject, Sendable {
    var onAudioChunk: ((Data) -> Void)? { get set }
    var averagePower: Float { get }
    var peakPower: Float { get }
    var recordingError: Error? { get }
    var firstAudioTimestampNanoseconds: UInt64? { get }

    func prepare(deviceID: AudioDeviceID, selectedInputChannels: [UInt32]?) throws
    func startRecording(toOutputFile url: URL, deviceID: AudioDeviceID, selectedInputChannels: [UInt32]?) throws
    func stopRecording()
    func switchDevice(to deviceID: AudioDeviceID, selectedInputChannels: [UInt32]?) throws
    func invalidatePreparation()
    func teardown()
}

extension RecordingHardware {
    var recordingError: Error? { nil }
    var firstAudioTimestampNanoseconds: UInt64? { nil }
}
