import XCTest

@testable import VoiceInk

@MainActor final class NavigationTests: XCTestCase {
    func testSidebarKeepsEveryFeatureReachableExactlyOnce() {
        let destinations = ViewType.sidebarGroups.flatMap { $0 }

        let available = ViewType.allCases.filter { $0.isAvailable() }
        XCTAssertEqual(Set(destinations), Set(available))
        XCTAssertEqual(destinations.count, available.count)
        XCTAssertEqual(ViewType.sidebarGroups.first, [.dashboard, .modes, .dictionary])
        XCTAssertEqual(ViewType.allCases.count, 11)
    }

    func testMeetingsAppearsWithHistoryOnlyWhileItsLabsSwitchIsOn() {
        let suiteName = "NavigationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertFalse(ViewType.meetings.isAvailable(defaults: defaults))
        XCTAssertFalse(ViewType.sidebarGroups(labsFeatures: LabsFeature.all, defaults: defaults).joined().contains(.meetings))

        Labs.setEnabled(true, for: .meetings, in: defaults)

        XCTAssertTrue(ViewType.meetings.isAvailable(defaults: defaults))
        XCTAssertEqual(ViewType.sidebarGroups(labsFeatures: LabsFeature.all, defaults: defaults)[2], [.history, .transcribeAudio, .meetings])
        Labs.setEnabled(true, for: .annotate, in: defaults)
        XCTAssertEqual(
            ViewType.sidebarGroups(labsFeatures: LabsFeature.all, defaults: defaults)[2], [.history, .transcribeAudio, .meetings, .annotations]
        )
        XCTAssertEqual(ViewType.annotations.labsFeature, .annotate)
        XCTAssertFalse(ViewType.meetings.isAvailable(labsFeatures: [], defaults: defaults))
    }

    func testLabsIsTheLastSidebarItemOnlyWhileItListsAFeature() {
        let feature = LabsFeature(id: "navigationFixture", title: "Fixture", summary: "Fixture.")
        let featureDestinations = ViewType.allCases.filter { $0 != .labs && $0.labsFeature == nil }

        XCTAssertEqual(Set(ViewType.sidebarGroups(labsFeatures: []).flatMap { $0 }), Set(featureDestinations))
        XCTAssertFalse(ViewType.labs.isAvailable(labsFeatures: []))
        XCTAssertEqual(ViewType.sidebarGroups(labsFeatures: [feature]).last, [.labs])
        XCTAssertEqual(Array(ViewType.sidebarGroups(labsFeatures: [feature]).dropLast()), ViewType.sidebarGroups(labsFeatures: []))
        XCTAssertTrue(ViewType.labs.isAvailable(labsFeatures: [feature]))
    }

    func testExistingNotificationRoutesStillResolve() {
        let navigation = MainWindowNavigation.shared
        let original = navigation.selectedView
        defer { navigation.navigate(to: original) }

        for destination in ViewType.allCases where destination.isAvailable() {
            navigation.navigate(to: destination.rawValue)
            XCTAssertEqual(navigation.selectedView, destination)
        }
        navigation.navigate(to: .models)
        navigation.navigate(to: "unknown")
        XCTAssertEqual(navigation.selectedView, .models)
        if !ViewType.labs.isAvailable() {
            navigation.navigate(to: ViewType.labs.rawValue)
            XCTAssertEqual(navigation.selectedView, .models)
        }
    }
}
