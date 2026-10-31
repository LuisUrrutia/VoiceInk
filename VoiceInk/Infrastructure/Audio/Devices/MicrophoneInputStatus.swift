import CoreAudio
import Foundation

/// The input VoiceInk records from and, when it is not the one the saved setting names, why.
/// Only one note shows, so the Audio settings and the toolbar never give contradicting reasons.
struct MicrophoneInputStatus: Equatable {
    enum Note: Equatable {
        /// A recording keeps its input; the newly resolved one takes over once it stops.
        case switchesAfterRecording(name: String)
        /// The saved Custom microphone, or a priority entry ranked above the input in use, is absent.
        case notConnected(savedName: String?)
        case closedLid
        case bluetooth(BluetoothMicrophoneSubstitution)
    }

    let inputName: String?
    let note: Note?

    var message: String? {
        switch note {
        case nil:
            return nil
        case .switchesAfterRecording(let name):
            return String(localized: "VoiceInk switches to \(name) after this recording")
        case .notConnected(let savedName?):
            guard let inputName else {
                return String(localized: "\(savedName) isn't connected, and no other microphone is available")
            }
            return String(localized: "\(savedName) isn't connected; using \(inputName)")
        case .notConnected(nil):
            guard let inputName else {
                return String(localized: "The selected microphone isn't connected, and no other microphone is available")
            }
            return String(localized: "The selected microphone isn't connected; using \(inputName)")
        case .closedLid:
            guard let inputName else {
                return String(localized: "The lid is closed, and no other microphone is available")
            }
            return String(localized: "The lid is closed, so VoiceInk listens to \(inputName)")
        case .bluetooth(let substitution):
            return substitution.message
        }
    }
}

extension AudioDeviceManager {
    var microphoneInputStatus: MicrophoneInputStatus {
        let currentDeviceID = getCurrentDevice()
        let inputName = availableDevices.first { $0.id == currentDeviceID }?.name
        return MicrophoneInputStatus(inputName: inputName, note: microphoneInputNote(currentDeviceID: currentDeviceID))
    }

    /// Saved microphones that are absent: the Custom choice, or every priority entry. Menus keep them listed.
    var savedMicrophonesNotConnected: [String] {
        switch inputMode {
        case .systemDefault:
            return []
        case .custom:
            guard let uid = userDefaults.selectedAudioDeviceUID,
                findAvailableDevice(uid: uid, modelUID: userDefaults.selectedAudioDeviceModelUID) == nil
            else { return [] }
            return [userDefaults.selectedAudioDeviceName ?? String(localized: "Selected Microphone")]
        case .prioritized:
            return prioritizedDevices.sorted { $0.priority < $1.priority }
                .filter { findAvailableDevice(uid: $0.id, modelUID: $0.modelUID) == nil }
                .map(\.name)
        }
    }

    private func microphoneInputNote(currentDeviceID: AudioDeviceID) -> MicrophoneInputStatus.Note? {
        let resolution = resolveCurrentRecordingDevice()
        if let activeRecordingDeviceID, !recordingDeviceSession.isDeviceChangePending,
            let resolvedID = resolution.deviceID, resolvedID != activeRecordingDeviceID,
            let name = availableDevices.first(where: { $0.id == resolvedID })?.name
        {
            return .switchesAfterRecording(name: name)
        }
        guard temporaryMicrophone == nil else { return nil }
        if let notConnected = savedMicrophoneNotConnected(rankedBefore: currentDeviceID) {
            return notConnected
        }
        if resolution.internalMicrophoneBlockedByClosedLid {
            return .closedLid
        }
        return bluetoothDefaultSubstitution.map(MicrophoneInputStatus.Note.bluetooth)
    }

    private func savedMicrophoneNotConnected(rankedBefore currentDeviceID: AudioDeviceID) -> MicrophoneInputStatus.Note? {
        switch inputMode {
        case .systemDefault:
            return nil
        case .custom:
            guard let uid = userDefaults.selectedAudioDeviceUID,
                findAvailableDevice(uid: uid, modelUID: userDefaults.selectedAudioDeviceModelUID) == nil
            else { return nil }
            return .notConnected(savedName: userDefaults.selectedAudioDeviceName)
        case .prioritized:
            for entry in prioritizedDevices.sorted(by: { $0.priority < $1.priority }) {
                guard let device = findAvailableDevice(uid: entry.id, modelUID: entry.modelUID) else {
                    return .notConnected(savedName: entry.name)
                }
                if device.id == currentDeviceID { return nil }
            }
            return nil
        }
    }
}
