import Combine
import XCTest

@testable import VoiceInk

final class LabsFeatureTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    private let first = LabsFeature(id: "firstFixture", title: "First", summary: "First fixture.")
    private let second = LabsFeature(id: "secondFixture", title: "Second", summary: "Second fixture.")

    override func setUpWithError() throws {
        suiteName = "LabsFeatureTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
    }

    func testEveryRegisteredFeatureIsOffByDefaultWithAUniqueBooleanPreference() throws {
        let features = LabsFeature.all

        XCTAssertEqual(Set(features.map(\.id)).count, features.count)
        let registered = Labs.registeredDefaults(for: features)
        for feature in features {
            XCTAssertTrue(feature.defaultsKey.hasPrefix("labs."), feature.id)
            XCTAssertEqual(registered[feature.defaultsKey] as? Bool, false, feature.id)
            XCTAssertFalse(Labs.isRetiredKey(feature.defaultsKey), feature.id)

            Labs.setEnabled(true, for: feature, in: defaults)
            XCTAssertEqual(try ConfigurationPreferences.capture(from: defaults)[feature.defaultsKey], .bool(true))
            try ConfigurationPreferences.apply([feature.defaultsKey: .bool(false)], to: defaults)
            XCTAssertFalse(Labs.isEnabled(feature, in: defaults), feature.id)
            XCTAssertThrowsError(
                try ConfigurationPreferences.validate([feature.defaultsKey: .string("on")]), feature.id)
        }
    }

    func testFixtureFeaturesStartOffAndToggleIndependently() {
        XCTAssertFalse(Labs.isEnabled(first, in: defaults))
        XCTAssertFalse(Labs.isEnabled(second, in: defaults))

        Labs.setEnabled(true, for: first, in: defaults)

        XCTAssertTrue(Labs.isEnabled(first, in: defaults))
        XCTAssertFalse(Labs.isEnabled(second, in: defaults))
        XCTAssertEqual(defaults.object(forKey: "labs.firstFixture") as? Bool, true)
    }

    func testEnabledPublisherReportsTheCurrentStateThenEachChangeOnce() {
        Labs.setEnabled(true, for: first, in: defaults)
        var received: [Bool] = []
        let subscription = Labs.enabledPublisher(first, in: defaults).sink { received.append($0) }
        defer { subscription.cancel() }

        Labs.setEnabled(false, for: first, in: defaults)
        Labs.setEnabled(true, for: second, in: defaults)
        Labs.setEnabled(true, for: first, in: defaults)

        XCTAssertEqual(received, [true, false, true])
    }

    func testBackupRestoresListedFeaturesKeepsMissingOnesAndIgnoresUnknownOnes() throws {
        let features = [first, second]
        Labs.setEnabled(true, for: first, in: defaults)
        XCTAssertEqual(Labs.backup(of: features, in: defaults), ["firstFixture": true, "secondFixture": false])

        Labs.restore(["firstFixture": false, "graduatedFeature": true], features: features, in: defaults)
        XCTAssertFalse(Labs.isEnabled(first, in: defaults))
        XCTAssertNil(defaults.object(forKey: "labs.secondFixture"), "a feature missing from the backup keeps its state")
        XCTAssertNil(defaults.object(forKey: "labs.graduatedFeature"))

        Labs.setEnabled(true, for: second, in: defaults)
        Labs.restore(nil, features: features, in: defaults)
        XCTAssertTrue(Labs.isEnabled(second, in: defaults))
    }

    func testGeneralBackupCarriesLabsFeaturesAndOlderBackupsOmitThem() throws {
        let legacy = try JSONDecoder().decode(GeneralBackup.self, from: Data("{}".utf8))
        XCTAssertNil(legacy.labsFeatures)

        let current = try JSONDecoder().decode(
            GeneralBackup.self, from: Data(#"{"labsFeatures":{"firstFixture":true}}"#.utf8))
        let roundTripped = try JSONDecoder().decode(GeneralBackup.self, from: JSONEncoder().encode(current))
        Labs.restore(roundTripped.labsFeatures, features: [first, second], in: defaults)

        XCTAssertTrue(Labs.isEnabled(first, in: defaults))
        XCTAssertNil(defaults.object(forKey: "labs.secondFixture"))
    }

    func testConfigurationLoadsKeysOfFeaturesNoLongerInLabsWithoutApplyingThem() throws {
        XCTAssertTrue(Labs.isRetiredKey("labs.graduatedFeature"))
        XCTAssertFalse(Labs.isRetiredKey("labsSomething"))
        let values: [String: ConfigurationValue] = ["labs.graduatedFeature": .bool(true), "IsVADEnabled": .bool(false)]

        XCTAssertNoThrow(try ConfigurationPreferences.validate(values))
        try ConfigurationPreferences.apply(values, to: defaults)

        XCTAssertNil(defaults.object(forKey: "labs.graduatedFeature"))
        XCTAssertEqual(defaults.object(forKey: "IsVADEnabled") as? Bool, false)
        defaults.set(true, forKey: "labs.graduatedFeature")
        XCTAssertNil(try ConfigurationPreferences.capture(from: defaults)["labs.graduatedFeature"])
        XCTAssertThrowsError(try ConfigurationPreferences.validate(["labsUnknown": .bool(true)]))
    }
}
