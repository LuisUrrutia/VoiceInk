import XCTest

@testable import VoiceInk

@MainActor final class MainWindowRequestTests: XCTestCase {
    func testTwoSceneRegistrationsHandleEachNotificationOnce() {
        let center = NotificationCenter()
        var opens = 0
        let coordinator = MainWindowRequestCoordinator(
            notificationCenter: center, showExistingWindow: { false }, prepareWindow: {}
        )
        coordinator.configureOpener { opens += 1 }
        coordinator.configureOpener { opens += 1 }

        center.post(name: .showMainWindowRequested, object: nil)

        XCTAssertEqual(opens, 1)
        withExtendedLifetime(coordinator) {}
    }

    func testOpenerRemainsAvailableAfterMenuSceneDisappears() {
        var opens = 0
        let coordinator = MainWindowRequestCoordinator(
            notificationCenter: NotificationCenter(), showExistingWindow: { false }, prepareWindow: {}
        )
        coordinator.configureOpener { opens += 1 }

        let handled = coordinator.requestWindow()

        XCTAssertTrue(handled)
        XCTAssertEqual(opens, 1)
    }

    func testEarlyRequestsWaitForSwiftUIOpenerAndCoalesce() {
        let center = NotificationCenter()
        var opens = 0
        var preparations = 0
        let coordinator = MainWindowRequestCoordinator(
            notificationCenter: center, showExistingWindow: { false }, prepareWindow: { preparations += 1 }
        )
        center.post(name: .showMainWindowRequested, object: nil)
        center.post(name: .showMainWindowRequested, object: nil)
        XCTAssertEqual(opens, 0)

        coordinator.configureOpener { opens += 1 }

        XCTAssertEqual(opens, 1)
        XCTAssertGreaterThan(preparations, 0)
    }

    func testExistingWindowIsRestoredWithoutOpeningAnotherScene() {
        var restores = 0
        var opens = 0
        let coordinator = MainWindowRequestCoordinator(
            notificationCenter: NotificationCenter(),
            showExistingWindow: { restores += 1; return true },
            prepareWindow: { XCTFail("An existing window needs no preparation") }
        )
        coordinator.configureOpener { opens += 1 }

        let handled = coordinator.requestWindow()

        XCTAssertTrue(handled)
        XCTAssertEqual(restores, 1)
        XCTAssertEqual(opens, 0)
    }
}
