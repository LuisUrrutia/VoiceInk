import CoreAudio
import Foundation

/// A saved Custom microphone or priority entry that is not connected, identified by its device UID.
struct SavedMicrophone: Equatable, Identifiable {
    let id: String
    let name: String
}

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

    /// The active recording's input, else the input the next recording resolves to.
    var inputName: String?
    /// The usable input that routing resolves to; nil when no input is usable, even while a recording keeps one.
    var standInName: String?
    var note: Note?
    /// Menus keep these listed as not connected.
    var notConnected: [SavedMicrophone] = []

    var message: String? {
        switch note {
        case nil:
            return nil
        case .switchesAfterRecording(let name):
            return String(localized: "VoiceInk switches to \(name) after this recording")
        case .notConnected(let savedName?):
            guard let standInName else {
                return String(localized: "\(savedName) isn't connected, and no other microphone is available")
            }
            return String(localized: "\(savedName) isn't connected; using \(standInName)")
        case .notConnected(nil):
            guard let standInName else {
                return String(localized: "The selected microphone isn't connected, and no other microphone is available")
            }
            return String(localized: "The selected microphone isn't connected; using \(standInName)")
        case .closedLid:
            guard let standInName else {
                return String(localized: "The lid is closed, and no other microphone is available")
            }
            return String(localized: "The lid is closed, so VoiceInk listens to \(standInName)")
        case .bluetooth(let substitution):
            return substitution.message
        }
    }
}

extension AudioDeviceManager {
    /// Queries CoreAudio on the calling thread; interface code reads `MicrophoneInputStatusMonitor` instead.
    var microphoneInputStatus: MicrophoneInputStatus { makeMicrophoneInputStatus() }

    /// Computes the status from `properties`, fetched for the current `availableDevices`, without querying CoreAudio.
    func microphoneInputStatus(using properties: RecordingDeviceProperties) -> MicrophoneInputStatus {
        withPrefetchedRoutingProperties(properties) { makeMicrophoneInputStatus() }
    }

    private func makeMicrophoneInputStatus() -> MicrophoneInputStatus {
        let resolution = resolveCurrentRecordingDevice()
        let currentDeviceID = activeRecordingDeviceID ?? resolution.deviceID
        func name(_ deviceID: AudioDeviceID?) -> String? {
            deviceID.flatMap { id in availableDevices.first { $0.id == id }?.name }
        }
        return MicrophoneInputStatus(
            inputName: name(currentDeviceID),
            standInName: name(resolution.deviceID),
            note: microphoneInputNote(currentDeviceID: currentDeviceID, resolution: resolution),
            notConnected: savedMicrophonesNotConnected
        )
    }

    /// Saved microphones that are absent: the Custom choice, or every priority entry.
    private var savedMicrophonesNotConnected: [SavedMicrophone] {
        switch inputMode {
        case .systemDefault:
            return []
        case .custom:
            guard let uid = userDefaults.selectedAudioDeviceUID,
                findAvailableDevice(uid: uid, modelUID: userDefaults.selectedAudioDeviceModelUID) == nil
            else { return [] }
            return [SavedMicrophone(
                id: uid, name: userDefaults.selectedAudioDeviceName ?? String(localized: "Selected Microphone")
            )]
        case .prioritized:
            return prioritizedDevices.sorted { $0.priority < $1.priority }
                .filter { findAvailableDevice(uid: $0.id, modelUID: $0.modelUID) == nil }
                .map { SavedMicrophone(id: $0.id, name: $0.name) }
        }
    }

    private func microphoneInputNote(
        currentDeviceID: AudioDeviceID?, resolution: RecordingDeviceResolution
    ) -> MicrophoneInputStatus.Note? {
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
        return currentDeviceID.flatMap(bluetoothDefaultSubstitution(currentDeviceID:))
            .map(MicrophoneInputStatus.Note.bluetooth)
    }

    private func savedMicrophoneNotConnected(rankedBefore currentDeviceID: AudioDeviceID?) -> MicrophoneInputStatus.Note? {
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
