import XCTest
@testable import VoiceInk

final class SoundPlaybackEngineTests: XCTestCase {
    private let startURL = URL(fileURLWithPath: "/fixture/start.wav")
    private let stopURL = URL(fileURLWithPath: "/fixture/stop.wav")
    private let missingURL = URL(fileURLWithPath: "/fixture/missing.wav")

    func testStartToneRetractedBeforeItSoundsStaysSilent() {
        let (engine, factory) = makeEngine()

        engine.scheduleStart(after: 0.05)
        engine.retractStart()
        Thread.sleep(forTimeInterval: 0.15)
        engine.waitUntilIdle()

        XCTAssertEqual(factory.players(for: startURL).map(\.plays), [0])
    }

    func testPlayingStartToneFadesOutAndANewStartSurvivesTheFade() throws {
        let (engine, factory) = makeEngine()
        engine.scheduleStart(after: 0)
        Thread.sleep(forTimeInterval: 0.05)
        engine.waitUntilIdle()
        let player = try XCTUnwrap(factory.players(for: startURL).first)
        XCTAssertEqual(player.plays, 1)

        engine.retractStart(fadeDuration: 0.02)
        engine.waitUntilIdle()
        XCTAssertEqual(player.fades.last?.volume, 0)
        XCTAssertEqual(player.fades.last?.duration, 0.02)
        XCTAssertTrue(player.isPlaying)
        Thread.sleep(forTimeInterval: 0.08)
        engine.waitUntilIdle()
        XCTAssertFalse(player.isPlaying)
        XCTAssertEqual(player.volume, 0.3)
        XCTAssertEqual(player.currentTime, 0)

        engine.scheduleStart(after: 0)
        Thread.sleep(forTimeInterval: 0.05)
        engine.retractStart(fadeDuration: 0.05)
        engine.scheduleStart(after: 0)
        Thread.sleep(forTimeInterval: 0.15)
        engine.waitUntilIdle()
        XCTAssertEqual(player.plays, 3)
        XCTAssertTrue(player.isPlaying)
        XCTAssertEqual(player.volume, 0.3)
    }

    func testDefaultOutputChangeRebuildsPlayersSoTonesUseTheNewOutput() {
        let (engine, factory) = makeEngine()
        engine.play(.stop)
        engine.waitUntilIdle()

        engine.defaultOutputDidChange()
        engine.waitUntilIdle()
        XCTAssertEqual(factory.players(for: startURL).count, 2, "Idle players are rebuilt at once")
        XCTAssertEqual(factory.players(for: stopURL).count, 1, "A playing tone keeps its player")
        engine.play(.start)
        engine.play(.stop)
        engine.waitUntilIdle()

        XCTAssertEqual(factory.players(for: startURL).map(\.plays), [0, 1])
        XCTAssertEqual(factory.players(for: stopURL).map(\.plays), [1, 1])
    }

    func testMissingCustomSoundFallsBackToItsBuiltInSound() {
        let factory = PlayerFactory(missing: [missingURL])
        let engine = SoundPlaybackEngine(makePlayer: factory.make, observesDefaultOutput: false)
        engine.setup([.error: [.init(url: missingURL, volume: 1), .init(url: stopURL, volume: 0.55)]])

        engine.play(.error)
        engine.waitUntilIdle()

        XCTAssertEqual(factory.players(for: stopURL).map(\.plays), [1])
        XCTAssertEqual(factory.players(for: stopURL).first?.volume, 0.55)
    }

    private func makeEngine() -> (SoundPlaybackEngine, PlayerFactory) {
        let factory = PlayerFactory()
        let engine = SoundPlaybackEngine(makePlayer: factory.make, observesDefaultOutput: false)
        engine.setup([.start: [.init(url: startURL, volume: 0.3)], .stop: [.init(url: stopURL, volume: 0.3)]])
        engine.waitUntilIdle()
        return (engine, factory)
    }

    private final class FakePlayer: SoundPlayer {
        let url: URL
        var isPlaying = false
        var volume: Float = 1
        var currentTime: TimeInterval = 0
        var duration: TimeInterval = 0.4
        var plays = 0
        var fades: [(volume: Float, duration: TimeInterval)] = []

        init(url: URL) { self.url = url }
        func prepareToPlay() -> Bool { true }
        func play() -> Bool {
            plays += 1
            isPlaying = true
            return true
        }
        func stop() { isPlaying = false }
        func setVolume(_ volume: Float, fadeDuration: TimeInterval) {
            if fadeDuration == 0 { self.volume = volume } else { fades.append((volume, fadeDuration)) }
        }
    }

    private final class PlayerFactory {
        private let missing: Set<URL>
        private let lock = NSLock()
        private var created: [FakePlayer] = []

        init(missing: Set<URL> = []) { self.missing = missing }

        func make(_ url: URL) throws -> SoundPlayer {
            guard !missing.contains(url) else { throw CocoaError(.fileNoSuchFile) }
            let player = FakePlayer(url: url)
            lock.withLock { created.append(player) }
            return player
        }

        func players(for url: URL) -> [FakePlayer] {
            lock.withLock { created.filter { $0.url == url } }
        }
    }
}

