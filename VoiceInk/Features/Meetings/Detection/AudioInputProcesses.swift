import AppKit
import CoreAudio
import Darwin
import Foundation

/// A process that is capturing audio input, with the bundle identifiers of itself and its ancestors, so a
/// browser helper or `avconferenced` can be traced to the app that owns the call.
struct AudioInputProcess: Equatable, Sendable {
    var pid: pid_t
    var bundleIDs: [String]
}

protocol AudioInputProcessListing: Sendable {
    func processesUsingInput() -> [AudioInputProcess]
}

/// Core Audio's process objects (macOS 14.2+) report which processes run audio input. Reading them needs no
/// permission and does not open any device.
struct CoreAudioInputProcessListing: AudioInputProcessListing {
    func processesUsingInput() -> [AudioInputProcess] {
        let ownPID = getpid()
        return processObjects().compactMap { object -> AudioInputProcess? in
            guard isRunningInput(object), let pid = pid(of: object), pid != ownPID else { return nil }
            var bundleIDs = bundleID(of: object).map { [$0] } ?? []
            for ancestor in Self.lineage(of: pid) {
                if let id = NSRunningApplication(processIdentifier: ancestor)?.bundleIdentifier, !bundleIDs.contains(id) {
                    bundleIDs.append(id)
                }
            }
            return AudioInputProcess(pid: pid, bundleIDs: bundleIDs)
        }
    }

    /// The process and up to four parents, stopping at launchd.
    static func lineage(of pid: pid_t) -> [pid_t] {
        var result: [pid_t] = []
        var current = pid
        for _ in 0..<5 where current > 1 {
            result.append(current)
            var info = proc_bsdinfo()
            let size = proc_pidinfo(current, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
            guard size == Int32(MemoryLayout<proc_bsdinfo>.size) else { break }
            current = pid_t(info.pbi_ppid)
        }
        return result
    }

    private func processObjects() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &objects) == noErr else { return [] }
        return Array(objects.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }

    private func isRunningInput(_ object: AudioObjectID) -> Bool {
        var value: UInt32 = 0
        return read(kAudioProcessPropertyIsRunningInput, of: object, into: &value) && value != 0
    }

    private func pid(of object: AudioObjectID) -> pid_t? {
        var value: pid_t = 0
        return read(kAudioProcessPropertyPID, of: object, into: &value) ? value : nil
    }

    private func bundleID(of object: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyBundleID, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr,
            let string = value?.takeRetainedValue() as String?, !string.isEmpty
        else { return nil }
        return string
    }

    private func read<T>(_ selector: AudioObjectPropertySelector, of object: AudioObjectID, into value: inout T) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr
    }
}
