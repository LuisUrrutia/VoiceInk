import AVFoundation
import Foundation
import XCTest
@testable import ParakeetCLI
import TranscriptionText

final class ContractTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("voiceink-cli-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    func testDependencyRevisionMatchesApp() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        func fluidRevision(_ url: URL) throws -> String? {
            let root = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
            let pins = root?["pins"] as? [[String: Any]]
            let pin = pins?.first { $0["identity"] as? String == "fluidaudio" }
            return (pin?["state"] as? [String: Any])?["revision"] as? String
        }
        let app = try fluidRevision(root.appendingPathComponent("VoiceInk.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"))
        let cli = try fluidRevision(root.appendingPathComponent("cli/parakeet/Package.resolved"))

        XCTAssertNotNil(app)
        XCTAssertEqual(cli, app)
    }

    func testInvocationAndExitCodes() async throws {
        var output = Data()
        var errors: [String] = []

        let help = await CLIApplication.run(arguments: ["--help"], stdout: { output.append($0) }, stderr: { errors.append($0) })
        let invalid = await CLIApplication.run(arguments: ["--format", "html", "a.wav"], stdout: { output.append($0) }, stderr: { errors.append($0) })
        let missing = await CLIApplication.run(arguments: ["--model-directory", directory.path, "--quiet", "a.wav"], stdout: { output.append($0) }, stderr: { errors.append($0) })

        XCTAssertEqual(help, 0)
        XCTAssertTrue(String(decoding: output, as: UTF8.self).contains("Usage:"))
        XCTAssertEqual(invalid, 2)
        XCTAssertEqual(missing, 1)
        XCTAssertTrue(errors.last?.contains("never downloads") == true)
        XCTAssertThrowsError(try Options.parse(["--lang", "ja", "a.wav"]))
        XCTAssertThrowsError(try Options.parse(["--model", "v2", "--lang", "es", "a.wav"]))
        XCTAssertThrowsError(try Options.parse(["a.wav", "b.wav"]))
        XCTAssertThrowsError(try Options.parse(["--skip-existing", "a.wav"]))
        XCTAssertThrowsError(try Options.parse(["--output"]))
        XCTAssertEqual(try Options.parse(["--", "-audio.wav"]).inputs.first?.lastPathComponent, "-audio.wav")
        XCTAssertEqual(try Options.parse(["--lang", "auto", "a.wav"]).language, "auto")
    }

    func testDefaultsFlagsAndSnapshotImmutability() throws {
        let defaults = Settings()
        XCTAssertTrue(defaults.vadEnabled)
        XCTAssertTrue(defaults.formatEnabled)
        XCTAssertEqual(defaults.language, "en")
        XCTAssertEqual(defaults.fillerWords, TranscriptionTextDefaults.fillerWords)
        let preferences = directory.appendingPathComponent("settings.plist")
        let dictionary = directory.appendingPathComponent("dictionary.json")
        let plist = try PropertyListSerialization.data(fromPropertyList: ["IsVADEnabled": false, "FillerWords": ["eh"]], format: .binary, options: 0)
        let export = Data("""
        {"format":"voiceink.dictionary","schemaVersion":2,"replacements":[
        {"sources":["hello"],"replacement":"Hola $1\\\\world","enabled":true},
        {"sources":["world"],"replacement":"disabled","enabled":false}]}
        """.utf8)
        try plist.write(to: preferences)
        try export.write(to: dictionary)
        let options = try Options.parse(["--preferences", preferences.path, "--dictionary", dictionary.path,
                                         "--namespace", "local", "--no-format", "--lang", "es", "audio.wav"])

        let settings = try Settings.load(options)
        let overridden = try Settings.load(Options.parse(["--preferences", preferences.path, "--no-vad", "--no-format", "--keep-fillers", "--no-replacements", "audio.wav"]))

        XCTAssertFalse(settings.vadEnabled)
        XCTAssertFalse(settings.formatEnabled)
        XCTAssertEqual(settings.language, "es")
        XCTAssertEqual(settings.process("eh, hello world [music]"), "Hola $1\\world world")
        XCTAssertEqual(overridden.process("eh, hello"), "eh, hello")
        XCTAssertEqual(try Data(contentsOf: preferences), plist)
        XCTAssertEqual(try Data(contentsOf: dictionary), export)
        XCTAssertEqual(AppNamespace.development.domain, "com.prakashjoshipax.VoiceInk.dev")
        XCTAssertEqual(AppNamespace.local.storeDirectoryName, "com.prakashjoshipax.VoiceInk.local")
        XCTAssertNotEqual(AppNamespace.production.storeDirectoryName, AppNamespace.development.storeDirectoryName)
        XCTAssertThrowsError(try Settings.dictionaryPlan(from: preferences))
    }

    func testSharedCleanupAndReplacementBoundaries() {
        let settings = Settings()
        let input = "um, Café [music] <tag>secret</tag> 東京."

        XCTAssertEqual(settings.process(input, paragraphs: false), TranscriptionTextFilter.filter(input, fillerWords: TranscriptionTextDefaults.fillerWords))
        XCTAssertEqual(settings.process(input), ParagraphFormatter.format(TranscriptionTextFilter.filter(input, fillerWords: TranscriptionTextDefaults.fillerWords)))
        let plan = WordReplacementPlan(rules: [
            ReplacementRule(id: "1", sources: ["new york", "nyc"], replacement: "NY"),
            ReplacementRule(id: "2", sources: ["york"], replacement: "Y"),
            ReplacementRule(id: "3", sources: ["東京"], replacement: "Tokyo"),
            ReplacementRule(id: "4", sources: [""], replacement: "BAD"),
        ])
        XCTAssertEqual(plan.apply(to: "New York, NYC and yorkshire; 東京駅"), "NY, NY and yorkshire; Tokyo駅")
    }

    func testOriginalTimelineAndJoinConvention() throws {
        let timeline = try SpeechTimeline(ranges: [16_000..<32_000, 80_000..<112_000], originalCount: 160_000)

        XCTAssertEqual(timeline.originalTime(0.5, isEnd: false), 1.5)
        XCTAssertEqual(timeline.originalTime(1, isEnd: false), 5)
        XCTAssertEqual(timeline.originalTime(1, isEnd: true), 2)
        XCTAssertEqual(timeline.originalTime(2, isEnd: true), 6)
        XCTAssertEqual(timeline.originalTime(100, isEnd: true), 7)
        XCTAssertEqual(timeline.originalTime(-1, isEnd: false), 1)
        XCTAssertEqual(timeline.speechCount, 48_000)
        XCTAssertThrowsError(try SpeechTimeline(ranges: [10..<20, 15..<25], originalCount: 30))
        XCTAssertThrowsError(try SpeechTimeline(ranges: [0..<31], originalCount: 30))
    }

    func testUnicodeJSONAndSRTOrdering() throws {
        let transcript = Transcript(text: "Café 東京 👋", segments: [
            TimedSegment(start: 59.9996, end: 61.02, text: "Café 東京 👋"),
            TimedSegment(start: 60, end: 62, text: "next"),
        ], duration: 62, speechDuration: 3, vadApplied: true)

        let json = try JSONSerialization.jsonObject(with: transcript.render(.json)) as! [String: Any]
        let srt = String(decoding: try transcript.render(.srt), as: UTF8.self)

        XCTAssertEqual(json["text"] as? String, "Café 東京 👋")
        XCTAssertTrue(srt.contains("00:01:00,000 --> 00:01:01,020"))
        XCTAssertTrue(srt.contains("00:01:01,020 --> 00:01:02,000"))
        XCTAssertTrue(srt.contains("Café 東京 👋"))
        XCTAssertEqual(Transcript.timestamp(3_600_001), "01:00:00,001")
        XCTAssertEqual(String(decoding: try transcript.render(.txt), as: UTF8.self), "Café 東京 👋\n")
    }

    func testBatchContinuesAndProgressNeverReachesStdout() async throws {
        let output = directory.appendingPathComponent("out")
        let options = try Options.parse(["--output", output.path, "bad.wav", "good.wav"])
        var stdout = Data()
        var messages: [String] = []
        var processed: [String] = []
        let runner = BatchRunner(makeProcessor: {
            return { url in
                processed.append(url.lastPathComponent)
                if url.lastPathComponent == "bad.wav" { throw CLIError.message("corrupt audio") }
                return Transcript(text: "Éxito", segments: [], duration: 1, speechDuration: 1, vadApplied: false)
            }
        }, stdout: { stdout.append($0) }, stderr: { messages.append($0) })

        let code = await runner.run(options, jobs: try OutputFiles.plan(options))

        XCTAssertEqual(code, 1)
        XCTAssertEqual(processed, ["bad.wav", "good.wav"])
        XCTAssertTrue(stdout.isEmpty)
        XCTAssertTrue(messages.contains { $0.contains("corrupt audio") })
        XCTAssertEqual(try String(contentsOf: output.appendingPathComponent("good.txt"), encoding: .utf8), "Éxito\n")
    }

    func testSkipExistingNeverLoadsModelOrSettings() async throws {
        let output = directory.appendingPathComponent("existing.txt")
        try Data("preserved".utf8).write(to: output)
        var stdout = Data()
        var errors: [String] = []

        let code = await CLIApplication.run(arguments: ["--quiet", "--skip-existing", "--output", output.path,
                                                       "--model-directory", directory.path, "--preferences", "/missing.plist", "missing.wav"],
                                            stdout: { stdout.append($0) }, stderr: { errors.append($0) })

        XCTAssertEqual(code, 0)
        XCTAssertTrue(stdout.isEmpty)
        XCTAssertTrue(errors.isEmpty)
        XCTAssertEqual(try String(contentsOf: output, encoding: .utf8), "preserved")
    }

    func testOutputCollisionsAliasesAndAtomicNoClobber() throws {
        let input = directory.appendingPathComponent("audio.wav")
        let alias = directory.appendingPathComponent("alias.txt")
        try Data("audio".utf8).write(to: input)
        try FileManager.default.linkItem(at: input, to: alias)

        XCTAssertThrowsError(try OutputFiles.plan(Options.parse(["--output", input.path, input.path])))
        XCTAssertThrowsError(try OutputFiles.plan(Options.parse(["--output", alias.path, input.path])))
        XCTAssertThrowsError(try OutputFiles.plan(Options.parse(["--output", directory.path, "one/same.wav", "two/same.mp3"])))
        let existing = directory.appendingPathComponent("existing.txt")
        try Data("old".utf8).write(to: existing)
        try OutputFiles.write(Data("new".utf8), to: existing, skipExisting: true, protected: [input])
        XCTAssertEqual(try String(contentsOf: existing, encoding: .utf8), "old")
        try OutputFiles.write(Data("new".utf8), to: existing, skipExisting: false, protected: [input])
        XCTAssertEqual(try String(contentsOf: existing, encoding: .utf8), "new")
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.hasPrefix(".voiceink-") })
        XCTAssertEqual(try String(contentsOf: input, encoding: .utf8), "audio")
    }

    func testDecoderResamplingDurationAndTailAcrossChunks() async throws {
        for rate in [16_000.0, 44_100.0, 48_000.0] {
            let url = try fixture(rate: rate, channels: 2, seconds: 1.73)

            let samples = try await AudioDecoder.decode(url)

            XCTAssertEqual(Double(samples.count) / 16_000, 1.73, accuracy: 0.003)
            XCTAssertTrue(samples.allSatisfy(\.isFinite))
            XCTAssertGreaterThan(samples.suffix(160).map(abs).max() ?? 0, 0.05)
            XCTAssertLessThan(samples.map(abs).max() ?? 1, 0.4)
        }
    }

    func testDecoderShortSilentEmptyAndCorruptAudio() async throws {
        let short = try fixture(rate: 48_000, channels: 1, seconds: 0.025)
        let silent = try fixture(rate: 16_000, channels: 1, seconds: 0.1, silent: true)
        let corrupt = directory.appendingPathComponent("corrupt.wav")
        let empty = directory.appendingPathComponent("empty.wav")
        try Data("not a wav file".utf8).write(to: corrupt)
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        _ = try AVAudioFile(forWriting: empty, settings: format.settings)

        let shortSamples = try await AudioDecoder.decode(short)
        let silentSamples = try await AudioDecoder.decode(silent)

        XCTAssertEqual(shortSamples.count, 400, accuracy: 32)
        XCTAssertTrue(silentSamples.allSatisfy { $0 == 0 })
        for url in [corrupt, empty] {
            do { _ = try await AudioDecoder.decode(url); XCTFail("Expected decode failure") }
            catch { XCTAssertFalse(error.localizedDescription.isEmpty) }
        }
    }

    private func fixture(rate: Double, channels: AVAudioChannelCount, seconds: Double, silent: Bool = false) throws -> URL {
        let url = directory.appendingPathComponent("\(UUID().uuidString).wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(rate * seconds))!
        buffer.frameLength = buffer.frameCapacity
        for frame in 0..<Int(buffer.frameLength) {
            for channel in 0..<Int(channels) {
                buffer.floatChannelData![channel][frame] = silent ? 0 : Float(sin(Double(frame) * 2 * .pi * 440 / rate)) * (channel == 0 ? 0.2 : 0.4)
            }
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        return url
    }
}
