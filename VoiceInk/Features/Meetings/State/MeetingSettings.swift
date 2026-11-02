import Foundation

extension LabsFeature {
    static let meetings = LabsFeature(
        id: "meetings",
        title: "Meetings",
        summary: "Record calls with your microphone and the other participants' audio, then transcribe them on this Mac."
    )
}

enum MeetingSettings {
    static let outputFolderKey = "MeetingsOutputFolder"
    static let showsRecordingIndicatorKey = "MeetingsShowsRecordingIndicator"

    static var registeredDefaults: [String: Any] {
        [showsRecordingIndicatorKey: true]
    }

    /// Each build keeps its own folder, like its other persistence.
    static var defaultFolderName: String {
        #if LOCAL_BUILD
            "VoiceInk Local Meetings"
        #elseif DEBUG
            "VoiceInk Dev Meetings"
        #else
            "VoiceInk Meetings"
        #endif
    }

    static var defaultOutputFolder: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(defaultFolderName, isDirectory: true)
    }

    /// The saved folder when it is an absolute path, else the default.
    static func outputFolder(in defaults: UserDefaults = .standard) -> URL {
        guard let path = defaults.string(forKey: outputFolderKey), path.hasPrefix("/") else { return defaultOutputFolder }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    static func setOutputFolder(_ url: URL?, in defaults: UserDefaults = .standard) {
        if let url {
            defaults.set(url.path, forKey: outputFolderKey)
        } else {
            defaults.removeObject(forKey: outputFolderKey)
        }
    }

    static func showsRecordingIndicator(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: showsRecordingIndicatorKey) as? Bool ?? true
    }

    /// Fields of General backups; a missing field keeps the current value.
    struct Backup: Codable, Equatable {
        var outputFolder: String?
        var showsRecordingIndicator: Bool?

        static func capture(from defaults: UserDefaults = .standard) -> Backup {
            Backup(
                outputFolder: defaults.string(forKey: outputFolderKey),
                showsRecordingIndicator: MeetingSettings.showsRecordingIndicator(in: defaults)
            )
        }

        func restore(in defaults: UserDefaults = .standard) {
            if let outputFolder, outputFolder.hasPrefix("/") { defaults.set(outputFolder, forKey: outputFolderKey) }
            if let showsRecordingIndicator { defaults.set(showsRecordingIndicator, forKey: showsRecordingIndicatorKey) }
        }
    }
}
