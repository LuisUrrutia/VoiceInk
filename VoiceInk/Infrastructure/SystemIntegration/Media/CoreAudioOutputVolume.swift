import CoreAudio
import Foundation

struct CoreAudioOutputVolumeSystem: OutputVolumeSystem {
    func defaultOutputDevice() -> AudioDeviceID? {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
        )
        return status == noErr && deviceID != kAudioObjectUnknown ? deviceID : nil
    }

    func volumeControl(for deviceID: AudioDeviceID) -> (any OutputVolumeControl)? {
        guard let elements = Self.volumeElements(
            channelCount: Self.outputChannelCount(deviceID),
            isSettable: { CoreAudioOutputVolume.isSettable(deviceID: deviceID, element: $0) },
            read: { CoreAudioOutputVolume.read(deviceID: deviceID, element: $0) }
        ) else { return nil }
        return CoreAudioOutputVolume(deviceID: deviceID, elements: elements)
    }

    /// Prefers separate channel volumes. Writing the master volume of an output with readable
    /// channel volumes could lose a balance that cannot be restored, so such outputs stay unchanged.
    static func volumeElements(
        channelCount: UInt32,
        isSettable: (AudioObjectPropertyElement) -> Bool,
        read: (AudioObjectPropertyElement) -> Float32?
    ) -> [AudioObjectPropertyElement]? {
        let channels = channelCount > 0 ? Array(1...channelCount) : []
        if !channels.isEmpty, channels.allSatisfy({ isSettable($0) && read($0) != nil }) {
            return channels
        }
        guard !channels.contains(where: { read($0) != nil }) else { return nil }
        let main = kAudioObjectPropertyElementMain
        return isSettable(main) && read(main) != nil ? [main] : nil
    }

    private static func outputChannelCount(_ deviceID: AudioDeviceID) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr,
            size >= MemoryLayout<AudioBufferList>.size
        else { return 0 }

        let storage = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { storage.deallocate() }
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, storage) == noErr else { return 0 }
        let buffers = UnsafeMutableAudioBufferListPointer(storage.assumingMemoryBound(to: AudioBufferList.self))
        let count = buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
        return count <= 256 ? UInt32(count) : 0
    }
}

final class CoreAudioOutputVolume: OutputVolumeControl {
    private let deviceID: AudioDeviceID
    private let elements: [AudioObjectPropertyElement]

    init(deviceID: AudioDeviceID, elements: [AudioObjectPropertyElement]) {
        self.deviceID = deviceID
        self.elements = elements
    }

    func read() -> [Float32]? {
        var values: [Float32] = []
        for element in elements {
            guard let value = Self.read(deviceID: deviceID, element: element) else { return nil }
            values.append(value)
        }
        return values
    }

    /// Attempts every element so a partial failure leaves no channel skipped.
    func write(_ values: [Float32]) -> Bool {
        guard values.count == elements.count else { return false }
        var succeeded = true
        for (element, value) in zip(elements, values) {
            var address = Self.address(element)
            var scalar = value
            let status = AudioObjectSetPropertyData(
                deviceID, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &scalar
            )
            succeeded = succeeded && status == noErr
        }
        return succeeded
    }

    static func read(deviceID: AudioDeviceID, element: AudioObjectPropertyElement) -> Float32? {
        var address = address(element)
        guard AudioObjectHasProperty(deviceID, &address) else { return nil }
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value) == noErr,
            value.isFinite, (0...1).contains(value)
        else { return nil }
        return value
    }

    static func isSettable(deviceID: AudioDeviceID, element: AudioObjectPropertyElement) -> Bool {
        var address = address(element)
        var settable: DarwinBoolean = false
        return AudioObjectHasProperty(deviceID, &address)
            && AudioObjectIsPropertySettable(deviceID, &address, &settable) == noErr
            && settable.boolValue
    }

    private static func address(_ element: AudioObjectPropertyElement) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: element
        )
    }
}
