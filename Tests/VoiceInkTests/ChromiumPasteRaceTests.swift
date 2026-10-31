import Foundation
import XCTest
@testable import VoiceInk

@MainActor
final class ChromiumPasteRaceTests: XCTestCase {
    func testAffectedChromiumVersionFoldersIncludingStagedUpdates() throws {
        let running156 = try makeBundle(frameworks: ["Google Chrome Framework": ["156.0.8078.74"]])
        let staged156 = try makeBundle(frameworks: ["Helium Framework": ["154.0.8037.57", "156.0.8078.48"]])
        let brave = try makeBundle(frameworks: ["Brave Browser Framework": ["155.1.97.12"]])
        let fixed = try makeBundle(frameworks: ["Google Chrome Framework": ["157.0.8100.1"]])
        let older = try makeBundle(frameworks: ["Helium Framework": ["154.0.8037.57"]])

        XCTAssertEqual(ChromiumPasteRace.chromiumMajorVersions(inBundleAt: running156), [156])
        XCTAssertEqual(ChromiumPasteRace.chromiumMajorVersions(inBundleAt: staged156), [154, 156])
        XCTAssertEqual(ChromiumPasteRace.chromiumMajorVersions(inBundleAt: brave), [155])
        XCTAssertEqual(ChromiumPasteRace.chromiumMajorVersions(inBundleAt: fixed), [157])
        XCTAssertEqual(ChromiumPasteRace.chromiumMajorVersions(inBundleAt: older), [154])
        for (bundle, affected) in [(running156, true), (staged156, true), (brave, true), (fixed, false), (older, false)] {
            XCTAssertEqual(race(for: bundle).losesSyntheticPaste(Self.application), affected, bundle.lastPathComponent)
        }
    }

    func testOpaqueVersionFoldersUseOnlyAFourPartDeclaredVersion() throws {
        let arc = try makeBundle(frameworks: ["ArcCore": ["A"]], declaredVersions: ["ArcCore": "156.0.8078.48"])
        let cef = try makeBundle(
            frameworks: ["Chromium Embedded Framework": ["A"]],
            declaredVersions: ["Chromium Embedded Framework": "151.3.18.0"]
        )
        let electron = try makeBundle(frameworks: ["Electron Framework": ["A"]])
        let ownNumbering = try makeBundle(
            frameworks: ["Aside Framework": ["1.0.1022.1"]], declaredVersions: ["Aside Framework": "1.0.1022.1"]
        )
        let sparkle = try makeBundle(frameworks: ["Sparkle": ["B"]], declaredVersions: ["Sparkle": "2.6.4"])

        XCTAssertEqual(ChromiumPasteRace.chromiumMajorVersions(inBundleAt: arc), [156])
        XCTAssertEqual(ChromiumPasteRace.chromiumMajorVersions(inBundleAt: cef), [151])
        XCTAssertEqual(ChromiumPasteRace.chromiumMajorVersions(inBundleAt: electron), [])
        XCTAssertEqual(ChromiumPasteRace.chromiumMajorVersions(inBundleAt: ownNumbering), [1])
        XCTAssertEqual(ChromiumPasteRace.chromiumMajorVersions(inBundleAt: sparkle), [])
        XCTAssertTrue(race(for: arc).losesSyntheticPaste(Self.application))
    }

    func testIgnoresUnversionedBundlesAndMalformedVersions() throws {
        let webAppShim = try makeBundle(frameworks: [:])
        let unrelatedFramework = try makeBundle(frameworks: ["Helper": ["156.0.8078.74"]])
        let malformed = try makeBundle(frameworks: ["Chromium Framework": ["156.0.8078", "156.0.8078.74.1", "156.x.8078.74", "١٥٦.0.8078.74"]])

        XCTAssertEqual(ChromiumPasteRace.chromiumMajorVersions(inBundleAt: webAppShim), [])
        XCTAssertEqual(ChromiumPasteRace.chromiumMajorVersions(inBundleAt: unrelatedFramework), [])
        XCTAssertEqual(ChromiumPasteRace.chromiumMajorVersions(inBundleAt: malformed), [])
        XCTAssertFalse(ChromiumPasteRace { _ in nil }.losesSyntheticPaste(Self.application))
    }

