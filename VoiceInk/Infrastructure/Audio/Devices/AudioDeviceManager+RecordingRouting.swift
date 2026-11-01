import CoreAudio
import Foundation
import os

struct RecordingDeviceResolution {
    let deviceID: AudioDeviceID?
    let internalMicrophoneBlockedByClosedLid: Bool
}

/// The CoreAudio properties that recording-device resolution reads, queried together for `deviceIDs`.
struct RecordingDeviceProperties: Sendable {
    let deviceIDs: [AudioDeviceID]
    let systemDefaultDeviceID: AudioDeviceID?
    let transports: [AudioDeviceID: AudioInputTransport]
    let internalMicrophoneIDs: Set<AudioDeviceID>
    let modelUIDs: [AudioDeviceID: String]
}

struct RecordingDeviceSession {
    var isActive = false
    var activeDeviceID: AudioDeviceID?
    var isDeviceChangePending = false
}

enum RecordingDeviceChangeReason: Equatable {
    case closedLid
    case deviceUnavailable
    case userSelection
}

struct RecordingDeviceChangeRequest {
    let fallbackDeviceID: AudioDeviceID?
    let reason: RecordingDeviceChangeReason
}

extension AudioDeviceManager {
    func setupRecordingDeviceRouting() {
        clamshellStateMonitor = ClamshellStateMonitor { [weak self] isClosed in
            self?.handleClamshellChange(isClosed: isClosed)
        }
    }

    func beginRecordingSetup(deviceID: AudioDeviceID) {
        recordingDeviceSession.isActive = true
        recordingDeviceSession.activeDeviceID = deviceID
    }

    func recordingDidStart(deviceID: AudioDeviceID) {
        recordingDeviceSession.isActive = true
        recordingDeviceSession.activeDeviceID = deviceID
    }

    func recordingDeviceChangeFinished(activeDeviceID: AudioDeviceID? = nil) {
        if let activeDeviceID {
            recordingDeviceSession.activeDeviceID = activeDeviceID
        }
        recordingDeviceSession.isDeviceChangePending = false
    }

    func recordingDidStop() {
        recordingDeviceSession = RecordingDeviceSession()
        reconcileInputAvailability()
    }

    func resolveCurrentRecordingDevice(
        excluding excludedDeviceID: AudioDeviceID? = nil
    ) -> RecordingDeviceResolution {
        let preferredCandidates = preferredRecordingDeviceIDs()
        let preferredAvailableDevice = preferredCandidates.first(where: isOperationalInputDevice)
        let internalMicrophoneBlockedByClosedLid = isClamshellClosed
            && preferredAvailableDevice.map(routingIsInternalMicrophone) == true

        var seen = Set<AudioDeviceID>()
        let candidates = (preferredCandidates + fallbackRecordingDeviceIDs()).filter { deviceID in
            guard deviceID != excludedDeviceID else { return false }
            return seen.insert(deviceID).inserted
        }
        let resolvedDeviceID = candidates.first(where: isDeviceUsableForRecording)

        return RecordingDeviceResolution(
            deviceID: resolvedDeviceID,
            internalMicrophoneBlockedByClosedLid: internalMicrophoneBlockedByClosedLid
        )
    }

    /// Each query is a synchronous call into coreaudiod that can take hundreds of milliseconds under load, so
    /// capture readiness fetches off the main thread; overrides of the queried methods must be thread-safe.
    func fetchRecordingDeviceProperties(for deviceIDs: [AudioDeviceID]) -> RecordingDeviceProperties {
        RecordingDeviceProperties(
            deviceIDs: deviceIDs,
            systemDefaultDeviceID: getSystemDefaultDevice(),
            transports: Dictionary(deviceIDs.map { ($0, inputTransport($0)) }, uniquingKeysWith: { first, _ in first }),
            internalMicrophoneIDs: Set(deviceIDs.filter(isInternalMicrophone)),
            modelUIDs: Dictionary(
                deviceIDs.compactMap { id in getDeviceModelUID(deviceID: id).map { (id, $0) } },
                uniquingKeysWith: { first, _ in first }
            )
        )
    }

    func routingSystemDefaultDevice() -> AudioDeviceID? {
        guard let properties = prefetchedRoutingProperties else { return getSystemDefaultDevice() }
        return properties.systemDefaultDeviceID
    }

    func routingTransport(_ deviceID: AudioDeviceID) -> AudioInputTransport {
        prefetchedRoutingProperties?.transports[deviceID] ?? inputTransport(deviceID)
    }

    func routingIsInternalMicrophone(_ deviceID: AudioDeviceID) -> Bool {
        guard let properties = prefetchedRoutingProperties, properties.deviceIDs.contains(deviceID) else {
            return isInternalMicrophone(deviceID)
        }
        return properties.internalMicrophoneIDs.contains(deviceID)
    }

    func routingModelUID(_ deviceID: AudioDeviceID) -> String? {
        guard let properties = prefetchedRoutingProperties, properties.deviceIDs.contains(deviceID) else {
            return getDeviceModelUID(deviceID: deviceID)
        }
        return properties.modelUIDs[deviceID]
    }

    func getCurrentDevice() -> AudioDeviceID {
        if let activeRecordingDeviceID { return activeRecordingDeviceID }
        return resolveCurrentRecordingDevice().deviceID ?? 0
    }

    func findBestAvailableDevice() -> AudioDeviceID? {
        fallbackRecordingDeviceIDs().first(where: isDeviceUsableForRecording)
    }

    func isDeviceUsableForRecording(_ deviceID: AudioDeviceID) -> Bool {
        isPhysicalInputUsable(deviceID) && microphoneRequirementsAreMet(for: deviceID)
    }

