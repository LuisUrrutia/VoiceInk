import CoreAudio
import Foundation

protocol RecordingHardware: AnyObject, Sendable {
    var onAudioChunk: ((Data) -> Void)? { get set }
    var averagePower: Float { get }
    var peakPower: Float { get }

    func prepare(deviceID: AudioDeviceID) throws
    func startRecording(toOutputFile url: URL, deviceID: AudioDeviceID) throws
    func stopRecording()
    func switchDevice(to deviceID: AudioDeviceID) throws
    func invalidatePreparation()
    func teardown()
}
