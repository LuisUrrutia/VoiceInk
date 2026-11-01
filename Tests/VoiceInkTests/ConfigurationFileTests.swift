import AppKit
import SwiftData
import XCTest
@testable import VoiceInk

@MainActor
final class ConfigurationFileTests: XCTestCase {
    private var directory: URL!
    private var defaults: UserDefaults!
    private var suite: String!
    private var container: ModelContainer!
    private var stores: [ConfigurationFileStore] = []

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("VoiceInkConfig-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        suite = "VoiceInkConfigTests.\(UUID())"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let schema = Schema([VocabularyWord.self, VocabularySection.self, WordReplacement.self, Transcription.self])
        container = try ModelContainer(for: schema, configurations: ModelConfiguration(
            "config", schema: schema, url: directory.appendingPathComponent("data.store"), cloudKitDatabase: .none
        ))
    }

    override func tearDownWithError() throws {
        stores.forEach { $0.stopObserving() }
        stores = []
        container = nil
        defaults.removePersistentDomain(forName: suite)
        defaults = nil
        try FileManager.default.removeItem(at: directory)
    }

    private var file: URL { directory.appendingPathComponent("config.jsonc") }

    private func store(at url: URL? = nil) -> ConfigurationFileStore {
        let result = ConfigurationFileStore(fileURL: url ?? file, defaults: defaults)
        stores.append(result)
        return result
    }

    private func write(_ content: String) throws { try Data(content.utf8).write(to: file) }

    private func root() throws -> [String: ConfigurationValue] {
        try XCTUnwrap(ConfigurationJSON(data: Data(contentsOf: file)).root.value.object)
    }

    func testXDGPathsAndBuildIsolation() {
        let home = URL(fileURLWithPath: "/Users/example")
        for environment in [[:], ["XDG_CONFIG_HOME": ""], ["XDG_CONFIG_HOME": "relative"]] {
            XCTAssertEqual(ConfigurationLocation.fileURL(environment: environment, home: home, variant: .production).path,
                           "/Users/example/.config/voiceink/config.jsonc")
        }
        let environment = ["XDG_CONFIG_HOME": "/tmp/settings with spaces"]
        XCTAssertEqual(ConfigurationLocation.fileURL(environment: environment, home: home, variant: .production).path,
                       "/tmp/settings with spaces/voiceink/config.jsonc")
        XCTAssertEqual(ConfigurationLocation.fileURL(environment: environment, home: home, variant: .development).path,
                       "/tmp/settings with spaces/voiceink/dev/config.jsonc")
        XCTAssertEqual(ConfigurationLocation.fileURL(environment: environment, home: home, variant: .local).path,
                       "/tmp/settings with spaces/voiceink/local/config.jsonc")
    }