final class FeedbackSoundSettingsTests: XCTestCase {
    func testDoneAndErrorDefaultsUseBundledSoftToneAndMacOSBasso() {
        let manager = CustomSoundManager(defaults: makeDefaults(), customSoundsDirectory: makeDirectory())

        XCTAssertEqual(manager.soundSelection(for: .done), .builtIn(.softTone))
        XCTAssertEqual(manager.soundSelection(for: .error), .builtIn(.basso))
        XCTAssertNotNil(CustomSoundManager.BuiltInSound.softTone.url)
        XCTAssertEqual(CustomSoundManager.BuiltInSound.basso.url?.lastPathComponent, "Basso.aiff")
        XCTAssertEqual(manager.soundSelection(for: .start), .builtIn(.hexClassicStart))
        XCTAssertEqual(manager.soundSelection(for: .stop), .builtIn(.sound6))
    }

    func testDoneAndErrorSelectionsPersistAndCanBeDisabledOrReset() {
        let defaults = makeDefaults()
        let directory = makeDirectory()
        let manager = CustomSoundManager(defaults: defaults, customSoundsDirectory: directory)

        manager.selectNoSound(for: .done)
        manager.selectBuiltInSound(.sound3, for: .error)
        let reloaded = CustomSoundManager(defaults: defaults, customSoundsDirectory: directory)

        XCTAssertEqual(reloaded.soundSelection(for: .done), .none)
        XCTAssertFalse(reloaded.isSoundEnabled(for: .done))
        XCTAssertEqual(reloaded.soundSelection(for: .error), .builtIn(.sound3))
        reloaded.resetSoundToDefault(for: .done)
        XCTAssertTrue(reloaded.isDefaultSelection(for: .done))
        XCTAssertEqual(defaults.string(forKey: "selectedDoneSoundSelection"), "builtIn")
        XCTAssertEqual(defaults.string(forKey: "selectedErrorBuiltInSound"), "sound3")
    }

    func testCustomDoneSoundUsesItsCopiedFileAndBuiltInFallback() async throws {
        let directory = makeDirectory()
        let manager = CustomSoundManager(defaults: makeDefaults(), customSoundsDirectory: directory)
        let source = try XCTUnwrap(CustomSoundManager.BuiltInSound.sound7.url)

        let result = await manager.setCustomSound(url: source, for: .done)

        XCTAssertNoThrow(try result.get())
        XCTAssertEqual(manager.soundSelection(for: .done), .custom("CustomDoneSound.wav"))
        XCTAssertEqual(manager.getCustomSoundURL(for: .done), directory.appendingPathComponent("CustomDoneSound.wav"))
        XCTAssertEqual(manager.builtInSound(for: .done), .softTone)
    }

    func testLegacyDisabledSoundFeedbackAlsoSilencesDoneAndError() {
        let defaults = makeDefaults()
        defaults.set(false, forKey: "isSoundFeedbackEnabled")

        let manager = CustomSoundManager(defaults: defaults, customSoundsDirectory: makeDirectory())

        for type in CustomSoundManager.SoundType.allCases {
            XCTAssertEqual(manager.soundSelection(for: type), .none, "\(type)")
        }
    }

    func testGeneralBackupRoundTripsFeedbackSoundsAndKeepsMissingTypes() throws {
        let source = CustomSoundManager(defaults: makeDefaults(), customSoundsDirectory: makeDirectory())
        source.selectNoSound(for: .done)
        source.selectBuiltInSound(.sound2, for: .error)
        source.selectBuiltInSound(.sound1, for: .start)
        let json = try JSONEncoder().encode(["feedbackSounds": source.backup()])
        let general = try JSONDecoder().decode(GeneralBackup.self, from: json)
        let target = CustomSoundManager(defaults: makeDefaults(), customSoundsDirectory: makeDirectory())

        target.restore(try XCTUnwrap(general.feedbackSounds))

        for type in CustomSoundManager.SoundType.allCases {
            XCTAssertEqual(target.soundSelection(for: type), source.soundSelection(for: type), "\(type)")
        }
        target.restore(["error": .init(selection: "custom", builtInSound: "sound4", customFilename: "Absent.wav")])
        XCTAssertEqual(target.soundSelection(for: .error), .builtIn(.sound4))
        XCTAssertEqual(target.soundSelection(for: .done), .none)
        let legacy = try JSONDecoder().decode(GeneralBackup.self, from: Data("{}".utf8))
        XCTAssertNil(legacy.feedbackSounds)
    }

    func testConfigurationFileCapturesDoneAndErrorSounds() throws {
        let defaults = makeDefaults()
        let manager = CustomSoundManager(defaults: defaults, customSoundsDirectory: makeDirectory())
        manager.selectNoSound(for: .done)
        manager.selectBuiltInSound(.sound4, for: .error)
        defaults.set("CustomErrorSound.wav", forKey: "customErrorSoundFilename")

        let captured = try ConfigurationPreferences.capture(from: defaults)

        XCTAssertEqual(captured["selectedDoneSoundSelection"], .string("none"))
        XCTAssertEqual(captured["selectedErrorSoundSelection"], .string("builtIn"))
        XCTAssertEqual(captured["selectedErrorBuiltInSound"], .string("sound4"))
        XCTAssertEqual(captured["customErrorSoundFilename"], .string("CustomErrorSound.wav"))
    }

    private func makeDefaults() -> UserDefaults {
        let name = "FeedbackSoundSettingsTests.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    private func makeDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FeedbackSoundSettingsTests-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }
}