    func isPhysicalInputUsable(_ deviceID: AudioDeviceID) -> Bool {
        isOperationalInputDevice(deviceID)
            && !(isClamshellClosed && routingIsInternalMicrophone(deviceID))
    }

    private func preferredRecordingDeviceIDs() -> [AudioDeviceID] {
        let automatic = automaticRecordingDeviceIDs()
        guard let temporaryMicrophone,
            let device = findAvailableDevice(uid: temporaryMicrophone.uid, modelUID: temporaryMicrophone.modelUID)
        else { return automatic }
        return [device.id] + automatic
    }

    func automaticRecordingDeviceIDs() -> [AudioDeviceID] {
        switch inputMode {
        case .systemDefault:
            guard let defaultDeviceID = routingSystemDefaultDevice() else { return [] }
            return bluetoothDefaultStandInIDs(for: defaultDeviceID) + [defaultDeviceID]
        case .custom:
            let savedUID = userDefaults.selectedAudioDeviceUID ?? ""
            let savedModelUID = userDefaults.selectedAudioDeviceModelUID
            return findAvailableDevice(uid: savedUID, modelUID: savedModelUID).map { [$0.id] } ?? []
        case .prioritized:
            return prioritizedDevices.sorted { $0.priority < $1.priority }.compactMap { device in
                findAvailableDevice(uid: device.id, modelUID: device.modelUID)?.id
            }
        }
    }

    /// The inputs the saved mode names. Bluetooth stand-ins are excluded, so their arrival is an unrelated change
    /// that keeps a temporary selection.
    func preferredMicrophoneIDs() -> [AudioDeviceID] {
        guard inputMode == .systemDefault else { return automaticRecordingDeviceIDs() }
        return routingSystemDefaultDevice().map { [$0] } ?? []
    }

    var bluetoothDefaultSubstitution: BluetoothMicrophoneSubstitution? {
        guard inputMode == .systemDefault, temporaryMicrophone == nil,
            let defaultDeviceID = getSystemDefaultDevice(),
            !bluetoothDefaultStandInIDs(for: defaultDeviceID).isEmpty
        else { return nil }
        let currentDeviceID = getCurrentDevice()
        guard currentDeviceID != defaultDeviceID,
            let bluetoothName = availableDevices.first(where: { $0.id == defaultDeviceID })?.name,
            let standInName = availableDevices.first(where: { $0.id == currentDeviceID })?.name
        else { return nil }
        return BluetoothMicrophoneSubstitution(bluetoothName: bluetoothName, standInName: standInName)
    }

    /// A Bluetooth system default yields to the internal microphone, else another real input; it remains the
    /// last automatic candidate, so it is kept when no stand-in is usable.
    private func bluetoothDefaultStandInIDs(for defaultDeviceID: AudioDeviceID) -> [AudioDeviceID] {
        guard avoidsBluetoothDefaultMicrophone, isOperationalInputDevice(defaultDeviceID),
            routingTransport(defaultDeviceID) == .bluetooth
        else { return [] }
        return rankedFallbackDevices().filter {
            $0.rank <= .otherInput && isDeviceUsableForRecording($0.id)
        }.map(\.id)
    }

    private enum FallbackRank: Int, Comparable {
        case internalMicrophone, otherInput, bluetooth, unconfiguredVirtual, closedLidInternalMicrophone

        static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    private func fallbackRank(_ deviceID: AudioDeviceID) -> FallbackRank {
        if routingIsInternalMicrophone(deviceID) {
            return isClamshellClosed ? .closedLidInternalMicrophone : .internalMicrophone
        }
        guard avoidsBluetoothDefaultMicrophone else { return .otherInput }
        switch routingTransport(deviceID) {
        case .bluetooth: return .bluetooth
        case .virtual: return hasMicrophoneRequirements(deviceID) ? .otherInput : .unconfiguredVirtual
        case .builtIn, .other: return .otherInput
        }
    }

    private func rankedFallbackDevices() -> [(id: AudioDeviceID, rank: FallbackRank)] {
        let ranked = availableDevices.map { (id: $0.id, rank: fallbackRank($0.id)) }
        return ranked.enumerated().sorted {
            ($0.element.rank, $0.offset) < ($1.element.rank, $1.offset)
        }.map(\.element)
    }

    private func fallbackRecordingDeviceIDs() -> [AudioDeviceID] {
        rankedFallbackDevices().map(\.id)
    }

    func isOperationalInputDevice(_ deviceID: AudioDeviceID) -> Bool {
        availableDevices.contains { $0.id == deviceID }
    }

    func handleClamshellChange(isClosed: Bool) {
        logger.notice("Clamshell state changed: \(isClosed ? "closed" : "open", privacy: .public)")

        reconcileInputAvailability(reason: isClosed ? .closedLid : .deviceUnavailable)
    }

    /// A quick-menu choice applies to an active recording too, through the coalesced switch that keeps its WAV.
    func moveActiveRecordingToResolvedInput() {
        guard isRecordingActive, let activeDeviceID = activeRecordingDeviceID,
            let resolvedDeviceID = resolveCurrentRecordingDevice().deviceID, resolvedDeviceID != activeDeviceID
        else { return }
        requestRecordingDeviceChange(reason: .userSelection)
    }

    func requestRecordingDeviceChange(reason: RecordingDeviceChangeReason) {
        guard let activeDeviceID = activeRecordingDeviceID,
            !recordingDeviceSession.isDeviceChangePending
        else {
            return
        }

        recordingDeviceSession.isDeviceChangePending = true
        let request = RecordingDeviceChangeRequest(
            fallbackDeviceID: resolveCurrentRecordingDevice(excluding: activeDeviceID).deviceID,
            reason: reason
        )
        notificationCenter.post(
            name: .recordingDeviceChangeRequired,
            object: request
        )
    }
}