    func testCurrentSymlinkIsNotCountedTwice() throws {
        let bundle = try makeBundle(frameworks: ["Google Chrome Framework": ["156.0.8078.74"]])
        let versions = bundle.appending(path: "Contents/Frameworks/Google Chrome Framework.framework/Versions")
        try FileManager.default.createSymbolicLink(
            at: versions.appending(path: "Current"), withDestinationURL: versions.appending(path: "156.0.8078.74")
        )

        XCTAssertEqual(ChromiumPasteRace.chromiumMajorVersions(inBundleAt: bundle), [156])
    }

    func testCachesTheDecisionPerProcessLaunch() throws {
        let affected = try makeBundle(frameworks: ["Google Chrome Framework": ["156.0.8078.74"]])
        let fixed = try makeBundle(frameworks: ["Google Chrome Framework": ["157.0.8100.1"]])
        var lookups: [PasteApplication] = []
        var bundle = affected
        let race = ChromiumPasteRace { lookups.append($0); return bundle }
        let relaunched = PasteApplication(
            processID: 401, bundleIdentifier: Self.application.bundleIdentifier, launchDate: Date(timeIntervalSince1970: 2)
        )

        XCTAssertTrue(race.losesSyntheticPaste(Self.application))
        bundle = fixed
        XCTAssertTrue(race.losesSyntheticPaste(Self.application))
        XCTAssertFalse(race.losesSyntheticPaste(relaunched))

        XCTAssertEqual(lookups, [Self.application, relaunched])
    }

    func testTypedChunksKeepUnitLimitSurrogatePairsAndLineBreaks() throws {
        let ascii = String(repeating: "a", count: 45)
        let emojiAtBoundary = String(repeating: "b", count: 19) + "😀c"

        let asciiChunks = try XCTUnwrap(DirectTextTyper.unicodeChunks(for: ascii))
        let emojiChunks = try XCTUnwrap(DirectTextTyper.unicodeChunks(for: emojiAtBoundary))
        let lineChunks = try XCTUnwrap(DirectTextTyper.unicodeChunks(for: "one\r\ntwo\nthree\rfour"))

        XCTAssertEqual(asciiChunks.map(\.count), [20, 20, 5])
        XCTAssertEqual(emojiChunks.map(\.count), [19, 3])
        XCTAssertEqual(String(utf16CodeUnits: emojiChunks[1], count: emojiChunks[1].count), "😀c")
        XCTAssertEqual(lineChunks.map { String(utf16CodeUnits: $0, count: $0.count) }, ["one", "\r", "two", "\r", "three", "\r", "four"])
        XCTAssertNil(DirectTextTyper.unicodeChunks(for: "bell\u{07}"))
    }

    private static let application = PasteApplication(
        processID: 400, bundleIdentifier: "com.google.Chrome", launchDate: Date(timeIntervalSince1970: 1)
    )

    private func race(for bundle: URL) -> ChromiumPasteRace {
        ChromiumPasteRace { _ in bundle }
    }

    private func makeBundle(
        frameworks: [String: [String]], declaredVersions: [String: String] = [:]
    ) throws -> URL {
        let bundle = FileManager.default.temporaryDirectory
            .appending(path: "ChromiumPasteRaceTests-\(UUID().uuidString).app", directoryHint: .isDirectory)
        addTeardownBlock { try? FileManager.default.removeItem(at: bundle) }
        let frameworksDirectory = bundle.appending(path: "Contents/Frameworks", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: frameworksDirectory, withIntermediateDirectories: true)
        for (name, versions) in frameworks {
            for version in versions {
                let resources = frameworksDirectory
                    .appending(path: "\(name).framework/Versions/\(version)/Resources", directoryHint: .isDirectory)
                try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
                var info: [String: String] = ["CFBundleVersion": "44.9.1"]
                if let declared = declaredVersions[name] { info["CFBundleShortVersionString"] = declared }
                try (info as NSDictionary).write(to: resources.appending(path: "Info.plist"))
            }
        }
        return bundle
    }
}
