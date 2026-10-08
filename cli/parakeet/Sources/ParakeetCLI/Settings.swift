import Foundation
import TranscriptionText

enum AppNamespace: String {
    case production, development, local
    var domain: String {
        switch self {
        case .production, .local: return VoiceInkPersistence.productionDirectoryName
        case .development: return VoiceInkPersistence.productionDirectoryName + ".dev"
        }
    }
    var storeDirectoryName: String {
        VoiceInkPersistence.directoryName(bundleIdentifier: domain, isLocalBuild: self == .local)
    }
}

struct Settings {
    var vadEnabled: Bool
    var formatEnabled: Bool
    var language: String
    var fillerWords: [String]
    var replacements = WordReplacementPlan(rules: [])

    init(preferences: [String: Any] = [:]) {
        let values = preferences.merging(TranscriptionTextDefaults.preferences) { saved, _ in saved }
        vadEnabled = values["IsVADEnabled"] as? Bool ?? true
        formatEnabled = values["IsTextFormattingEnabled"] as? Bool ?? true
        language = values["SelectedLanguage"] as? String ?? "en"
        fillerWords = values["FillerWords"] as? [String] ?? TranscriptionTextDefaults.fillerWords
    }

    static func load(_ options: Options) throws -> Settings {
        let preferences: [String: Any]
        if let url = options.preferences {
            guard let values = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any] else {
                throw CLIError.message("Preferences must be a dictionary plist")
            }
            preferences = values
        } else {
            // One domain snapshot, no registration, synchronization, or writes.
            preferences = CFPreferencesCopyMultiple(nil, options.namespace.domain as CFString,
                                                    kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String: Any] ?? [:]
        }
        var settings = Settings(preferences: preferences)
        if options.noVAD { settings.vadEnabled = false }
        if options.noFormat { settings.formatEnabled = false }
        if options.keepFillers { settings.fillerWords = [] }
        if let language = options.language { settings.language = language }
        if options.model == "v2" { settings.language = "en" }
        if !options.noReplacements, let url = options.dictionary {
            settings.replacements = try dictionaryPlan(from: url)
        }
        return settings
    }

    static func dictionaryPlan(from url: URL) throws -> WordReplacementPlan {
        struct Archive: Decodable {
            struct Entry: Decodable {
                let sources: [String]
                let replacement: String
                let createdAt: Date?
                let enabled: Bool?
            }
            let format: String
            let schemaVersion: Int
            let replacements: [Entry]
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let archive = try decoder.decode(Archive.self, from: Data(contentsOf: url))
        guard archive.format == "voiceink.dictionary", (1...2).contains(archive.schemaVersion) else {
            throw CLIError.message("Unsupported VoiceInk Dictionary export")
        }
        return WordReplacementPlan(rules: archive.replacements.enumerated().map { index, entry in
            ReplacementRule(id: String(index), sources: entry.sources.filter { !$0.isEmpty },
                            replacement: entry.replacement, dateAdded: entry.createdAt ?? .distantPast,
                            enabled: entry.enabled ?? true)
        })
    }

    func process(_ text: String, paragraphs: Bool = true) -> String {
        let filtered = TranscriptionTextFilter.filter(text, fillerWords: fillerWords)
        return replacements.apply(to: paragraphs && formatEnabled ? ParagraphFormatter.format(filtered) : filtered)
    }
}
