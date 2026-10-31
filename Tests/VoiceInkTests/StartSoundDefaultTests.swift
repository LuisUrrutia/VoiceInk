import AVFoundation
import XCTest
@testable import VoiceInk

final class StartSoundDefaultTests: XCTestCase {
    private typealias Sound = CustomSoundManager.BuiltInSound

    private var suite: String!
    private var defaults: UserDefaults!
    private var soundsDirectory: URL!

    override func setUpWithError() throws {
        suite = "StartSoundDefaultTests.\(UUID())"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        soundsDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("VoiceInkSounds-\(UUID())")
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suite)
        defaults = nil
        if FileManager.default.fileExists(atPath: soundsDirectory.path) {
            try FileManager.default.removeItem(at: soundsDirectory)
        }
    }

    private func makeManager(defaults: UserDefaults? = nil) -> CustomSoundManager {
        CustomSoundManager(defaults: defaults ?? self.defaults, customSoundsDirectory: soundsDirectory)
    }

    func testNewInstallStartsWithHexClassicAndKeepsStopSound() {
        let manager = makeManager()

        XCTAssertEqual(manager.soundSelection(for: .start), .builtIn(.hexClassicStart))
        XCTAssertEqual(manager.builtInSound(for: .start)?.url?.lastPathComponent, "hexClassicStart.wav")
        XCTAssertTrue(manager.isDefaultSelection(for: .start))
        XCTAssertEqual(manager.soundSelection(for: .stop), .builtIn(.sound6))
        XCTAssertEqual(manager.builtInSound(for: .stop)?.url?.lastPathComponent, "sound6.mp3")
    }

    func testAppRegistersHexClassicAsStartDefaultAndKeepsStopDefault() throws {
        let registered = try XCTUnwrap(UserDefaults.standard.volatileDomain(forName: UserDefaults.registrationDomain))

        XCTAssertEqual(registered["selectedStartBuiltInSound"] as? String, Sound.hexClassicStart.rawValue)
        XCTAssertEqual(registered["selectedStopBuiltInSound"] as? String, Sound.sound6.rawValue)
    }

    func testStoredPreviousStartSoundIsKept() {
        defaults.set("builtIn", forKey: "selectedStartSoundSelection")
        defaults.set(Sound.sound5.rawValue, forKey: "selectedStartBuiltInSound")

        let manager = makeManager()

        XCTAssertEqual(manager.soundSelection(for: .start), .builtIn(.sound5))
        XCTAssertEqual(manager.builtInSound(for: .start)?.url?.lastPathComponent, "sound5.mp3")
        XCTAssertFalse(manager.isDefaultSelection(for: .start))
    }

    func testCustomAndDisabledStartSoundsAreKept() {
        defaults.set("custom", forKey: "selectedStartSoundSelection")
        defaults.set("CustomStartSound.wav", forKey: "customStartSoundFilename")
        defaults.set("none", forKey: "selectedStopSoundSelection")

        let manager = makeManager()

        XCTAssertEqual(manager.soundSelection(for: .start), .custom("CustomStartSound.wav"))
        XCTAssertEqual(
            manager.getCustomSoundURL(for: .start), soundsDirectory.appendingPathComponent("CustomStartSound.wav"))
        XCTAssertEqual(manager.soundSelection(for: .stop), .none)
    }

    func testPreviousStartSoundRemainsSelectable() {
        let manager = makeManager()

        manager.selectBuiltInSound(.sound5, for: .start)

        XCTAssertTrue(Sound.allCases.contains(.sound5))
        XCTAssertEqual(manager.soundSelection(for: .start), .builtIn(.sound5))
        XCTAssertEqual(defaults.string(forKey: "selectedStartBuiltInSound"), Sound.sound5.rawValue)
        XCTAssertEqual(makeManager().soundSelection(for: .start), .builtIn(.sound5))
    }

    func testResetFromPreviousOrCustomStartSoundReturnsToHexClassic() throws {
        defaults.set("builtIn", forKey: "selectedStartSoundSelection")
        defaults.set(Sound.sound5.rawValue, forKey: "selectedStartBuiltInSound")
        let manager = makeManager()

        manager.resetSoundToDefault(for: .start)

        XCTAssertEqual(manager.soundSelection(for: .start), .builtIn(.hexClassicStart))
        XCTAssertEqual(defaults.string(forKey: "selectedStartBuiltInSound"), Sound.hexClassicStart.rawValue)

        let customFile = soundsDirectory.appendingPathComponent("CustomStartSound.wav")
        try Data("custom".utf8).write(to: customFile)
        defaults.set("custom", forKey: "selectedStartSoundSelection")
        defaults.set(customFile.lastPathComponent, forKey: "customStartSoundFilename")
        let customManager = makeManager()

        customManager.resetSoundToDefault(for: .start)

        XCTAssertEqual(customManager.soundSelection(for: .start), .builtIn(.hexClassicStart))
        XCTAssertFalse(FileManager.default.fileExists(atPath: customFile.path))
        XCTAssertNil(defaults.string(forKey: "customStartSoundFilename"))
        XCTAssertEqual(customManager.soundSelection(for: .stop), .builtIn(.sound6))
    }

    func testConfigurationRoundTripPreservesStartSoundSelections() throws {
        for sound in [Sound.hexClassicStart, .sound5] {
            makeManager().selectBuiltInSound(sound, for: .start)
            let captured = try ConfigurationPreferences.capture(from: defaults)
            XCTAssertEqual(captured["selectedStartBuiltInSound"], .string(sound.rawValue))
            try ConfigurationPreferences.validate(captured)

            let restoredSuite = "StartSoundDefaultTests.restored.\(UUID())"
            let restored = try XCTUnwrap(UserDefaults(suiteName: restoredSuite))
            defer { restored.removePersistentDomain(forName: restoredSuite) }
            try ConfigurationPreferences.apply(captured, to: restored)

            XCTAssertEqual(makeManager(defaults: restored).soundSelection(for: .start), .builtIn(sound))
            XCTAssertEqual(makeManager(defaults: restored).soundSelection(for: .stop), .builtIn(.sound6))
        }
    }

    func testEveryBuiltInSoundIsBundledAndPlayable() throws {
        for sound in Sound.allCases {
            let url = try XCTUnwrap(sound.url, "\(sound.rawValue) is missing from the app bundle")
            XCTAssertNoThrow(try AVAudioPlayer(contentsOf: url), sound.rawValue)
        }

        let file = try AVAudioFile(forReading: try XCTUnwrap(Sound.hexClassicStart.url))
        let duration = Double(file.length) / file.fileFormat.sampleRate
        XCTAssertEqual(file.fileFormat.sampleRate, 44_100)
        XCTAssertEqual(file.fileFormat.channelCount, 2)
        XCTAssertGreaterThan(duration, 0.2)
        XCTAssertLessThan(duration, 0.5)
    }
}
