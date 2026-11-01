import AppKit
import CoreAudio
import Foundation
import os

/// One CoreAudio process object. Running states are nil when CoreAudio does not report them.
struct BrowserAudioProcess: Equatable, Sendable {
    let objectID: AudioObjectID
    let pid: pid_t
    let bundleID: String
    let applicationName: String?
    let isRunningOutput: Bool?
    let isRunningInput: Bool?
}

protocol BrowserAudioProcessListing: Sendable {
    /// Every CoreAudio process object; nil when the list cannot be read.
    func processes() -> [BrowserAudioProcess]?
}

enum BrowserAudioCatalog {
    static let bundleIDs: [String] =
        BrowserType.allCases.map(\.bundleIdentifier) + ["org.mozilla.firefox", "org.mozilla.plugincontainer", "org.chromium.Chromium"]

    /// A known browser or one of its helpers (`<bundle id>.helper…`). Safari plays
    /// through a WebKit GPU process that only its application name tells apart.
    static func isBrowser(bundleID: String, applicationName: String?) -> Bool {
        let bundle = bundleID.lowercased()
        if bundle == "com.apple.webkit.gpu" {
            return applicationName?.lowercased().hasPrefix("safari") == true
        }
        return bundleIDs.contains { known in
            let known = known.lowercased()
            return bundle == known || bundle.hasPrefix(known + ".")
        }
    }

    static func browsers(in processes: [BrowserAudioProcess], excluding ownPID: pid_t) -> [BrowserAudioProcess] {
        processes.filter { $0.pid != ownPID && isBrowser(bundleID: $0.bundleID, applicationName: $0.applicationName) }
    }

    static func select(_ which: BrowserAudioProcesses, from browsers: [BrowserAudioProcess]) -> [BrowserAudioProcess] {
        switch which {
        case .playing: browsers.filter { $0.isRunningOutput ?? true }
        case .all: browsers
        }
    }
}

struct CoreAudioBrowserProcessList: BrowserAudioProcessListing {
    func processes() -> [BrowserAudioProcess]? {
        guard let objectIDs = Self.processObjectIDs() else { return nil }
        return objectIDs.compactMap { objectID in
            guard let pid: pid_t = Self.value(objectID, kAudioProcessPropertyPID),
                let bundleID = Self.bundleID(objectID)
            else { return nil }
            let name =
                bundleID.caseInsensitiveCompare("com.apple.WebKit.GPU") == .orderedSame
                ? NSRunningApplication(processIdentifier: pid)?.localizedName : nil
            let output: UInt32? = Self.value(objectID, kAudioProcessPropertyIsRunningOutput)
            let input: UInt32? = Self.value(objectID, kAudioProcessPropertyIsRunningInput)
            return BrowserAudioProcess(
                objectID: objectID, pid: pid, bundleID: bundleID, applicationName: name,
                isRunningOutput: output.map { $0 != 0 }, isRunningInput: input.map { $0 != 0 }
            )
        }
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain
        )
    }

    private static func processObjectIDs() -> [AudioObjectID]? {
        var address = address(kAudioHardwarePropertyProcessObjectList)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return nil }
        var objectIDs = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &objectIDs) == noErr else { return nil }
        return Array(objectIDs.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }

    private static func value<T: FixedWidthInteger>(_ objectID: AudioObjectID, _ selector: AudioObjectPropertySelector) -> T? {
        var address = address(selector)
        var value: T = 0
        var size = UInt32(MemoryLayout<T>.size)
        let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value)
        return status == noErr && size == UInt32(MemoryLayout<T>.size) ? value : nil
    }

    private static func bundleID(_ objectID: AudioObjectID) -> String? {
        var address = address(kAudioProcessPropertyBundleID)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value) == noErr,
            let bundleID = value?.takeRetainedValue() as String?, !bundleID.isEmpty
        else { return nil }
        return bundleID
    }
}

/// Starting I/O on a process tap is the documented trigger for the System Audio Recording
/// prompt; the tap covers only VoiceInk's own output and is closed after half a second.
enum SystemAudioRecordingPrompt {
    static func trigger() {
        DispatchQueue.global(qos: .userInitiated).async {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
                mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain
            )
            var pid = ProcessInfo.processInfo.processIdentifier
            var objectID = AudioObjectID(kAudioObjectUnknown)
            var size = UInt32(MemoryLayout<AudioObjectID>.size)
            guard AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address,
                UInt32(MemoryLayout<pid_t>.size), &pid, &size, &objectID
            ) == noErr, objectID != kAudioObjectUnknown else { return }
            let tap = try? BrowserOutputTap(processObjectIDs: [objectID])
            Thread.sleep(forTimeInterval: 0.5)
            withExtendedLifetime(tap) {}
        }
    }
}

/// The level of a started tap; nil for a window in which it delivered nothing.
protocol BrowserOutputLevel: AnyObject {
    func waitForFirstCycle() async
    func peakDBFS(over window: Duration) async -> Float?
}

/// Hears the browsers' own output through a private CoreAudio process tap.
final class CoreAudioBrowserAudioListener: BrowserAudioListening, @unchecked Sendable {
    typealias TapFactory = ([AudioObjectID]) throws -> any BrowserOutputLevel

