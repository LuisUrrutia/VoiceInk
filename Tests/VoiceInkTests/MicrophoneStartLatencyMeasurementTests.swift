import AVFoundation
import CoreAudio
import XCTest
@testable import VoiceInk

/// Opt-in physical measurement; set VOICEINK_MIC_LATENCY_RESULT to a writable report path.
final class MicrophoneStartLatencyMeasurementTests: XCTestCase {
    private struct Input {
        let id: AudioDeviceID
        let name: String
        let transport: UInt32
    }

    func testMeasureStartToFirstHardwareAudio() throws {
        guard let reportPath = ProcessInfo.processInfo.environment["VOICEINK_MIC_LATENCY_RESULT"] else {
            throw XCTSkip("Set VOICEINK_MIC_LATENCY_RESULT to measure physical microphone start latency")
        }
        let iterations = Int(ProcessInfo.processInfo.environment["VOICEINK_MIC_LATENCY_ITERATIONS"] ?? "") ?? 8
        let inputs = physicalInputs()
        XCTAssertFalse(inputs.isEmpty)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MicLatency-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var report = [
            "microphone authorization=\(AVCaptureDevice.authorizationStatus(for: .audio).rawValue) iterations=\(iterations)"
        ]

        for input in inputs {
            for mode in ["prepared", "unprepared", "keepReady"] {
                let recorder = CoreAudioRecorder()
                defer { recorder.teardown() }
                var latencies: [Double] = []
                var preRolls: [Double] = []
                var peaks: [Float] = []
                for iteration in 0..<iterations {
                    switch mode {
                    case "prepared": try recorder.prepare(deviceID: input.id)
                    case "keepReady": try recorder.startIdleCapture(deviceID: input.id, selectedInputChannels: nil)
                    default: recorder.invalidatePreparation()
                    }
                    Thread.sleep(forTimeInterval: 1.5)
                    let url = directory.appendingPathComponent("\(input.id)-\(mode)-\(iteration).wav")
                    let press = DispatchTime.now().uptimeNanoseconds
                    if mode == "keepReady" { recorder.holdPreRoll(forPressAt: press) }
                    try recorder.startRecording(
                        toOutputFile: url, deviceID: input.id, selectedInputChannels: nil,
                        preRollPressNanoseconds: mode == "keepReady" ? press : nil
                    )
                    let deadline = Date().addingTimeInterval(3)
                    while recorder.firstAudioTimestampNanoseconds == nil, Date() < deadline {
                        Thread.sleep(forTimeInterval: 0.0005)
                    }
                    Thread.sleep(forTimeInterval: 0.5)
                    peaks.append(recorder.peakPower)
                    if let first = recorder.firstAudioTimestampNanoseconds {
                        latencies.append(Double(Int64(first) - Int64(press)) / 1_000_000)
                    }
                    preRolls.append(recorder.attachedPreRollDuration * 1000)
                    recorder.stopRecording()
                }
                report.append(
                    "device=\"\(input.name)\" transport=\(fourCC(input.transport)) mode=\(mode) "
                        + "startToFirstAudioMs=\(summary(latencies)) preRollMs=\(summary(preRolls)) "
                        + "maxPeakDb=\(String(format: "%.1f", peaks.max() ?? -160))"
                )
            }
        }
        try report.joined(separator: "\n").appending("\n").write(
            toFile: reportPath, atomically: true, encoding: .utf8
        )
    }

    private func summary(_ values: [Double]) -> String {
        guard !values.isEmpty else { return "none" }
        let sorted = values.sorted()
        let median = sorted[sorted.count / 2]
        return String(
            format: "n=%d,min=%.1f,median=%.1f,max=%.1f", sorted.count, sorted.first!, median, sorted.last!
        )
    }

    private func fourCC(_ value: UInt32) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((value >> UInt32($0)) & 0xff) }
        return String(decoding: bytes, as: UTF8.self)
    }

    private func physicalInputs() -> [Input] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr
        else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr
        else { return [] }
        let measured: Set<UInt32> = [
            kAudioDeviceTransportTypeBuiltIn, kAudioDeviceTransportTypeUSB,
            kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE,
        ]
        return ids.compactMap { id in
            guard hasInput(id), let transport = transportType(id), measured.contains(transport) else { return nil }
            return Input(id: id, name: name(id), transport: transport)
        }
    }

    private func hasInput(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration, mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return false }
        let list = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
        defer { list.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, list) == noErr else { return false }
        let buffers = UnsafeMutableAudioBufferListPointer(list.assumingMemoryBound(to: AudioBufferList.self))
        return buffers.contains { $0.mNumberChannels > 0 }
    }

    private func transportType(_ id: AudioDeviceID) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr ? value : nil
    }

    private func name(_ id: AudioDeviceID) -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceNameCFString, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr, let value else {
            return "Unknown"
        }
        return value.takeRetainedValue() as String
    }
}
