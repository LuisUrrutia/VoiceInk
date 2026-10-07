import XCTest

@testable import VoiceInk

@MainActor final class NavigationTests: XCTestCase {
    func testSidebarKeepsEveryFeatureReachableExactlyOnce() {
        let destinations = ViewType.sidebarGroups.flatMap { $0 }

        XCTAssertEqual(Set(destinations), Set(ViewType.allCases))
        XCTAssertEqual(destinations.count, ViewType.allCases.count)
        XCTAssertEqual(ViewType.sidebarGroups.first, [.dashboard, .modes, .dictionary])
        XCTAssertEqual(ViewType.allCases.count, 8)
    }

    func testExistingNotificationRoutesStillResolve() {
        let navigation = MainWindowNavigation.shared
        let original = navigation.selectedView
        defer { navigation.navigate(to: original) }

        for destination in ViewType.allCases {
            navigation.navigate(to: destination.rawValue)
            XCTAssertEqual(navigation.selectedView, destination)
        }
        navigation.navigate(to: .models)
        navigation.navigate(to: "unknown")
        XCTAssertEqual(navigation.selectedView, .models)
    }
}