    private let which: BrowserAudioProcesses
    private let processList: any BrowserAudioProcessListing
    private let startTap: TapFactory
    private let ownPID = ProcessInfo.processInfo.processIdentifier
    private var tap: (any BrowserOutputLevel)?
    private var hasStarted = false
    private static let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "BrowserMedia")

    init(
        _ which: BrowserAudioProcesses,
        processList: any BrowserAudioProcessListing = CoreAudioBrowserProcessList(),
        startTap: @escaping TapFactory = { try BrowserOutputTap(processObjectIDs: $0) }
    ) {
        self.which = which
        self.processList = processList
        self.startTap = startTap
    }

    func isBrowserUsingMicrophone() -> Bool {
        // An unreadable list counts as a call: leave the browser alone.
        guard let processes = processList.processes() else { return true }
        return BrowserAudioCatalog.browsers(in: processes, excluding: ownPID).contains { $0.isRunningInput == true }
    }

    func peakDBFS(over window: Duration) async -> Float? {
        if !hasStarted {
            hasStarted = true
            let browsers = processList.processes().map { BrowserAudioCatalog.browsers(in: $0, excluding: ownPID) } ?? []
            let selected = BrowserAudioCatalog.select(which, from: browsers)
            // Most dictations find no browser output open and create no tap.
            if !selected.isEmpty {
                do {
                    tap = try startTap(selected.map(\.objectID))
                    await tap?.waitForFirstCycle()
                } catch {
                    Self.logger.warning("Could not listen to the browser: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
        return await tap?.peakDBFS(over: window)
    }

    func isBrowserOutputClosed() -> Bool {
        // A quit browser is not a paused one, and without a started tap nothing could confirm a play.
        guard tap != nil, let processes = processList.processes() else { return false }
        let browsers = BrowserAudioCatalog.browsers(in: processes, excluding: ownPID)
        return !browsers.isEmpty && BrowserAudioCatalog.select(.playing, from: browsers).isEmpty
    }

    func close() {
        tap = nil
    }
}

struct BrowserOutputTapError: LocalizedError {
    let operation: String
    let status: OSStatus
    var errorDescription: String? { "\(operation) failed (OSStatus \(status))" }
}

/// A mono private tap of the given processes, an aggregate device carrying it, and an IO block
/// that keeps the peak since the last reset. Torn down in reverse order on deinit.
final class BrowserOutputTap: BrowserOutputLevel {
    private struct Level {
        var peak: Float = 0
        var cycles: UInt64 = 0
    }

    private static let warmUp: Duration = .milliseconds(300)
    private let level = OSAllocatedUnfairLock(initialState: Level())
    private let queue = DispatchQueue(label: "com.prakashjoshipax.voiceink.browser-tap")
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?

    init(processObjectIDs: [AudioObjectID]) throws {
        let description = CATapDescription(monoMixdownOfProcesses: processObjectIDs)
        description.name = "VoiceInk browser level"
        description.isPrivate = true
        description.muteBehavior = .unmuted
        try Self.check(AudioHardwareCreateProcessTap(description, &tapID), "Creating the browser tap")

        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "VoiceInk Browser Level",
            kAudioAggregateDeviceUIDKey: "com.prakashjoshipax.voiceink.browser-tap.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [
                [kAudioSubTapUIDKey: description.uuid.uuidString, kAudioSubTapDriftCompensationKey: true]
            ],
        ]
        try Self.check(
            AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID), "Creating the browser tap device"
        )
        let level = self.level
        try Self.check(
            AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, queue) { _, input, _, _, _ in
                let peak = Self.peak(of: input)
                level.withLock { level in
                    level.peak = max(level.peak, peak)
                    level.cycles &+= 1
                }
            },
            "Attaching to the browser tap"
        )
        try Self.check(AudioDeviceStart(aggregateID, ioProcID), "Starting the browser tap")
    }

    deinit {
        if aggregateID != kAudioObjectUnknown {
            if let ioProcID {
                AudioDeviceStop(aggregateID, ioProcID)
                AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
        }
    }

    func waitForFirstCycle() async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: Self.warmUp)
        while level.withLock({ $0.cycles }) == 0, clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    /// Nil when the tap delivered nothing during `window`.
    func peakDBFS(over window: Duration) async -> Float? {
        let cycles = level.withLock { level in
            level.peak = 0
            return level.cycles
        }
        try? await Task.sleep(for: window)
        let current = level.withLock { $0 }
        guard current.cycles != cycles else { return nil }
        return current.peak > 0 ? 20 * log10(current.peak) : -200
    }

    private static func peak(of list: UnsafePointer<AudioBufferList>) -> Float {
        var peak: Float = 0
        for buffer in UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list)) {
            guard let data = buffer.mData else { continue }
            let samples = data.assumingMemoryBound(to: Float.self)
            for index in 0..<(Int(buffer.mDataByteSize) / MemoryLayout<Float>.size) {
                peak = max(peak, abs(samples[index]))
            }
        }
        return peak
    }

    private static func check(_ status: OSStatus, _ operation: String) throws {
        guard status == noErr else { throw BrowserOutputTapError(operation: operation, status: status) }
    }
}
