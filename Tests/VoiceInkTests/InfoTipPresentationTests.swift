import XCTest
@testable import VoiceInk

final class InfoTipPresentationTests: XCTestCase {
    func testHoverOpensAndLeavingClosesAfterGracePeriod() {
        var tip = InfoTipPresentation()

        let enterSchedulesHide = tip.setHovering(true, over: .icon)
        XCTAssertTrue(tip.isShowing)
        XCTAssertFalse(enterSchedulesHide)

        let leaveSchedulesHide = tip.setHovering(false, over: .icon)
        XCTAssertTrue(tip.isShowing)
        XCTAssertTrue(leaveSchedulesHide)

        tip.hoverGraceEnded()
        XCTAssertFalse(tip.isShowing)
    }

    func testMovingFromIconIntoPopoverKeepsTipOpen() {
        var tip = InfoTipPresentation()
        _ = tip.setHovering(true, over: .icon)

        _ = tip.setHovering(false, over: .icon)
        _ = tip.setHovering(true, over: .tip)
        tip.hoverGraceEnded()

        XCTAssertTrue(tip.isShowing)
    }

    func testReenteringIconBeforeGracePeriodEndsKeepsTipOpen() {
        var tip = InfoTipPresentation()
        _ = tip.setHovering(true, over: .icon)
        _ = tip.setHovering(false, over: .icon)

        _ = tip.setHovering(true, over: .icon)
        tip.hoverGraceEnded()

        XCTAssertTrue(tip.isShowing)
    }

    func testClickPinsTipThroughPointerLeavingAndSecondClickCloses() {
        var tip = InfoTipPresentation()

        tip.togglePinned()
        let leaveSchedulesHide = tip.setHovering(false, over: .icon)
        tip.hoverGraceEnded()

        XCTAssertTrue(tip.isShowing)
        XCTAssertTrue(tip.isPinned)
        XCTAssertFalse(leaveSchedulesHide)

        tip.togglePinned()
        XCTAssertFalse(tip.isShowing)
        XCTAssertFalse(tip.isPinned)
    }

    func testClickOnHoverOpenedTipPinsIt() {
        var tip = InfoTipPresentation()
        _ = tip.setHovering(true, over: .icon)

        tip.togglePinned()
        _ = tip.setHovering(false, over: .icon)
        tip.hoverGraceEnded()

        XCTAssertTrue(tip.isShowing)
        XCTAssertTrue(tip.isPinned)
    }

    func testSystemDismissalClosesAndUnpins() {
        var tip = InfoTipPresentation()
        tip.togglePinned()

        tip.systemDismissed()

        XCTAssertFalse(tip.isShowing)
        XCTAssertFalse(tip.isPinned)
        let reopened = tip.setHovering(true, over: .icon)
        XCTAssertTrue(tip.isShowing)
        XCTAssertFalse(reopened)
    }
}
