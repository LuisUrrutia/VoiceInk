import AVFoundation
import Foundation
import SwiftUI

class CustomSoundManager: ObservableObject {
    static let shared = CustomSoundManager()

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

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .hexClassicStart:
                return "Hex Classic"
            default:
                return String(localized: "Sound \(number)")
            }
        }

        var fileExtension: String {
            switch self {
            case .sound1, .sound2, .sound3, .sound4, .sound7, .hexClassicStart:
                return "wav"
            case .sound5, .sound6:
                return "mp3"
            }
        }

        var bundleURL: URL? {
            Bundle.main.url(forResource: rawValue, withExtension: fileExtension)
                ?? Bundle.main.url(forResource: rawValue, withExtension: fileExtension, subdirectory: "Sounds")
        }

        private var number: Int {
            Int(rawValue.replacingOccurrences(of: "sound", with: "")) ?? 0
        }
    }

    enum SoundType: String {
        case start
        case stop

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

    @Published private var startSoundSelection: SoundSelection {
        didSet {
            saveSoundSelection(startSoundSelection, for: .start)
        }
    }

    @Published private var stopSoundSelection: SoundSelection {
        didSet {
            saveSoundSelection(stopSoundSelection, for: .stop)
        }
    }

    private var startBuiltInSound: BuiltInSound {
        didSet { defaults.set(startBuiltInSound.rawValue, forKey: SoundType.start.builtInSoundKey) }
    }

    private var stopBuiltInSound: BuiltInSound {
        didSet { defaults.set(stopBuiltInSound.rawValue, forKey: SoundType.stop.builtInSoundKey) }
    }

    private var customStartSoundFilename: String? {
        didSet { updateFilenameInUserDefaults(filename: customStartSoundFilename, for: .start) }
    }

    private var customStopSoundFilename: String? {
        didSet { updateFilenameInUserDefaults(filename: customStopSoundFilename, for: .stop) }
    }

    private func updateFilenameInUserDefaults(filename: String?, for type: SoundType) {
        if let filename = filename {
            defaults.set(filename, forKey: type.filenameKey)
        } else {
            defaults.removeObject(forKey: type.filenameKey)
        }
    }

    init(
        defaults: UserDefaults = .standard,
        customSoundsDirectory: URL? = CustomSoundManager.applicationSupportSoundsDirectory
    ) {
        self.defaults = defaults
        self.customSoundsDirectory = customSoundsDirectory
        let savedStartBuiltInSound = Self.savedBuiltInSound(for: .start, in: defaults)
        let savedStopBuiltInSound = Self.savedBuiltInSound(for: .stop, in: defaults)
        let savedStartFilename = defaults.string(forKey: SoundType.start.filenameKey)
        let savedStopFilename = defaults.string(forKey: SoundType.stop.filenameKey)
        let legacySoundFeedbackEnabled = defaults.object(forKey: "isSoundFeedbackEnabled")
            .map { _ in defaults.bool(forKey: "isSoundFeedbackEnabled") }

        self.startBuiltInSound = savedStartBuiltInSound
        self.stopBuiltInSound = savedStopBuiltInSound
        self.customStartSoundFilename = savedStartFilename
        self.customStopSoundFilename = savedStopFilename
        self.startSoundSelection = Self.savedSoundSelection(
            for: .start,
            builtInSound: savedStartBuiltInSound,
            customFilename: savedStartFilename,
            legacySoundFeedbackEnabled: legacySoundFeedbackEnabled,
            in: defaults
        )
        self.stopSoundSelection = Self.savedSoundSelection(
            for: .stop,
            builtInSound: savedStopBuiltInSound,
            customFilename: savedStopFilename,
            legacySoundFeedbackEnabled: legacySoundFeedbackEnabled,
            in: defaults
        )

        createCustomSoundsDirectoryIfNeeded()
        saveSoundSelection(startSoundSelection, for: .start)
        saveSoundSelection(stopSoundSelection, for: .stop)
    }

    private static func savedSoundSelection(
        for type: SoundType,
        builtInSound: BuiltInSound,
        customFilename: String?,
        legacySoundFeedbackEnabled: Bool?,
        in defaults: UserDefaults
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

    func builtInSoundURL(for type: SoundType) -> URL? {
        switch soundSelection(for: type) {
        case .none:
            return nil
        case .builtIn(let sound):
            return sound.bundleURL
        case .custom:
            return storedBuiltInSound(for: type).bundleURL
        }
    }

    var hasAnyRecordingSoundEnabled: Bool {
        startSoundSelection.isEnabled || stopSoundSelection.isEnabled
    }

    func isSoundEnabled(for type: SoundType) -> Bool {
        soundSelection(for: type).isEnabled
    }

    func soundSelection(for type: SoundType) -> SoundSelection {
        switch type {
        case .start:
            return startSoundSelection
        case .stop:
            return stopSoundSelection
        }
    }

    private func storedBuiltInSound(for type: SoundType) -> BuiltInSound {
        switch type {
        case .start:
            return startBuiltInSound
        case .stop:
            return stopBuiltInSound
        }
    }

    private func setSoundSelection(_ selection: SoundSelection, for type: SoundType) {
        switch type {
        case .start:
            startSoundSelection = selection
        case .stop:
            stopSoundSelection = selection
        }
    }

    private func saveSoundSelection(_ selection: SoundSelection, for type: SoundType) {
        defaults.set(selection.storageValue, forKey: type.selectionKey)
    }

    func selectNoSound(for type: SoundType) {
        switch type {
        case .start:
            startSoundSelection = .none
        case .stop:
            stopSoundSelection = .none
        }
        notifyCustomSoundsChanged()
    }

    func selectBuiltInSound(_ sound: BuiltInSound, for type: SoundType) {
        switch type {
        case .start:
            startBuiltInSound = sound
            startSoundSelection = .builtIn(sound)
        case .stop:
            stopBuiltInSound = sound
            stopSoundSelection = .builtIn(sound)
        }

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
                if type == .start {
                    customStartSoundFilename = filename
                } else {
                    customStopSoundFilename = filename
                }
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
        let filename = (type == .start) ? customStartSoundFilename : customStopSoundFilename

        if let filename = filename, let directory = customSoundsDirectory {
            let fileURL = directory.appendingPathComponent(filename)
            try? FileManager.default.removeItem(at: fileURL)
        }

        if type == .start {
            startBuiltInSound = type.defaultBuiltInSound
            customStartSoundFilename = nil
            startSoundSelection = .builtIn(type.defaultBuiltInSound)
        } else {
            stopBuiltInSound = type.defaultBuiltInSound
            customStopSoundFilename = nil
            stopSoundSelection = .builtIn(type.defaultBuiltInSound)
        }
        notifyCustomSoundsChanged()
    }

    private func notifyCustomSoundsChanged() {
        NotificationCenter.default.post(name: NSNotification.Name("CustomSoundsChanged"), object: nil)
    }

    func getSoundDisplayName(for type: SoundType) -> String? {
        return (type == .start) ? customStartSoundFilename : customStopSoundFilename
    }

    func isDefaultSelection(for type: SoundType) -> Bool {
        soundSelection(for: type) == .builtIn(type.defaultBuiltInSound)
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
                        "Audio file is %.1f seconds long. Please use an audio file that is %.0f seconds or shorter for start and stop sounds."
                ), duration, maxDuration)
        case .directoryCreationFailed:
            return String(localized: "Failed to create custom sounds directory")
        case .fileCopyFailed:
            return String(localized: "Failed to copy audio file")
        }
    }
}
