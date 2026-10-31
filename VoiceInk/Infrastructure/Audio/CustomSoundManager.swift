import AVFoundation
import Foundation
import SwiftUI

class CustomSoundManager: ObservableObject {
    static let shared = CustomSoundManager()
    static let soundsDidChange = NSNotification.Name("CustomSoundsChanged")

    enum BuiltInSound: String, CaseIterable, Identifiable {
        case sound1
        case sound2
        case sound3
        case sound4
        case sound5
        case sound6
        case sound7
        /// Hex's Classic start sound; see `Resources/Licenses/Hex-LICENSE.txt`.
        case hexClassicStart
        case softTone
        case basso

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .hexClassicStart:
                return "Hex Classic"
            case .softTone:
                return String(localized: "Soft Tone")
            case .basso:
                return "Basso"
            default:
                return String(localized: "Sound \(number)")
            }
        }

        var url: URL? {
            switch self {
            case .basso:
                let url = URL(fileURLWithPath: "/System/Library/Sounds/Basso.aiff")
                return FileManager.default.fileExists(atPath: url.path) ? url : nil
            default:
                return Bundle.main.url(forResource: resourceName, withExtension: fileExtension)
                    ?? Bundle.main.url(forResource: resourceName, withExtension: fileExtension, subdirectory: "Sounds")
            }
        }

        /// Levels the newer sounds with Sound 5 and Sound 6 at their long-standing 0.3 volume.
        var playbackVolume: Float {
            switch self {
            case .softTone:
                return 0.45
            case .basso:
                return 0.55
            default:
                return 0.3
            }
        }

        private var resourceName: String {
            self == .softTone ? "soft-done" : rawValue
        }

        private var fileExtension: String {
            switch self {
            case .sound5, .sound6:
                return "mp3"
            case .basso:
                return "aiff"
            default:
                return "wav"
            }
        }

        private var number: Int {
            Int(rawValue.replacingOccurrences(of: "sound", with: "")) ?? 0
        }
    }

    enum SoundType: String, CaseIterable {
        case start
        case stop
        case done
        case error

        var selectionKey: String { "selected\(rawValue.capitalized)SoundSelection" }
        var filenameKey: String { "custom\(rawValue.capitalized)SoundFilename" }
        var builtInSoundKey: String { "selected\(rawValue.capitalized)BuiltInSound" }
        var standardName: String { "Custom\(rawValue.capitalized)Sound" }
        var defaultBuiltInSound: BuiltInSound {
            switch self {
            case .start:
                return .hexClassicStart
            case .stop:
                return .sound6
            case .done:
                return .softTone
            case .error:
                return .basso
            }
        }
    }

    enum SoundSelection: Equatable {
        case none
        case builtIn(BuiltInSound)
        case custom(String)

        var isEnabled: Bool {
            self != .none
        }

        var isCustom: Bool {
            if case .custom = self {
                return true
            }
            return false
        }

        fileprivate var storageValue: String {
            switch self {
            case .none:
                return "none"
            case .builtIn:
                return "builtIn"
            case .custom:
                return "custom"
            }
        }
    }

    private let maxSoundDuration: TimeInterval = 3.0
    private let defaults: UserDefaults
    private let customSoundsDirectory: URL?

    @Published private var selections: [SoundType: SoundSelection] = [:]
    private var builtInSounds: [SoundType: BuiltInSound] = [:]
    private var customFilenames: [SoundType: String] = [:]

    init(
        defaults: UserDefaults = .standard,
        customSoundsDirectory: URL? = CustomSoundManager.applicationSupportSoundsDirectory
    ) {
        self.defaults = defaults
        self.customSoundsDirectory = customSoundsDirectory
        let legacySoundFeedbackEnabled = defaults.object(forKey: "isSoundFeedbackEnabled")
            .map { _ in defaults.bool(forKey: "isSoundFeedbackEnabled") }

        for type in SoundType.allCases {
            let builtInSound = Self.savedBuiltInSound(for: type, in: defaults)
            let customFilename = defaults.string(forKey: type.filenameKey)
            builtInSounds[type] = builtInSound
            customFilenames[type] = customFilename
            selections[type] = Self.savedSoundSelection(
                for: type,
                in: defaults,
                builtInSound: builtInSound,
                customFilename: customFilename,
                legacySoundFeedbackEnabled: legacySoundFeedbackEnabled
            )
        }

        createCustomSoundsDirectoryIfNeeded()
        for type in SoundType.allCases {
            saveSoundSelection(soundSelection(for: type), for: type)
        }
    }

    private static func savedSoundSelection(
        for type: SoundType,
        in defaults: UserDefaults,
        builtInSound: BuiltInSound,
        customFilename: String?,
        legacySoundFeedbackEnabled: Bool?
    ) -> SoundSelection {
        switch defaults.string(forKey: type.selectionKey) {
        case "none":
            return .none
        case "custom":
            return customFilename.map(SoundSelection.custom) ?? .builtIn(builtInSound)
        case nil:
            guard let legacySoundFeedbackEnabled else {
                return .builtIn(builtInSound)
            }
            return legacySoundFeedbackEnabled ? .builtIn(builtInSound) : .none
        default:
            return .builtIn(builtInSound)
        }
    }

    private static func savedBuiltInSound(for type: SoundType, in defaults: UserDefaults) -> BuiltInSound {
        if let rawValue = defaults.string(forKey: type.builtInSoundKey),
            let sound = BuiltInSound(rawValue: rawValue)
        {
            return sound
        }

        return type.defaultBuiltInSound
    }

    static var applicationSupportSoundsDirectory: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("VoiceInk/CustomSounds")
    }

    private func createCustomSoundsDirectoryIfNeeded() {
        guard let directory = customSoundsDirectory else { return }

        if !FileManager.default.fileExists(atPath: directory.path) {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    func getCustomSoundURL(for type: SoundType) -> URL? {
        guard case .custom(let filename) = soundSelection(for: type),
            let directory = customSoundsDirectory
        else {
            return nil
        }
        return directory.appendingPathComponent(filename)
    }

    /// The built-in sound to play, which is also the fallback for a custom sound that fails to load.
    func builtInSound(for type: SoundType) -> BuiltInSound? {
        switch soundSelection(for: type) {
        case .none:
            return nil
        case .builtIn(let sound):
            return sound
        case .custom:
            return storedBuiltInSound(for: type)
        }
    }

    var hasAnyRecordingSoundEnabled: Bool {
        isSoundEnabled(for: .start) || isSoundEnabled(for: .stop)
    }

    func isSoundEnabled(for type: SoundType) -> Bool {
        soundSelection(for: type).isEnabled
    }

    func soundSelection(for type: SoundType) -> SoundSelection {
        selections[type] ?? .builtIn(type.defaultBuiltInSound)
    }

    private func storedBuiltInSound(for type: SoundType) -> BuiltInSound {
        builtInSounds[type] ?? type.defaultBuiltInSound
    }

    private func setSoundSelection(_ selection: SoundSelection, for type: SoundType) {
        selections[type] = selection
        saveSoundSelection(selection, for: type)
    }

    private func setStoredBuiltInSound(_ sound: BuiltInSound, for type: SoundType) {
        builtInSounds[type] = sound
        defaults.set(sound.rawValue, forKey: type.builtInSoundKey)
    }

    private func setCustomFilename(_ filename: String?, for type: SoundType) {
        customFilenames[type] = filename
        if let filename {
            defaults.set(filename, forKey: type.filenameKey)
        } else {
            defaults.removeObject(forKey: type.filenameKey)
        }
    }

    private func saveSoundSelection(_ selection: SoundSelection, for type: SoundType) {
        defaults.set(selection.storageValue, forKey: type.selectionKey)
    }

    func selectNoSound(for type: SoundType) {
        setSoundSelection(.none, for: type)
        notifyCustomSoundsChanged()
    }

    func selectBuiltInSound(_ sound: BuiltInSound, for type: SoundType) {
        setStoredBuiltInSound(sound, for: type)
        setSoundSelection(.builtIn(sound), for: type)
        notifyCustomSoundsChanged()
    }

    func useCustomSound(for type: SoundType) {
        guard let filename = getSoundDisplayName(for: type) else { return }
        setSoundSelection(.custom(filename), for: type)

        notifyCustomSoundsChanged()
    }

    @MainActor
    func setCustomSound(url: URL, for type: SoundType) async -> Result<Void, CustomSoundError> {
        let result = await validateAudioFile(url: url)
        switch result {
        case .success:
            let copyResult = copySoundFile(from: url, standardName: type.standardName)
            switch copyResult {
            case .success(let filename):
                setCustomFilename(filename, for: type)
                setSoundSelection(.custom(filename), for: type)
                notifyCustomSoundsChanged()
                return .success(())
            case .failure(let error):
                return .failure(error)
            }
        case .failure(let error):
            return .failure(error)
        }
    }

    func resetSoundToDefault(for type: SoundType) {
        if let filename = customFilenames[type], let directory = customSoundsDirectory {
            let fileURL = directory.appendingPathComponent(filename)
            try? FileManager.default.removeItem(at: fileURL)
        }

        setStoredBuiltInSound(type.defaultBuiltInSound, for: type)
        setCustomFilename(nil, for: type)
        setSoundSelection(.builtIn(type.defaultBuiltInSound), for: type)
        notifyCustomSoundsChanged()
    }

    private func notifyCustomSoundsChanged() {
        NotificationCenter.default.post(name: Self.soundsDidChange, object: self)
    }

    func getSoundDisplayName(for type: SoundType) -> String? {
        customFilenames[type]
    }

    func isDefaultSelection(for type: SoundType) -> Bool {
        soundSelection(for: type) == .builtIn(type.defaultBuiltInSound)
    }

    // MARK: - Backup

    struct SoundBackup: Codable, Equatable {
        let selection: String
        let builtInSound: String?
        let customFilename: String?
    }

    func backup() -> [String: SoundBackup] {
        Dictionary(uniqueKeysWithValues: SoundType.allCases.map { type in
            (type.rawValue, SoundBackup(
                selection: soundSelection(for: type).storageValue,
                builtInSound: storedBuiltInSound(for: type).rawValue,
                customFilename: customFilenames[type]
            ))
        })
    }

    /// Applies the sound types present in a backup. A custom sound whose file is not on this Mac uses its built-in sound.
    func restore(_ backups: [String: SoundBackup]) {
        for (rawType, backup) in backups {
            guard let type = SoundType(rawValue: rawType) else { continue }
            if let sound = backup.builtInSound.flatMap(BuiltInSound.init(rawValue:)) {
                setStoredBuiltInSound(sound, for: type)
            }
            switch backup.selection {
            case "none":
                setSoundSelection(.none, for: type)
            case "builtIn":
                setSoundSelection(.builtIn(storedBuiltInSound(for: type)), for: type)
            case "custom":
                if let filename = backup.customFilename,
                    let directory = customSoundsDirectory,
                    FileManager.default.fileExists(atPath: directory.appendingPathComponent(filename).path)
                {
                    setCustomFilename(filename, for: type)
                    setSoundSelection(.custom(filename), for: type)
                } else {
                    setSoundSelection(.builtIn(storedBuiltInSound(for: type)), for: type)
                }
            default:
                continue
            }
        }
        notifyCustomSoundsChanged()
    }

    private func copySoundFile(from sourceURL: URL, standardName: String) -> Result<String, CustomSoundError> {
        guard let directory = customSoundsDirectory else {
            return .failure(.directoryCreationFailed)
        }

        let fileExtension = sourceURL.pathExtension
        let newFilename = "\(standardName).\(fileExtension)"
        let destinationURL = directory.appendingPathComponent(newFilename)

        if sourceURL.resolvingSymlinksInPath() == destinationURL.resolvingSymlinksInPath() {
            return .success(newFilename)
        }

        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try? FileManager.default.removeItem(at: destinationURL)
        }

        do {
            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
            return .success(newFilename)
        } catch {
            return .failure(.fileCopyFailed)
        }
    }

    private func validateAudioFile(url: URL) async -> Result<Void, CustomSoundError> {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .failure(.fileNotFound)
        }

        do {
            _ = try AVAudioPlayer(contentsOf: url)
        } catch {
            return .failure(.invalidAudioFile)
        }

        let duration: TimeInterval
        do {
            duration = try await AVAsset(url: url).load(.duration).seconds
        } catch {
            return .failure(.invalidAudioFile)
        }

        guard duration.isFinite && duration > 0 else {
            return .failure(.invalidAudioFile)
        }

        if duration > maxSoundDuration {
            return .failure(.durationTooLong(duration: duration, maxDuration: maxSoundDuration))
        }

        return .success(())
    }
}

enum CustomSoundError: LocalizedError {
    case fileNotFound
    case invalidAudioFile
    case durationTooLong(duration: TimeInterval, maxDuration: TimeInterval)
    case directoryCreationFailed
    case fileCopyFailed

    var errorDescription: String? {
        switch self {
        case .fileNotFound:
            return String(localized: "Audio file not found")
        case .invalidAudioFile:
            return String(localized: "Invalid audio file format")
        case .durationTooLong(let duration, let maxDuration):
            return String(
                format: String(
                    localized:
                        "Audio file is %.1f seconds long. Please use an audio file that is %.0f seconds or shorter for feedback sounds."
                ), duration, maxDuration)
        case .directoryCreationFailed:
            return String(localized: "Failed to create custom sounds directory")
        case .fileCopyFailed:
            return String(localized: "Failed to copy audio file")
        }
    }
}
