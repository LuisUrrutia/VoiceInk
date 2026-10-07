import XCTest
@testable import VoiceInk

final class ScreenCaptureTests: XCTestCase {
    func testWindowOnOffsetDisplayUsesDisplayRelativeCoordinates() throws {
        let display = CGRect(x: -1920, y: -300, width: 1920, height: 1080)
        let window = CGRect(x: -1800, y: -200, width: 800, height: 600)

        let region = try XCTUnwrap(WindowCaptureRegion(windowFrame: window, displayFrames: [display]))

        XCTAssertEqual(region.sourceRect, CGRect(x: 120, y: 100, width: 800, height: 600))
        XCTAssertEqual(region.pixelSize(pointPixelScale: 2), CGSize(width: 1600, height: 1200))
    }

    func testSpanningWindowChoosesLargestIntersectionAndSizesOnlyVisibleContent() throws {
        let displays = [
            CGRect(x: 0, y: 0, width: 1920, height: 1080),
            CGRect(x: 1920, y: 0, width: 1920, height: 1080),
        ]
        let window = CGRect(x: 1800, y: 100, width: 800, height: 600)

        let region = try XCTUnwrap(WindowCaptureRegion(windowFrame: window, displayFrames: displays))

        XCTAssertEqual(region.displayIndex, 1)
        XCTAssertEqual(region.sourceRect, CGRect(x: 0, y: 100, width: 680, height: 600))
        XCTAssertEqual(region.pixelSize(pointPixelScale: 1), CGSize(width: 680, height: 600))
    }

    func testOffscreenWindowIsClippedOnEveryEdge() throws {
        let display = CGRect(x: 100, y: 200, width: 1200, height: 800)
        let window = CGRect(x: 50, y: 150, width: 1500, height: 1000)

        let region = try XCTUnwrap(WindowCaptureRegion(windowFrame: window, displayFrames: [display]))

        XCTAssertEqual(region.sourceRect, CGRect(x: 0, y: 0, width: 1200, height: 800))
    }

    func testRightAndBottomEdgesDoNotCaptureBeyondDisplay() throws {
        let display = CGRect(x: 0, y: 0, width: 1200, height: 800)
        let window = CGRect(x: 1100, y: 700, width: 500, height: 400)

        let region = try XCTUnwrap(WindowCaptureRegion(windowFrame: window, displayFrames: [display]))

        XCTAssertEqual(region.sourceRect, CGRect(x: 1100, y: 700, width: 100, height: 100))
    }

    func testEqualIntersectionsKeepFirstDisplay() throws {
        let displays = [
            CGRect(x: -1000, y: 0, width: 1000, height: 800),
            CGRect(x: 0, y: 0, width: 1000, height: 800),
        ]

        let region = try XCTUnwrap(WindowCaptureRegion(
            windowFrame: CGRect(x: -200, y: 100, width: 400, height: 300), displayFrames: displays))

        XCTAssertEqual(region.displayIndex, 0)
        XCTAssertEqual(region.sourceRect, CGRect(x: 800, y: 100, width: 200, height: 300))
    }

    func testUnavailableDisplayDoesNotFallBackToIndependentWindowCapture() {
        let window = CGRect(x: 1200, y: 100, width: 400, height: 300)
        let display = CGRect(x: 0, y: 0, width: 1000, height: 800)

        let missing = WindowCaptureRegion(windowFrame: window, displayFrames: [])
        let offscreen = WindowCaptureRegion(windowFrame: window, displayFrames: [display])

        XCTAssertNil(missing)
        XCTAssertNil(offscreen)
    }

    func testWindowTouchingDisplayEdgeHasNoCapturableArea() {
        let region = WindowCaptureRegion(
            windowFrame: CGRect(x: 1000, y: 0, width: 400, height: 300),
            displayFrames: [CGRect(x: 0, y: 0, width: 1000, height: 800)])

        XCTAssertNil(region)
    }

    func testLargeCaptureRespectsOCRDimensionLimitAndAspectRatio() throws {
        let frame = CGRect(x: 0, y: 0, width: 2000, height: 1000)
        let region = try XCTUnwrap(WindowCaptureRegion(windowFrame: frame, displayFrames: [frame]))

        let pixels = region.pixelSize(pointPixelScale: 2)

        XCTAssertEqual(pixels, CGSize(width: 2800, height: 1400))
    }

    func testStandardDensityCaptureIsNotUpscaled() throws {
        let frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        let region = try XCTUnwrap(WindowCaptureRegion(windowFrame: frame, displayFrames: [frame]))

        let pixels = region.pixelSize(pointPixelScale: 1)

        XCTAssertEqual(pixels, CGSize(width: 800, height: 600))
    }
}
