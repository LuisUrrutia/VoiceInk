import CoreAudio
import Foundation
import os

struct RecordingDeviceResolution {
    let deviceID: AudioDeviceID?
    let internalMicrophoneBlockedByClosedLid: Bool
}

struct RecordingDeviceSession {
    var isActive = false
    var activeDeviceID: AudioDeviceID?
    var isDeviceChangePending = false
}

enum RecordingDeviceChangeReason: Equatable {
    case closedLid
    case deviceUnavailable
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
            && preferredAvailableDevice.map(isInternalMicrophone) == true

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
            && !(isClamshellClosed && isInternalMicrophone(deviceID))
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
            guard let defaultDeviceID = getSystemDefaultDevice() else { return [] }
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
        return getSystemDefaultDevice().map { [$0] } ?? []
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
            inputTransport(defaultDeviceID) == .bluetooth
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
        if isInternalMicrophone(deviceID) {
            return isClamshellClosed ? .closedLidInternalMicrophone : .internalMicrophone
        }
        guard avoidsBluetoothDefaultMicrophone else { return .otherInput }
        switch inputTransport(deviceID) {
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