    func testJSONCStringsCommentsTrailingCommasAndUnicode() throws {
        let source = #"""
        // title
        {"url": "https://example.test/a//b", "text": "á \\\" /*literal*/", /* block */ "items": [true, null, 3,],}
        """#
        let document = try ConfigurationJSON(data: Data(source.utf8))
        XCTAssertEqual(document.root.value.object?["url"], .string("https://example.test/a//b"))
        XCTAssertEqual(document.root.value.object?["items"], .array([.bool(true), .null, .number(3)]))
        XCTAssertEqual(try document.updating(document.root.value), Data(source.utf8))
    }

    func testJSONCRejectsInvalidFilesAndDuplicateKeys() {
        for source in ["{", "{\"a\":1,\"a\":2}", "/* unfinished", "[1 2]", "{\"a\":true} garbage", "{\"a\":NaN}", "{\"a\":\"unterminated}"] {
            XCTAssertThrowsError(try ConfigurationJSON(data: Data(source.utf8)), source)
        }
    }

    func testJSONCUpdatesLeavesAndAddsMembersWithoutLosingComments() throws {
        for trailing in ["", ","] {
            let source = "// header\n{\n\"preferences\": { /* keep */ \"IsVADEnabled\": true\(trailing)\n// footer\n}\n}"
            let document = try ConfigurationJSON(data: Data(source.utf8))
            let value: ConfigurationValue = .object(["preferences": .object([
                "IsVADEnabled": .bool(false), "SelectedLanguage": .string("es")
            ])])

            let changed = try document.updating(value)

            XCTAssertEqual(try ConfigurationJSON(data: changed).root.value, value)
            let text = String(decoding: changed, as: UTF8.self)
            for comment in ["// header", "/* keep */", "// footer"] { XCTAssertTrue(text.contains(comment)) }
        }
    }

    func testJSONCAddsMembersToCompactAndCommentedObjects() throws {
        for source in [
            "{}", "{\"a\":1}", "{\"a\":1 }", "{\"a\":1,}",
            "{\"a\":1/* retained */}", "{\"a\":1// retained\n}",
            "{\"a\":{\"nested\":\"á\"}}",
        ] {
            let document = try ConfigurationJSON(data: Data(source.utf8))
            let expected: ConfigurationValue = .object(["a": .number(2), "b": .string("added")])

            let changed = try document.updating(expected)

            XCTAssertEqual(try ConfigurationJSON(data: changed).root.value, expected, source)
            if source.contains("retained") {
                XCTAssertTrue(String(decoding: changed, as: UTF8.self).contains("retained"))
            }
        }
    }

    func testAddingAPreferenceToCompactFileSavesAndReloads() throws {
        try write("{\"schemaVersion\":1,\"preferences\":{\"IsVADEnabled\":true}}")
        let service = store()
        service.load(into: container)

        defaults.set("dark", forKey: "AppAppearancePreference")
        service.saveNow()
        defaults.removeObject(forKey: "AppAppearancePreference")
        let reopened = store()
        reopened.load(into: container)

        XCTAssertTrue(service.isReady, service.errorMessage ?? "")
        XCTAssertTrue(reopened.isReady, reopened.errorMessage ?? "")
        XCTAssertEqual(defaults.string(forKey: "AppAppearancePreference"), "dark")
    }

    func testDictionaryEditCapturesCompleteDictionaryWhenOriginallyOmitted() throws {
        let context = ModelContext(container)
        let section = VocabularySection(name: "Technology", sectionDescription: "Names")
        context.insert(section)
        context.insert(VocabularyWord(word: "Retained", sectionID: section.id))
        context.insert(WordReplacement(originalText: "v ink", replacementText: "VoiceInk"))
        try context.save()
        try write("{\"schemaVersion\":1\n}")
        let service = store()
        service.load(into: container)

        context.insert(VocabularyWord(word: "Added", sectionID: section.id))
        try context.save()
        let expected = try ConfigurationDictionary.capture(in: ModelContext(container))
        service.saveNow()
        let reopened = store()
        reopened.load(into: container)

        XCTAssertTrue(service.isReady, service.errorMessage ?? "")
        XCTAssertTrue(reopened.isReady, reopened.errorMessage ?? "")
        XCTAssertEqual(try root()["dictionary"]?.decoded(as: ConfigurationDictionary.self), expected)
        XCTAssertEqual(try ConfigurationDictionary.capture(in: ModelContext(container)), expected)
    }

    func testEditingOmittedLanguagePromptMapPreservesUnchangedLanguages() throws {
        defaults.set(["en": "Keep English names."], forKey: "CustomLanguagePrompts")
        try write("{\"schemaVersion\":1\n}")
        let service = store()
        service.load(into: container)
        let expected = ["en": "Keep English names.", "es": "Keep Spanish names."]

        defaults.set(expected, forKey: "CustomLanguagePrompts")
        service.saveNow()
        defaults.removeObject(forKey: "CustomLanguagePrompts")
        let reopened = store()
        reopened.load(into: container)

        XCTAssertTrue(service.isReady, service.errorMessage ?? "")
        XCTAssertTrue(reopened.isReady, reopened.errorMessage ?? "")
        XCTAssertEqual(defaults.dictionary(forKey: "CustomLanguagePrompts") as? [String: String], expected)
    }

    func testRemovingLanguagePromptSavesAValidMap() throws {
        defaults.set(["en": "English", "es": "Spanish"], forKey: "CustomLanguagePrompts")
        let service = store()
        service.load(into: container)
        service.saveNow()

        defaults.set(["en": "English"], forKey: "CustomLanguagePrompts")
        service.saveNow()
        let reopened = store()
        reopened.load(into: container)

        XCTAssertTrue(service.isReady, service.errorMessage ?? "")
        XCTAssertTrue(reopened.isReady, reopened.errorMessage ?? "")
        XCTAssertEqual(try root()["preferences"]?.object?["CustomLanguagePrompts"], .object(["en": .string("English")]))
    }

    func testUnsafeShortcutRejectsTheCompleteFileBeforeAnyMutation() throws {
        for shortcut in [Shortcut.key(keyCode: 0, modifierFlags: []), .key(keyCode: 8, modifierFlags: .command)] {
            defaults.set(true, forKey: "IsVADEnabled")
            let context = ModelContext(container)
            context.insert(VocabularyWord(word: "Keep"))
            try context.save()
            let config: ConfigurationValue = .object([
                "schemaVersion": .number(1),
                "preferences": .object([
                    "IsVADEnabled": .bool(false),
                    ShortcutAction.primaryRecording.userDefaultsKey: try .encoded(shortcut),
                ]),
                "dictionary": .object(["sections": .array([]), "vocabulary": .array([]), "replacements": .array([])]),
            ])
            try config.data().write(to: file)
            let service = store()

            service.load(into: container)

            XCTAssertFalse(service.isReady)
            XCTAssertTrue(defaults.bool(forKey: "IsVADEnabled"))
            XCTAssertNil(defaults.data(forKey: ShortcutAction.primaryRecording.userDefaultsKey))
            XCTAssertFalse(try context.fetch(FetchDescriptor<VocabularyWord>()).isEmpty)
        }
    }

    func testShortcutConflictsUseFinalValuesIncludingOmittedAndClearedBindings() throws {
        let primary = ShortcutAction.primaryRecording.userDefaultsKey
        let secondary = ShortcutAction.secondaryRecording.userDefaultsKey
        let first = Shortcut.key(keyCode: 42, modifierFlags: [.command, .shift])
        let second = Shortcut.key(keyCode: 40, modifierFlags: [.command, .shift])
        defaults.set(try JSONEncoder().encode(first), forKey: primary)
        defaults.set(try JSONEncoder().encode(second), forKey: secondary)

        XCTAssertThrowsError(try ConfigurationPreferences.validate([secondary: .encoded(first)], defaults: defaults))
        XCTAssertNoThrow(try ConfigurationPreferences.validate([primary: .encoded(second), secondary: .encoded(first)], defaults: defaults))
        XCTAssertNoThrow(try ConfigurationPreferences.validate([primary: .null, secondary: .encoded(first)], defaults: defaults))
        XCTAssertNoThrow(try ConfigurationPreferences.validate([primary + "_cleared": .bool(true), secondary: .encoded(first)], defaults: defaults))
        XCTAssertNoThrow(try ConfigurationPreferences.validate([
            primary: .encoded(Shortcut.key(keyCode: 42, modifierFlags: [])),
            secondary: .null,
            ShortcutAction.cancelRecorder.userDefaultsKey: .encoded(Shortcut.key(keyCode: 53, modifierFlags: [])),
        ], defaults: defaults))
    }

    func testOnlySuccessfullyImportedModeListsProtectOnboardingModes() throws {
        for (preference, expected) in [("\"modeConfigurationsV2\":[]", true), ("\"modeConfigurationsV2\":null", false), ("", false)] {
            try write("{\"schemaVersion\":1,\"preferences\":{\(preference)}}")
            let service = store()

            service.load(into: container)

            XCTAssertTrue(service.isReady, service.errorMessage ?? "")
            XCTAssertEqual(service.hasImportedModes, expected)
        }
        try write("{\"schemaVersion\":1,\"preferences\":{\"modeConfigurationsV2\":[],\"IsVADEnabled\":42}}")
        let invalid = store()

        invalid.load(into: container)

        XCTAssertFalse(invalid.isReady)
        XCTAssertFalse(invalid.hasImportedModes)
    }

    func testLegacyModeShortcutConflictRejectsTheCompleteFileBeforeMutation() throws {
        let mode = ModeConfig(name: "Retained", isAIEnhancementEnabled: false)
        let modeKey = ShortcutAction.mode(mode.id).userDefaultsKey
        let legacyKey = "Shortcut_powerMode_\(mode.id.uuidString)"
        let primaryKey = ShortcutAction.primaryRecording.userDefaultsKey
        let legacyShortcut = Shortcut.key(keyCode: 42, modifierFlags: [.command, .shift])
        let currentShortcut = Shortcut.key(keyCode: 40, modifierFlags: [.command, .shift])
        let currentData = try JSONEncoder().encode(currentShortcut)
        defaults.set(try JSONEncoder().encode([mode]), forKey: "modeConfigurationsV2")
        defaults.set(try JSONEncoder().encode(legacyShortcut), forKey: legacyKey)
        defaults.set(currentData, forKey: modeKey)
        defaults.set(true, forKey: "IsVADEnabled")
        let context = ModelContext(container)
        context.insert(VocabularyWord(word: "Keep"))
        try context.save()
        let input = try ConfigurationValue.object([
            "schemaVersion": .number(1),
            "preferences": .object([
                modeKey: .null, primaryKey: try .encoded(legacyShortcut), "IsVADEnabled": .bool(false),
            ]),
            "dictionary": .object(["sections": .array([]), "vocabulary": .array([]), "replacements": .array([])]),
        ]).data()
        try input.write(to: file)
        let service = store()

        service.load(into: container)
        service.saveNow()

        XCTAssertFalse(service.isReady)
        XCTAssertTrue(service.errorMessage?.contains("conflicts") == true)
        XCTAssertEqual(defaults.data(forKey: modeKey), currentData)
        XCTAssertNil(defaults.object(forKey: primaryKey))
        XCTAssertTrue(defaults.bool(forKey: "IsVADEnabled"))
        XCTAssertEqual(try ModelContext(container).fetch(FetchDescriptor<VocabularyWord>()).map(\.word), ["Keep"])
        XCTAssertEqual(try Data(contentsOf: file), input)
    }

    func testNoncanonicalModeShortcutKeyRejectsTheCompleteFileBeforeMutation() throws {
        let mode = ModeConfig(id: UUID(uuidString: "A1B2C3D4-1234-4321-ABCD-0123456789AB")!,
                              name: "Retained", isAIEnhancementEnabled: false)
        let canonicalKey = ShortcutAction.mode(mode.id).userDefaultsKey
        let lowercaseKey = "Shortcut_mode_\(mode.id.uuidString.lowercased())"
        let current = try JSONEncoder().encode(Shortcut.key(keyCode: 40, modifierFlags: [.command, .shift]))
        defaults.set(try JSONEncoder().encode([mode]), forKey: "modeConfigurationsV2")
        defaults.set(current, forKey: canonicalKey)
        defaults.set(true, forKey: "IsVADEnabled")
        let context = ModelContext(container)
        context.insert(VocabularyWord(word: "Keep"))
        try context.save()
        let input = try ConfigurationValue.object([
            "schemaVersion": .number(1),
            "preferences": .object([
                lowercaseKey: try .encoded(Shortcut.key(keyCode: 42, modifierFlags: [.command, .shift])),
                "IsVADEnabled": .bool(false),
            ]),
            "dictionary": .object(["sections": .array([]), "vocabulary": .array([]), "replacements": .array([])]),
        ]).data()
        try input.write(to: file)
        let service = store()

        service.load(into: container)
        service.saveNow()

        XCTAssertFalse(service.isReady)
        XCTAssertNotNil(service.errorMessage)
        XCTAssertEqual(defaults.data(forKey: canonicalKey), current)
        XCTAssertNil(defaults.object(forKey: lowercaseKey))
        XCTAssertTrue(defaults.bool(forKey: "IsVADEnabled"))
        XCTAssertEqual(try ModelContext(container).fetch(FetchDescriptor<VocabularyWord>()).map(\.word), ["Keep"])
        XCTAssertEqual(try Data(contentsOf: file), input)
    }

    func testFirstCaptureDoesNotWriteConflictingMigratedShortcuts() throws {
        let mode = ModeConfig(name: "Legacy", isAIEnhancementEnabled: false)
        let shortcut = try JSONEncoder().encode(Shortcut.key(keyCode: 42, modifierFlags: [.command, .shift]))
        defaults.set(try JSONEncoder().encode([mode]), forKey: "modeConfigurationsV2")
        defaults.set(shortcut, forKey: "Shortcut_powerMode_\(mode.id.uuidString)")
        defaults.set(shortcut, forKey: ShortcutAction.primaryRecording.userDefaultsKey)
        let service = store()

        service.load(into: container)
        ModeShortcutMigration.migrate(modeIDs: [mode.id], defaults: defaults)
        service.startObserving()

        XCTAssertFalse(service.isReady)
        XCTAssertTrue(service.errorMessage?.contains("conflicts") == true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testLegacyShortcutPrecedenceAndClearedFlagsSurviveSaveAndReload() throws {
        let mode = ModeConfig(name: "Legacy", isAIEnhancementEnabled: false)
        let key = ShortcutAction.mode(mode.id).userDefaultsKey
        let legacyKey = "Shortcut_powerMode_\(mode.id.uuidString)"
        let first = Shortcut.key(keyCode: 42, modifierFlags: [.command, .shift])
        let second = Shortcut.key(keyCode: 40, modifierFlags: [.command, .shift])
        struct Scenario {
            let name: String
            var current: Shortcut? = nil
            var supplied: ConfigurationValue? = nil
            var legacyCleared: Bool? = nil
            var currentCleared: Bool? = nil
            var suppliedCleared: ConfigurationValue? = nil
            var conflicts = false
            let expected: Shortcut
            var expectedCleared = false
        }
        let scenarios = [
            Scenario(name: "Missing current binding restores legacy", conflicts: true, expected: first),
            Scenario(name: "Null restores legacy", current: second, supplied: .null, conflicts: true, expected: first),
            Scenario(name: "Current binding overrides legacy", current: second, expected: second),
            Scenario(name: "Supplied binding overrides legacy", supplied: try .encoded(second), expected: second),
            Scenario(name: "Legacy clear remains effective", legacyCleared: true, expected: first, expectedCleared: true),
            Scenario(name: "Current false overrides legacy clear", legacyCleared: true, currentCleared: false,
                     conflicts: true, expected: first),
            Scenario(name: "Current clear overrides legacy false", legacyCleared: false, currentCleared: true,
                     expected: first, expectedCleared: true),
            Scenario(name: "Null clear restores legacy true", legacyCleared: true, currentCleared: false,
                     suppliedCleared: .null, expected: first, expectedCleared: true),
            Scenario(name: "Null clear restores legacy false", legacyCleared: false, currentCleared: true,
                     suppliedCleared: .null, conflicts: true, expected: first),
            Scenario(name: "Explicit false removes current clear", legacyCleared: true, currentCleared: true,
                     suppliedCleared: .bool(false), conflicts: true, expected: first),
            Scenario(name: "Explicit clear suppresses restored binding", current: second, supplied: .null,
                     legacyCleared: false, suppliedCleared: .bool(true), expected: first, expectedCleared: true),
        ]
        for scenario in scenarios {
            defaults.removePersistentDomain(forName: suite)
            defaults.set(try JSONEncoder().encode(first), forKey: legacyKey)
            if let current = scenario.current { defaults.set(try JSONEncoder().encode(current), forKey: key) }
            if let cleared = scenario.legacyCleared { defaults.set(cleared, forKey: "\(legacyKey)_cleared") }
            if let cleared = scenario.currentCleared { defaults.set(cleared, forKey: "\(key)_cleared") }
            var preferences: [String: ConfigurationValue] = [
                "modeConfigurationsV2": try .encoded([mode]),
                ShortcutAction.primaryRecording.userDefaultsKey: try .encoded(first),
            ]
            preferences[key] = scenario.supplied
            preferences["\(key)_cleared"] = scenario.suppliedCleared
            let input = Data("// Retain this comment\n".utf8) + (try ConfigurationValue.object([
                "schemaVersion": .number(1), "preferences": .object(preferences),
            ]).data())
            try input.write(to: file)
            let before = defaults.persistentDomain(forName: suite) ?? [:]
            let service = store()

            service.load(into: container)

            XCTAssertEqual(service.isReady, !scenario.conflicts, scenario.name)
            if scenario.conflicts {
                XCTAssertTrue(service.errorMessage?.contains("conflicts") == true, scenario.name)
                XCTAssertTrue(NSDictionary(dictionary: before).isEqual(to: defaults.persistentDomain(forName: suite) ?? [:]), scenario.name)
                XCTAssertEqual(try Data(contentsOf: file), input, scenario.name)
                continue
            }
            ModeShortcutMigration.migrate(modeIDs: [mode.id], defaults: defaults)
            service.saveNow()
            let reopened = store()
            reopened.load(into: container)
            ModeShortcutMigration.migrate(modeIDs: [mode.id], defaults: defaults)

            XCTAssertTrue(service.isReady, service.errorMessage ?? scenario.name)
            XCTAssertTrue(reopened.isReady, reopened.errorMessage ?? scenario.name)
            XCTAssertEqual(try JSONDecoder().decode(Shortcut.self, from: XCTUnwrap(defaults.data(forKey: key))), scenario.expected, scenario.name)
            XCTAssertEqual(defaults.bool(forKey: "\(key)_cleared"), scenario.expectedCleared, scenario.name)
            XCTAssertTrue(try String(contentsOf: file, encoding: .utf8).contains("// Retain this comment"), scenario.name)
        }
    }

    func testLegacyShortcutConflictsFollowTheFinalModeList() throws {
        let mode = ModeConfig(name: "Legacy", isAIEnhancementEnabled: false)
        let other = ModeConfig(name: "Other", isAIEnhancementEnabled: false)
        let shortcut = Shortcut.key(keyCode: 42, modifierFlags: [.command, .shift])
        defaults.set(try JSONEncoder().encode([mode]), forKey: "powerModeConfigurationsV2")
        defaults.set(try JSONEncoder().encode(shortcut), forKey: "Shortcut_powerMode_\(mode.id.uuidString)")
        let binding: ConfigurationValue = try .encoded(shortcut)
        let primary = ShortcutAction.primaryRecording.userDefaultsKey

        XCTAssertThrowsError(try ConfigurationPreferences.validate([primary: binding], defaults: defaults))
        XCTAssertThrowsError(try ConfigurationPreferences.validate([primary: binding, "modeConfigurationsV2": .null], defaults: defaults))
        XCTAssertNoThrow(try ConfigurationPreferences.validate([primary: binding, "modeConfigurationsV2": .array([])], defaults: defaults))
        XCTAssertNoThrow(try ConfigurationPreferences.validate([primary: binding, "modeConfigurationsV2": .encoded([other])], defaults: defaults))
        defaults.set(try JSONEncoder().encode([other]), forKey: "modeConfigurationsV2")
        XCTAssertNoThrow(try ConfigurationPreferences.validate([primary: binding], defaults: defaults))
        XCTAssertThrowsError(try ConfigurationPreferences.validate([primary: binding, "modeConfigurationsV2": .null], defaults: defaults))
    }

    func testTwoLegacyModeBindingsCannotEscapeConflictValidation() throws {
        let first = ModeConfig(name: "First", isAIEnhancementEnabled: false)
        let second = ModeConfig(name: "Second", isAIEnhancementEnabled: false)
        let shortcut = Shortcut.key(keyCode: 42, modifierFlags: [.command, .shift])
        defaults.set(try JSONEncoder().encode([first, second]), forKey: "modeConfigurationsV2")
        for mode in [first, second] {
            defaults.set(try JSONEncoder().encode(shortcut), forKey: "Shortcut_powerMode_\(mode.id.uuidString)")
        }

        XCTAssertThrowsError(try ConfigurationPreferences.validate([:], defaults: defaults))
        XCTAssertNoThrow(try ConfigurationPreferences.validate(["modeConfigurationsV2": .encoded([first])], defaults: defaults))
        XCTAssertNoThrow(try ConfigurationPreferences.validate([
            "\(ShortcutAction.mode(second.id).userDefaultsKey)_cleared": .bool(true),
        ], defaults: defaults))
    }

    func testUnsafeLegacyBindingIsRejectedUnlessOverriddenOrItsModeIsRemoved() throws {
        let mode = ModeConfig(name: "Legacy", isAIEnhancementEnabled: false)
        let key = ShortcutAction.mode(mode.id).userDefaultsKey
        defaults.set(try JSONEncoder().encode([mode]), forKey: "modeConfigurationsV2")
        defaults.set(try JSONEncoder().encode(Shortcut.key(keyCode: 0, modifierFlags: [])),
                     forKey: "Shortcut_powerMode_\(mode.id.uuidString)")
        let safe: ConfigurationValue = try .encoded(Shortcut.key(keyCode: 42, modifierFlags: [.command, .shift]))

        XCTAssertThrowsError(try ConfigurationPreferences.validate([:], defaults: defaults))
        XCTAssertNoThrow(try ConfigurationPreferences.validate([key: safe], defaults: defaults))
        XCTAssertNoThrow(try ConfigurationPreferences.validate(["modeConfigurationsV2": .array([])], defaults: defaults))
    }

    func testOnlyCanonicalModeShortcutNamesAreAcceptedIncludingClearFlagsAndNulls() throws {
        let id = UUID(uuidString: "A1B2C3D4-1234-4321-ABCD-0123456789AB")!
        let canonical = ShortcutAction.mode(id).userDefaultsKey
        let shortcut: ConfigurationValue = try .encoded(Shortcut.key(keyCode: 42, modifierFlags: [.command, .shift]))
        let invalidNames = [
            "Shortcut_mode_\(id.uuidString.lowercased())",
            "Shortcut_mode_a1B2C3D4-1234-4321-ABCD-0123456789AB",
            "Shortcut_mode_not-a-uuid", "\(canonical) ",
        ]
        for name in invalidNames {
            for value in [shortcut, .null] {
                XCTAssertThrowsError(try ConfigurationPreferences.validate([name: value]), name)
            }
            for value in [ConfigurationValue.bool(true), .bool(false), .null] {
                XCTAssertThrowsError(try ConfigurationPreferences.validate(["\(name)_cleared": value]), name)
            }
            XCTAssertThrowsError(try ConfigurationPreferences.validate([canonical: shortcut, name: shortcut]), name)
        }
        for key in [canonical, "Shortcut_mode_01234567-1234-4321-1234-012345678901"] {
            XCTAssertNoThrow(try ConfigurationPreferences.validate([key: shortcut, "\(key)_cleared": .bool(false)]))
            XCTAssertNoThrow(try ConfigurationPreferences.validate([key: .null, "\(key)_cleared": .null]))
        }
    }

    func testCaptureOmitsPreviouslyStoredNoncanonicalShortcutAliases() throws {
        let id = UUID(uuidString: "A1B2C3D4-1234-4321-ABCD-0123456789AB")!
        let key = ShortcutAction.mode(id).userDefaultsKey
        let alias = "Shortcut_mode_\(id.uuidString.lowercased())"
        let shortcut = Shortcut.key(keyCode: 42, modifierFlags: [.command, .shift])
        let data = try JSONEncoder().encode(shortcut)
        defaults.set(data, forKey: key)
        defaults.set(data, forKey: alias)
        defaults.set(true, forKey: "\(alias)_cleared")

        let captured = try ConfigurationPreferences.capture(from: defaults)

        XCTAssertEqual(captured[key], try .encoded(shortcut))
        XCTAssertNil(captured[alias])
        XCTAssertNil(captured["\(alias)_cleared"])
    }

    func testConflictingAppChangesLeaveTheLastValidFileUntouched() throws {
        let first = Shortcut.key(keyCode: 42, modifierFlags: [.command, .shift])
        let second = Shortcut.key(keyCode: 40, modifierFlags: [.command, .shift])
        defaults.set(try JSONEncoder().encode(first), forKey: ShortcutAction.primaryRecording.userDefaultsKey)
        defaults.set(try JSONEncoder().encode(second), forKey: ShortcutAction.secondaryRecording.userDefaultsKey)
        let service = store()
        service.load(into: container)
        service.saveNow()
        let original = try Data(contentsOf: file)

        defaults.set(try JSONEncoder().encode(first), forKey: ShortcutAction.secondaryRecording.userDefaultsKey)
        service.saveNow()

        XCTAssertFalse(service.isReady)
        XCTAssertTrue(service.errorMessage?.contains("conflicts") == true)
        XCTAssertEqual(try Data(contentsOf: file), original)
    }

    func testShortcutConflictsIgnoreRemovedModesAndRetainOmittedOrLegacyModes() throws {
        let old = ModeConfig(name: "Old", isAIEnhancementEnabled: false)
        let new = ModeConfig(name: "New", isAIEnhancementEnabled: false)
        let shortcut = Shortcut.key(keyCode: 42, modifierFlags: [.command, .shift])
        defaults.set(try JSONEncoder().encode([old]), forKey: "modeConfigurationsV2")
        defaults.set(try JSONEncoder().encode(shortcut), forKey: ShortcutAction.mode(old.id).userDefaultsKey)
        let binding: ConfigurationValue = try .encoded(shortcut)
        let replacement: [String: ConfigurationValue] = [
            "modeConfigurationsV2": try .encoded([new]), ShortcutAction.mode(new.id).userDefaultsKey: binding,
        ]

        XCTAssertNoThrow(try ConfigurationPreferences.validate(replacement, defaults: defaults))
        XCTAssertThrowsError(try ConfigurationPreferences.validate([ShortcutAction.primaryRecording.userDefaultsKey: binding], defaults: defaults))
        XCTAssertNoThrow(try ConfigurationPreferences.validate([
            "modeConfigurationsV2": .null, ShortcutAction.primaryRecording.userDefaultsKey: binding,
        ], defaults: defaults))

        defaults.set(try JSONEncoder().encode([old]), forKey: "powerModeConfigurationsV2")

        XCTAssertThrowsError(try ConfigurationPreferences.validate([
            "modeConfigurationsV2": .null, ShortcutAction.primaryRecording.userDefaultsKey: binding,
        ], defaults: defaults))
    }

    func testFirstLaunchCreatesCompleteFileAndPreservesExistingPreferences() throws {
        defaults.set("parakeet-v3", forKey: "CurrentTranscriptionModel")
        defaults.set(["es", "en"], forKey: "SelectedLanguages")
        defaults.set("test-secret", forKey: "OpenAIAPIKey")
        defaults.set("cache", forKey: "dashboardStatsSnapshotStale")
        let context = ModelContext(container)
        context.insert(VocabularyWord(word: "VoiceInk"))
        try context.save()
        let service = store()

        service.load(into: container)
        service.startObserving()

        XCTAssertTrue(service.isReady, service.errorMessage ?? "")
        let config = try root()
        XCTAssertEqual(config["preferences"]?.object?["CurrentTranscriptionModel"], .string("parakeet-v3"))
        XCTAssertEqual(config["preferences"]?.object?["SelectedLanguages"], .array([.string("es"), .string("en")]))
        XCTAssertNil(config["preferences"]?.object?["OpenAIAPIKey"])
        XCTAssertNil(config["preferences"]?.object?["dashboardStatsSnapshotStale"])
        XCTAssertEqual(try config["dictionary"]?.decoded(as: ConfigurationDictionary.self).vocabulary.map(\.term), ["VoiceInk"])
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
    }

    func testEditablePreferencesLoadBeforeConsumersAndOmittedKeysSurvive() throws {
        defaults.set(true, forKey: "IsVADEnabled")
        defaults.set("dark", forKey: "AppAppearancePreference")
        defaults.set(["fr"], forKey: "SelectedLanguages")
        try write("""
        {"schemaVersion":1,"preferences":{"SelectedLanguages":["es","en"],"IsVADEnabled":false,"localCLICommandTemplate":"printf '%s' hello"}}
        """)
        let service = store()

        service.load(into: container)

        XCTAssertTrue(service.isReady, service.errorMessage ?? "")
        XCTAssertFalse(defaults.bool(forKey: "IsVADEnabled"))
        XCTAssertEqual(defaults.string(forKey: "AppAppearancePreference"), "dark")
        XCTAssertEqual(defaults.selectedTranscriptionLanguages, ["es", "en"])
        XCTAssertEqual(defaults.string(forKey: "SelectedLanguage"), "auto")
        XCTAssertEqual(defaults.string(forKey: "localCLICommandTemplate"), "printf '%s' hello")
    }

    func testRetiredAutoLearnReviewKeysLoadWithoutApplyingAndNewPreferencesRoundTrip() throws {
        try write("""
        {"schemaVersion":1,"preferences":{
          "AutoLearnDictionaryProvider":"OpenAI","AutoLearnDictionaryModel":"gpt","AutoLearnDictionaryReviewSchedule":"daily",
          "SmartPunctuationEnabled":true,"IsAutomaticVocabularyCorrectionEnabled":false,
          "AutoLearnDictionaryMinimumCorrections":2,"audioInputChannelsByDeviceUID":{"usb-uid":[2]}
        }}
        """)
        let service = store()

        service.load(into: container)

        XCTAssertTrue(service.isReady, service.errorMessage ?? "")
        for key in ["AutoLearnDictionaryProvider", "AutoLearnDictionaryModel", "AutoLearnDictionaryReviewSchedule"] {
            XCTAssertNil(defaults.object(forKey: key), key)
        }
        XCTAssertTrue(defaults.bool(forKey: "SmartPunctuationEnabled"))
        XCTAssertFalse(defaults.bool(forKey: "IsAutomaticVocabularyCorrectionEnabled"))
        XCTAssertEqual(defaults.integer(forKey: "AutoLearnDictionaryMinimumCorrections"), 2)
        XCTAssertEqual(defaults.audioInputChannelsByDeviceUID, ["usb-uid": [2]])
        let captured = try ConfigurationPreferences.capture(from: defaults)
        XCTAssertNil(captured["AutoLearnDictionaryProvider"])
        XCTAssertEqual(captured["audioInputChannelsByDeviceUID"], .object(["usb-uid": .array([.number(2)])]))
    }

    func testModesPromptsModelsMicrophoneRequirementsAndShortcutsRoundTrip() throws {
        let prompt = CustomPrompt(title: "Technical", promptText: "Keep names unchanged.")
        let mode = ModeConfig(name: "Code", isAIEnhancementEnabled: true, selectedPrompt: prompt.id.uuidString,
                              selectedTranscriptionModelName: "parakeet-v3", selectedLanguages: ["es", "en"])
        let model = CustomAIProviderConfig(name: "Local", baseURL: "http://localhost:1234/v1", models: ["test"], selectedModel: "test")
        let shortcut = Shortcut.key(keyCode: 42, modifierFlags: [.command, .shift])
        let preferenceValues: [String: ConfigurationValue] = [
            "modeConfigurationsV2": try .encoded([mode]), "customPrompts": try .encoded([prompt]),
            "customAIProviders": try .encoded([model]),
            ShortcutAction.mode(mode.id).userDefaultsKey: try .encoded(shortcut),
            "Shortcut_secondaryRecording_cleared": .bool(true),
            "selectedAudioDeviceName": .string("SHURE MV7"),
            "prioritizedDevices": .array([.object([
                "id": .string("virtual-uid"), "name": .string("Virtual Input"), "priority": .number(0),
                "modelUID": .string("virtual-model"),
                "requirements": .object(["application": .object(["bundleID": .string("test.audio"), "name": .string("Audio")])]),
            ])]),
        ]
        let config: ConfigurationValue = .object(["schemaVersion": .number(1), "preferences": .object(preferenceValues)])
        try config.data().write(to: file)
        let service = store()

        service.load(into: container)
        service.startObserving()

        XCTAssertTrue(service.isReady, service.errorMessage ?? "")
        let captured = try ConfigurationPreferences.capture(from: defaults)
        for (key, expected) in preferenceValues { XCTAssertEqual(captured[key], expected, key) }
        XCTAssertEqual(try JSONDecoder().decode([ModeConfig].self, from: XCTUnwrap(defaults.data(forKey: "modeConfigurationsV2"))).first?.name, "Code")
    }

    func testInvalidPreferenceCannotPartiallyChangeDictionaryOrDefaults() throws {
        defaults.set(true, forKey: "IsVADEnabled")
        let context = ModelContext(container)
        context.insert(VocabularyWord(word: "Keep"))
        try context.save()
        try write("""
        {"schemaVersion":1,"preferences":{"IsVADEnabled":false,"SelectedLanguages":42},"dictionary":{"sections":[],"vocabulary":[],"replacements":[]}}
        """)
        let original = try Data(contentsOf: file)
        let service = store()

        service.load(into: container)
        service.startObserving()
        service.saveNow()

        XCTAssertFalse(service.isReady)
        XCTAssertNotNil(service.errorMessage)
        XCTAssertTrue(defaults.bool(forKey: "IsVADEnabled"))
        XCTAssertEqual(try ConfigurationDictionary.capture(in: ModelContext(container)).vocabulary.map(\.term), ["Keep"])
        XCTAssertEqual(try Data(contentsOf: file), original)
    }

    func testInvalidDictionaryCannotPartiallyChangePreferences() throws {
        defaults.set(true, forKey: "IsVADEnabled")
        try write("""
        {"schemaVersion":1,"preferences":{"IsVADEnabled":false},"dictionary":{"sections":[],"vocabulary":[{"term":"Name","sectionID":"11111111-1111-1111-1111-111111111111"}],"replacements":[]}}
        """)
        let service = store()
        service.load(into: container)
        XCTAssertFalse(service.isReady)
        XCTAssertTrue(defaults.bool(forKey: "IsVADEnabled"))
    }

    func testUnknownKeysUnsupportedVersionsAndPlaintextKeysAreRejected() throws {
        for text in [
            "{\"schemaVersion\":2}", "{\"schemaVersion\":1,\"preferencess\":{}}",
            "{\"schemaVersion\":1,\"preferences\":{\"OpenAIAPIKey\":\"fake\"}}",
            "{\"schemaVersion\":1,\"preferences\":{\"customCloudModels\":[{\"apiKey\":\"fake\"}]}}",
        ] {
            try write(text)
            let service = store()
            service.load(into: container)
            XCTAssertFalse(service.isReady, text)
            XCTAssertEqual(try Data(contentsOf: file), Data(text.utf8))
        }
    }

    func testEmptyDictionaryReplacesOnlyDictionaryAndPreservesHistory() throws {
        let context = ModelContext(container)
        context.insert(VocabularyWord(word: "Old"))
        context.insert(WordReplacement(originalText: "old", replacementText: "new"))
        let history = Transcription(text: "Keep history", duration: 1)
        context.insert(history)
        try context.save()
        try write("{\"schemaVersion\":1,\"dictionary\":{\"sections\":[],\"vocabulary\":[],\"replacements\":[]}}")

        let service = store()
        service.load(into: container)

        XCTAssertTrue(service.isReady, service.errorMessage ?? "")
        let fresh = ModelContext(container)
        XCTAssertTrue(try fresh.fetch(FetchDescriptor<VocabularyWord>()).isEmpty)
        XCTAssertTrue(try fresh.fetch(FetchDescriptor<WordReplacement>()).isEmpty)
        XCTAssertEqual(try fresh.fetch(FetchDescriptor<Transcription>()).map(\.id), [history.id])
    }

    func testDictionarySectionsVariantsIdentitiesAndDatesSurviveReload() throws {
        let sectionID = UUID()
        let replacementID = UUID()
        let dictionary = ConfigurationDictionary(
            sections: [.init(id: sectionID, name: "Technology", description: "Product names")],
            vocabulary: [.init(term: "VoiceInk", sectionID: sectionID, addedAt: 1_700_000_000)],
            replacements: [.init(id: replacementID, sources: ["voice ink", "vois ink"], replacement: "VoiceInk", addedAt: 1_700_000_001)]
        )
        let content: ConfigurationValue = .object(["schemaVersion": .number(1), "dictionary": try .encoded(dictionary)])
        try content.data().write(to: file)

        for _ in 0..<2 {
            let service = store()
            service.load(into: container)
            XCTAssertTrue(service.isReady, service.errorMessage ?? "")
            XCTAssertEqual(try ConfigurationDictionary.capture(in: ModelContext(container)), dictionary)
        }
    }

    func testAppChangesSaveWithCommentsAndNullResets() throws {
        defaults.register(defaults: ["IsVADEnabled": true])
        try write("// retain header\n{\"schemaVersion\":1,\"preferences\":{ /* speech */ \"IsVADEnabled\":false,\"CurrentTranscriptionModel\":\"old\"}}")
        let service = store()
        service.load(into: container)
        defaults.set(true, forKey: "IsVADEnabled")
        defaults.removeObject(forKey: "CurrentTranscriptionModel")

        service.saveNow()

        XCTAssertTrue(service.isReady, service.errorMessage ?? "")
        let preferences = try root()["preferences"]?.object
        XCTAssertEqual(preferences?["IsVADEnabled"], .bool(true))
        XCTAssertEqual(preferences?["CurrentTranscriptionModel"], .null)
        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(text.contains("// retain header"))
        XCTAssertTrue(text.contains("/* speech */"))
        defaults.set("reset-me", forKey: "CurrentTranscriptionModel")
        store().load(into: container)
        XCTAssertNil(defaults.string(forKey: "CurrentTranscriptionModel"))
    }

    func testUnchangedLaunchDoesNotRewriteUserFormatting() throws {
        try write("// My config\n{ \"schemaVersion\" : 1, \"preferences\" : { \"IsVADEnabled\" : true, }, }\n")
        let data = try Data(contentsOf: file)
        let service = store()
        service.load(into: container)
        service.startObserving()
        service.saveNow()
        XCTAssertEqual(try Data(contentsOf: file), data)
    }

    func testExternalEditOrDeletionPausesSavingAndKeepsEditorContent() throws {
        let service = store()
        service.load(into: container)
        service.saveNow()
        let external = "{\"schemaVersion\":1,\"preferences\":{\"IsVADEnabled\":false}}"
        try write(external)
        defaults.set(true, forKey: "IsVADEnabled")

        service.saveNow()

        XCTAssertFalse(service.isReady)
        XCTAssertTrue(service.errorMessage?.contains("outside VoiceInk") == true)
        XCTAssertEqual(try Data(contentsOf: file), Data(external.utf8))
        let reopened = store()
        reopened.load(into: container)
        XCTAssertFalse(defaults.bool(forKey: "IsVADEnabled"))
        try FileManager.default.removeItem(at: file)
        reopened.saveNow()
        XCTAssertFalse(reopened.isReady)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testSymlinkTargetIsUpdatedWithoutReplacingTheLink() throws {
        let target = directory.appendingPathComponent("dotfiles/voiceink.jsonc")
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{\"schemaVersion\":1,\"preferences\":{\"IsVADEnabled\":true}}".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
        let service = store()
        service.load(into: container)
        defaults.set(false, forKey: "IsVADEnabled")

        service.saveNow()

        XCTAssertTrue(service.isReady, service.errorMessage ?? "")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: file.path), target.path)
        XCTAssertEqual(try root()["preferences"]?.object?["IsVADEnabled"], .bool(false))
    }

    func testWriteFailureIsVisibleAndDoesNotReplaceExistingFile() throws {
        let parentFile = directory.appendingPathComponent("not-a-directory")
        try Data("keep".utf8).write(to: parentFile)
        let service = store(at: parentFile.appendingPathComponent("config.jsonc"))
        service.load(into: container)
        service.saveNow()
        XCTAssertFalse(service.isReady)
        XCTAssertNotNil(service.errorMessage)
        XCTAssertEqual(try String(contentsOf: parentFile, encoding: .utf8), "keep")
    }

    func testDefaultsChangesAreObserved() async throws {
        defaults.set(true, forKey: "IsVADEnabled")
        let service = store()
        service.load(into: container)
        service.startObserving()

        defaults.set(false, forKey: "IsVADEnabled")
        for _ in 0..<30 {
            try await Task.sleep(for: .milliseconds(100))
            if try root()["preferences"]?.object?["IsVADEnabled"] == .bool(false) { break }
        }

        XCTAssertEqual(try root()["preferences"]?.object?["IsVADEnabled"], .bool(false))
    }

    func testBackgroundDictionarySavesAreObservedWithoutPreferenceChanges() async throws {
        let service = store()
        service.load(into: container)
        service.startObserving()
        let writer = ModelContext(container)

        writer.insert(VocabularyWord(word: "Observed"))
        try writer.save()
        for _ in 0..<30 {
            try await Task.sleep(for: .milliseconds(100))
            if try root()["dictionary"]?.decoded(as: ConfigurationDictionary.self).vocabulary.count == 1 { break }
        }

        XCTAssertEqual(try root()["dictionary"]?.decoded(as: ConfigurationDictionary.self).vocabulary.map(\.term), ["Observed"])
    }

    func testVocabularySpellingsLoadInPlaceAndClearWhenOmittedNullOrEmpty() throws {
        let context = ModelContext(container)
        let word = VocabularyWord(word: "VoiceInk", dateAdded: Date(timeIntervalSince1970: 1_700_000_000))
        let history = Transcription(text: "Keep history", duration: 1)
        context.insert(word)
        context.insert(history)
        try context.save()
        let wordID = word.persistentModelID
        let entry = { (soundsLike: String) in
            "{\"schemaVersion\":1,\"dictionary\":{\"sections\":[],\"vocabulary\":[{\"term\":\"VoiceInk\"\(soundsLike)}],\"replacements\":[]}}"
        }

        for (soundsLike, expected) in [
            (",\"soundsLike\":[\"voice  ink\",\"voicing\"]", ["voice ink", "voicing"]),
            ("", []), (",\"soundsLike\":[\"voicing\"]", ["voicing"]), (",\"soundsLike\":null", []),
            (",\"soundsLike\":[\"voicing\"]", ["voicing"]), (",\"soundsLike\":[]", []),
        ] {
            try write(entry(soundsLike))
            let service = store()
            service.load(into: container)
            let reader = ModelContext(container)

            XCTAssertTrue(service.isReady, service.errorMessage ?? soundsLike)
            let saved = try XCTUnwrap(reader.fetch(FetchDescriptor<VocabularyWord>()).first)
            XCTAssertEqual(saved.persistentModelID, wordID, soundsLike)
            XCTAssertEqual(saved.soundsLike, expected, soundsLike)
            XCTAssertEqual(saved.dateAdded.timeIntervalSince1970, 1_700_000_000)
            XCTAssertEqual(try reader.fetch(FetchDescriptor<Transcription>()).map(\.id), [history.id])
        }
    }

    func testVocabularySpellingsSaveFromAppAndRoundTrip() throws {
        try write("{\"schemaVersion\":1}")
        let service = store()
        service.load(into: container)
        let context = ModelContext(container)
        context.insert(VocabularyWord(word: "WebSocket", soundsLike: ["web socket"]))
        context.insert(VocabularyWord(word: "Plain"))
        try context.save()

        service.saveNow()
        let saved = try XCTUnwrap(root()["dictionary"]).decoded(as: ConfigurationDictionary.self)
        let reopened = store()
        reopened.load(into: container)

        XCTAssertTrue(service.isReady, service.errorMessage ?? "")
        XCTAssertTrue(reopened.isReady, reopened.errorMessage ?? "")
        XCTAssertEqual(saved.vocabulary.first { $0.term == "WebSocket" }?.soundsLike, ["web socket"])
        XCTAssertNil(saved.vocabulary.first { $0.term == "Plain" }?.soundsLike)
        guard case .array(let vocabulary)? = try root()["dictionary"]?.object?["vocabulary"] else {
            return XCTFail("Missing vocabulary")
        }
        XCTAssertNil(vocabulary.first { $0.object?["term"] == .string("Plain") }?.object?["soundsLike"])
        XCTAssertEqual(try ConfigurationDictionary.capture(in: ModelContext(container)), saved)
    }

    func testInvalidVocabularySpellingsLeaveTheDictionaryUntouched() throws {
        let context = ModelContext(container)
        context.insert(VocabularyWord(word: "Keep", soundsLike: ["kept"]))
        try context.save()
        let tooMany = (0...VocabularySoundsLike.maximumCount).map { "\"s\($0)\"" }.joined(separator: ",")
        let tooLong = String(repeating: "x", count: VocabularySoundsLike.maximumLength + 1)

        for spellings in ["\"a,b\"", "\"same\",\"SAME\"", "\"name\"", "\" \"", tooMany, "\"\(tooLong)\""] {
            let text = "{\"schemaVersion\":1,\"dictionary\":{\"sections\":[],\"vocabulary\":[{\"term\":\"Name\",\"soundsLike\":[\(spellings)]}],\"replacements\":[]}}"
            try write(text)
            let service = store()
            service.load(into: container)

            XCTAssertFalse(service.isReady, spellings)
            let words = try ModelContext(container).fetch(FetchDescriptor<VocabularyWord>())
            XCTAssertEqual(words.map(\.word), ["Keep"], spellings)
            XCTAssertEqual(words.first?.soundsLike, ["kept"], spellings)
            XCTAssertEqual(try Data(contentsOf: file), Data(text.utf8))
        }
    }

    func testDictionaryReloadPreservesPersistentIdentitiesAndMissingDates() throws {
        let context = ModelContext(container)
        let word = VocabularyWord(word: "Retained", dateAdded: Date(timeIntervalSince1970: 1_700_000_000))
        let replacement = WordReplacement(originalText: "v ink", replacementText: "VoiceInk", dateAdded: word.dateAdded)
        context.insert(word)
        context.insert(replacement)
        try context.save()
        let wordID = word.persistentModelID
        let ruleID = replacement.persistentModelID
        try write("""
        {"schemaVersion":1,"dictionary":{"sections":[],"vocabulary":[{"term":"Retained"}],"replacements":[{"sources":["v ink"],"replacement":"Updated"}]}}
        """)

        let service = store()
        service.load(into: container)
        let reader = ModelContext(container)

        XCTAssertTrue(service.isReady, service.errorMessage ?? "")
        let savedWord = try XCTUnwrap(reader.fetch(FetchDescriptor<VocabularyWord>()).first)
        let savedRule = try XCTUnwrap(reader.fetch(FetchDescriptor<WordReplacement>()).first)
        XCTAssertEqual(savedWord.persistentModelID, wordID)
        XCTAssertEqual(savedRule.persistentModelID, ruleID)
        XCTAssertEqual(savedWord.dateAdded.timeIntervalSince1970, 1_700_000_000)
        XCTAssertEqual(savedRule.dateAdded, savedWord.dateAdded)
        XCTAssertEqual(savedRule.replacementText, "Updated")
    }

    func testModeEditsWithSameIDAreSavedAndLoadOnNextLaunch() throws {
        var mode = ModeConfig(name: "Before", isAIEnhancementEnabled: false)
        defaults.set(try JSONEncoder().encode([mode]), forKey: "modeConfigurationsV2")
        let service = store()
        service.load(into: container)
        service.saveNow()

        mode.name = "After"
        defaults.set(try JSONEncoder().encode([mode]), forKey: "modeConfigurationsV2")
        service.saveNow()
        defaults.removeObject(forKey: "modeConfigurationsV2")
        store().load(into: container)

        let restored = try JSONDecoder().decode([ModeConfig].self, from: XCTUnwrap(defaults.data(forKey: "modeConfigurationsV2")))
        XCTAssertEqual(restored.first?.id, mode.id)
        XCTAssertEqual(restored.first?.name, "After")
    }

    func testLegacyModelKeyIsNotExported() throws {
        let model = CustomCloudModel(name: "test", displayName: "Test", description: "Fixture", apiEndpoint: "https://example.test/v1", modelName: "test")
        var object = try XCTUnwrap(ConfigurationValue.encoded(model).object)
        object["apiKey"] = .string("fake-fixture-secret")
        defaults.set(try ConfigurationValue.array([.object(object)]).data(), forKey: "customCloudModels")

        let preferences = try ConfigurationPreferences.capture(from: defaults)

        XCTAssertFalse(String(decoding: try ConfigurationValue.object(preferences).data(), as: UTF8.self).contains("fake-fixture-secret"))
        XCTAssertEqual(try preferences["customCloudModels"]?.decoded(as: [CustomModelBackup].self).first?.id, model.id)
    }

    func testLegacyConflictingAndCyclicReplacementRulesSurviveFirstCaptureAndReload() throws {
        let context = ModelContext(container)
        for (index, pair) in [("tone", "alpha"), ("tone", "beta"), ("alpha", "tone")].enumerated() {
            context.insert(WordReplacement(originalText: pair.0, replacementText: pair.1,
                                           dateAdded: Date(timeIntervalSince1970: 1_700_000_000 + Double(index))))
        }
        try context.save()
        let expected = try ConfigurationDictionary.capture(in: ModelContext(container))
        let service = store()

        service.load(into: container)
        service.saveNow()
        let reopened = store()
        reopened.load(into: container)

        XCTAssertTrue(service.isReady, service.errorMessage ?? "")
        XCTAssertTrue(reopened.isReady, reopened.errorMessage ?? "")
        XCTAssertEqual(try ConfigurationDictionary.capture(in: ModelContext(container)), expected)
        XCTAssertEqual(try root()["dictionary"]?.decoded(as: ConfigurationDictionary.self), expected)
    }

    func testReplacementNormalizationIsStableAcrossRepeatedLoads() throws {
        try write("""
        {"schemaVersion":1,"dictionary":{"sections":[],"vocabulary":[],"replacements":[
            {"sources":["input"],"replacement":"  café  "}
        ]}}
        """)

        for _ in 0..<2 {
            let service = store()
            service.load(into: container)

            XCTAssertTrue(service.isReady, service.errorMessage ?? "")
            let replacement = try XCTUnwrap(ModelContext(container).fetch(FetchDescriptor<WordReplacement>()).first)
            XCTAssertEqual(replacement.replacementText, "café")
            let plan = WordReplacementPlan(rules: [ReplacementRule(
                id: replacement.id.uuidString, sources: ["input"], replacement: replacement.replacementText
            )])
            XCTAssertEqual(plan.apply(to: "an input here"), "an café here")
        }
    }

    func testConflictingRulesWithoutIDsRetainDistinctIdentitiesAndDates() throws {
        try write("""
        {"schemaVersion":1,"dictionary":{"sections":[],"vocabulary":[],"replacements":[
            {"sources":["tone"],"replacement":"alpha"},
            {"sources":["tone"],"replacement":"beta"}
        ]}}
        """)
        let service = store()
        service.load(into: container)
        let before = try ConfigurationDictionary.capture(in: ModelContext(container))

        let reopened = store()
        reopened.load(into: container)

        XCTAssertTrue(reopened.isReady, reopened.errorMessage ?? "")
        XCTAssertEqual(try ConfigurationDictionary.capture(in: ModelContext(container)), before)
        XCTAssertEqual(Set(before.replacements.compactMap(\.id)).count, 2)
    }

    func testRuleWithoutIDCannotTakeAnotherRulesExplicitIdentity() throws {
        let context = ModelContext(container)
        let existing = WordReplacement(originalText: "tone", replacementText: "alpha",
                                       dateAdded: Date(timeIntervalSince1970: 1_700_000_000))
        context.insert(existing)
        try context.save()
        let persistentID = existing.persistentModelID
        try write("""
        {"schemaVersion":1,"dictionary":{"sections":[],"vocabulary":[],"replacements":[
            {"sources":["tone"],"replacement":"beta"},
            {"id":"\(existing.id.uuidString)","sources":["new tone"],"replacement":"alpha"}
        ]}}
        """)
        let service = store()

        service.load(into: container)
        let rules = try ModelContext(container).fetch(FetchDescriptor<WordReplacement>())

        XCTAssertTrue(service.isReady, service.errorMessage ?? "")
        XCTAssertEqual(rules.count, 2)
        XCTAssertEqual(Set(rules.map(\.id)).count, 2)
        let retained = try XCTUnwrap(rules.first(where: { $0.id == existing.id }))
        XCTAssertEqual(retained.persistentModelID, persistentID)
        XCTAssertEqual(retained.originalText, "new tone")
        XCTAssertEqual(retained.dateAdded.timeIntervalSince1970, 1_700_000_000)
    }
}
