import AppKit
import XCTest

@testable import VoiceInk

@MainActor final class AnnotationInkTests: XCTestCase {
    private let display = CGSize(width: 1_000, height: 800)

    // MARK: - Shapes

    func testStrokesAreClassifiedAsHexDoes() {
        XCTAssertEqual(AnnotationMarks.shape(of: stroke([(0.5, 0.5), (0.505, 0.505)]), displaySize: display), .tap)
        XCTAssertEqual(AnnotationMarks.shape(of: circle(center: (0.5, 0.5), radius: 0.1), displaySize: display), .circle)
        XCTAssertEqual(AnnotationMarks.shape(of: stroke([(0.2, 0.6), (0.5, 0.605), (0.8, 0.6)]), displaySize: display), .underline)
        XCTAssertEqual(AnnotationMarks.shape(of: stroke([(0.2, 0.2), (0.4, 0.45), (0.6, 0.7)]), displaySize: display), .line)
        XCTAssertEqual(
            AnnotationMarks.shape(of: stroke([(0.2, 0.2), (0.4, 0.4), (0.2, 0.45), (0.4, 0.6), (0.2, 0.7)]), displaySize: display),
            .mark
        )
    }

    func testStrokesCloseInTimeFormOneMarkOfAtMostSixStrokes() {
        var strokes = (0..<7).map { index in stroke([(0.1, 0.1), (0.3, 0.1)], start: Double(index) * 0.5) }
        strokes.append(stroke([(0.6, 0.6), (0.7, 0.7)], start: 10))

        let marks = AnnotationMarks.marks(strokes, displaySize: display)

        XCTAssertEqual(marks.map(\.strokes), [[0, 1, 2, 3, 4, 5], [6], [7]])
        XCTAssertEqual(marks.map(\.id), ["m1", "m2", "m3"])
        XCTAssertEqual(marks[0].shape, .underline)
        XCTAssertEqual(marks[0].description, "underlined x 0.10–0.30 at y 0.10 (6 strokes)")
        XCTAssertEqual(marks[2].shape, .line)
    }

    func testAMarkMixingShapesIsAPlainMarkWithItsRegion() {
        let marks = AnnotationMarks.marks(
            [circle(center: (0.3, 0.3), radius: 0.05), stroke([(0.5, 0.5), (0.6, 0.6)], start: 1)], displaySize: display
        )

        XCTAssertEqual(marks.count, 1)
        XCTAssertEqual(marks[0].shape, .mark)
        XCTAssertTrue(marks[0].description.hasPrefix("marked region x 0.26–0.60"))
        XCTAssertTrue(marks[0].description.hasSuffix("(2 strokes)"))
    }

    func testALineKeepsTheDirectionItWasDrawnAndSeparateLinesAreARegion() {
        let single = AnnotationMarks.marks([stroke([(0.2, 0.8), (0.5, 0.5), (0.8, 0.2)])], displaySize: display)
        let pair = AnnotationMarks.marks(
            [stroke([(0.1, 0.1), (0.2, 0.3)]), stroke([(0.7, 0.7), (0.9, 0.95)], start: 0.5)], displaySize: display
        )

        XCTAssertEqual(single.first?.description, "drew a line from x 0.20, y 0.80 to x 0.80, y 0.20")
        XCTAssertEqual(pair.first?.shape, .mark)
        XCTAssertTrue(pair.first?.description.hasPrefix("marked region x 0.10–0.90") == true)
    }

    func testTheCapsuleSitsAboveTheInkOverlay() {
        XCTAssertGreaterThan(AnnotationCapsuleController.capsuleLevel.rawValue, AnnotationInputCapture.overlayLevel.rawValue)
        XCTAssertGreaterThan(AnnotationInputCapture.overlayLevel.rawValue, NSWindow.Level.floating.rawValue)
    }

    func testStopKeepsTheStrokeBeingDrawn() throws {
        let monitors = FakeEventMonitoring()
        let capture = AnnotationInputCapture(monitoring: monitors, displayFrame: { _ in CGRect(x: 0, y: 0, width: 1_000, height: 800) })
        capture.start(displayID: 1, startNanoseconds: 0)
        capture.setPenEnabled(true)
        let ink = try XCTUnwrap(capture.ink)

        ink.mouseDown(with: try mouse(.leftMouseDown, at: CGPoint(x: 100, y: 400)))
        ink.mouseDragged(with: try mouse(.leftMouseDragged, at: CGPoint(x: 400, y: 400)))
        let result = capture.stop()

        XCTAssertEqual(result.strokes.count, 1)
        XCTAssertEqual(result.strokes.first?.points.count, 2)
        XCTAssertEqual(monitors.added, 2)
        XCTAssertEqual(monitors.removed, 2)
    }

    func testClicksUseTheirOwnPositionAndTimeAndScrollsAreThrottled() throws {
        let monitors = FakeEventMonitoring()
        let frame = CGRect(x: -1_000, y: 0, width: 1_000, height: 800)
        let capture = AnnotationInputCapture(monitoring: monitors, displayFrame: { _ in frame })
        capture.start(displayID: 1, startNanoseconds: 100_000_000_000)

        monitors.deliver(try mouse(.leftMouseDown, at: CGPoint(x: -500, y: 600), timestamp: 101.5))
        monitors.deliver(try mouse(.rightMouseDown, at: CGPoint(x: -250, y: 200), timestamp: 102))
        monitors.deliver(try mouse(.leftMouseDown, at: CGPoint(x: 300, y: 600), timestamp: 102.1))
        for time in [103.0, 103.2, 103.6] { monitors.deliver(try scroll(at: CGPoint(x: -100, y: 100), timestamp: time)) }
        let result = capture.stop()

        XCTAssertEqual(result.events.map(\.kind), [.click, .rightClick, .scroll, .scroll])
        XCTAssertEqual(result.events[0].t, 1.5, accuracy: 0.001)
        XCTAssertEqual(result.events[0].x, 0.5, accuracy: 0.001)
        XCTAssertEqual(result.events[0].y, 0.25, accuracy: 0.001)
        XCTAssertEqual(result.events[1].y, 0.75, accuracy: 0.001)
        XCTAssertEqual(result.events[3].t, 3.6, accuracy: 0.001)
    }

    func testShiftAloneDrawsAndAMissedReleaseHealsOnTheNextEvent() throws {
        let monitors = FakeEventMonitoring()
        let capture = AnnotationInputCapture(monitoring: monitors, displayFrame: { _ in CGRect(x: 0, y: 0, width: 1_000, height: 800) })
        capture.start(displayID: 1, startNanoseconds: 0)

        monitors.deliver(try flags([.maskShift]))
        XCTAssertTrue(capture.isTakingPointer)
        monitors.deliver(try flags([.maskShift, .maskCommand]))
        XCTAssertFalse(capture.isTakingPointer, "Shift with another modifier is a shortcut, not drawing")
        monitors.deliver(try flags([.maskShift]))
        monitors.deliver(try mouse(.leftMouseDown, at: CGPoint(x: 10, y: 10), timestamp: 1))
        XCTAssertFalse(capture.isTakingPointer)
        capture.setPenEnabled(true)
        XCTAssertTrue(capture.isTakingPointer)
        capture.setPenEnabled(false)
        XCTAssertFalse(capture.isTakingPointer)
        _ = capture.stop()
    }

    func testAMissedShiftReleaseHealsOnTheOverlaysOwnClickWithoutDrawing() throws {
        let monitors = FakeEventMonitoring()
        let capture = AnnotationInputCapture(monitoring: monitors, displayFrame: { _ in CGRect(x: 0, y: 0, width: 1_000, height: 800) })
        capture.start(displayID: 1, startNanoseconds: 0)
        let ink = try XCTUnwrap(capture.ink)
        // The overlay is catching the pointer when the release is lost; its own clicks reach only the overlay.
        monitors.deliverLocal(try flags([.maskShift]))
        XCTAssertTrue(capture.isTakingPointer)

        ink.mouseDown(with: try mouse(.leftMouseDown, at: CGPoint(x: 100, y: 100)))
        ink.mouseUp(with: try mouse(.leftMouseUp, at: CGPoint(x: 200, y: 100)))

        XCTAssertFalse(capture.isTakingPointer)
        XCTAssertTrue(capture.stop().strokes.isEmpty)
    }

    func testPointsAreNormalizedFromTheTopLeftOfTheDisplay() {
        let frame = CGRect(x: -1_512, y: 200, width: 1_512, height: 982)

        XCTAssertEqual(AnnotationMarks.normalized(CGPoint(x: -1_512, y: 1_182), in: frame), CGPoint(x: 0, y: 0))
        XCTAssertEqual(AnnotationMarks.normalized(CGPoint(x: -756, y: 691), in: frame), CGPoint(x: 0.5, y: 0.5))
        XCTAssertNil(AnnotationMarks.normalized(CGPoint(x: 10, y: 500), in: frame))
    }

    func testInkHoldsThenFades() {
        XCTAssertEqual(AnnotationMarks.opacity(endedAt: nil, now: 9), 1)
        XCTAssertEqual(AnnotationMarks.opacity(endedAt: 1, now: 1.6), 1)
        XCTAssertEqual(AnnotationMarks.opacity(endedAt: 1, now: 1.975), 0.5, accuracy: 0.001)
        XCTAssertEqual(AnnotationMarks.opacity(endedAt: 1, now: 3), 0)
    }

    func testTheInkViewKeepsEachFinishedStrokeInAnnotationTime() throws {
        let view = InkView(frame: CGRect(x: 0, y: 0, width: 1_000, height: 800))
        var now = 2.0
        view.time = { now }
        view.normalize = { AnnotationMarks.normalized($0, in: CGRect(x: 0, y: 0, width: 1_000, height: 800)) }

        view.mouseDown(with: try mouse(.leftMouseDown, at: CGPoint(x: 100, y: 700)))
        now = 2.1
        view.mouseDragged(with: try mouse(.leftMouseDragged, at: CGPoint(x: 300, y: 700)))
        now = 2.2
        view.mouseUp(with: try mouse(.leftMouseUp, at: CGPoint(x: 500, y: 700)))

        let stroke = try XCTUnwrap(view.finishedStrokes.first)
        XCTAssertEqual(view.finishedStrokes.count, 1)
        XCTAssertEqual(stroke.points.map(\.x), [0.1, 0.3, 0.5])
        XCTAssertEqual(stroke.points.first?.y ?? 0, 0.125, accuracy: 0.0001)
        XCTAssertEqual(stroke.start, 2.0)
        XCTAssertEqual(stroke.end, 2.2)
    }

    // MARK: - Recording

    func testOlderManifestsWithoutInkStillLoad() throws {
        let manifest = AnnotationManifest()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(manifest)) as? [String: Any])
        for key in ["strokes", "marks", "events", "narrationFailure"] { object.removeValue(forKey: key) }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let decoded = try decoder.decode(AnnotationManifest.self, from: JSONSerialization.data(withJSONObject: object))

        XCTAssertEqual(decoded.id, manifest.id)
        XCTAssertTrue(decoded.strokes.isEmpty && decoded.marks.isEmpty && decoded.events.isEmpty)
    }

    func testTheSummaryListsMarksAndClicksInTimeOrder() {
        var manifest = AnnotationManifest()
        manifest.duration = 12
        manifest.marks = AnnotationMarks.marks([circle(center: (0.5, 0.5), radius: 0.1, start: 5)], displaySize: display)
        manifest.events = [
            AnnotationEvent(kind: .click, t: 2, x: 0.42, y: 0.18), AnnotationEvent(kind: .scroll, t: 8, x: 0.5, y: 0.5),
        ]

        let summary = AnnotationSummary.render(manifest, folder: URL(fileURLWithPath: "/tmp/A"))

        let lines = summary.components(separatedBy: "\n").filter { $0.hasPrefix("- 00:") && !$0.contains("“") }
        XCTAssertEqual(lines.count, 3)
        XCTAssertTrue(lines[0].hasPrefix("- 00:02 clicked at x 0.42, y 0.18"))
        XCTAssertTrue(lines[1].hasPrefix("- 00:05 circled region"))
        XCTAssertTrue(lines[2].hasPrefix("- 00:08 scrolled"))
    }

    // MARK: - Fixtures

    private func stroke(_ points: [(Double, Double)], start: TimeInterval = 0) -> AnnotationStroke {
        AnnotationStroke(points: points.enumerated().map {
            AnnotationStroke.Point(x: $0.element.0, y: $0.element.1, t: start + Double($0.offset) * 0.02)
        })
    }

    private func circle(center: (Double, Double), radius: Double, start: TimeInterval = 0) -> AnnotationStroke {
        let points = (0...36).map { index -> (Double, Double) in
            let angle = Double(index) / 36 * 2 * .pi
            return (center.0 + radius * cos(angle) * 0.8, center.1 + radius * sin(angle))
        }
        return stroke(points, start: start)
    }

    private func mouse(_ type: NSEvent.EventType, at point: CGPoint, timestamp: TimeInterval = 0) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: [], timestamp: timestamp, windowNumber: 0, context: nil, eventNumber: 0,
            clickCount: 1, pressure: 1
        ))
    }

    /// A scroll at `point` in AppKit screen coordinates; CoreGraphics measures y down from the main display's top.
    private func scroll(at point: CGPoint, timestamp: TimeInterval) throws -> NSEvent {
        let event = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: 3, wheel2: 0, wheel3: 0))
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        event.location = CGPoint(x: point.x, y: mainHeight - point.y)
        event.timestamp = UInt64(timestamp * 1_000_000_000)
        return try XCTUnwrap(NSEvent(cgEvent: event))
    }

    private func flags(_ flags: CGEventFlags) throws -> NSEvent {
        let event = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 56, keyDown: true))
        event.type = .flagsChanged
        event.flags = flags
        return try XCTUnwrap(NSEvent(cgEvent: event))
    }
}

@MainActor
private final class FakeEventMonitoring: AnnotationEventMonitoring {
    private var global: ((NSEvent) -> Void)?
    private var globalMask: NSEvent.EventTypeMask = []
    private var local: ((NSEvent) -> NSEvent?)?
    private var localMask: NSEvent.EventTypeMask = []
    private(set) var added = 0
    private(set) var removed = 0

    func addGlobal(_ mask: NSEvent.EventTypeMask, _ handler: @escaping (NSEvent) -> Void) -> Any? {
        added += 1
        global = handler
        globalMask = mask
        return "global"
    }

    func addLocal(_ mask: NSEvent.EventTypeMask, _ handler: @escaping (NSEvent) -> NSEvent?) -> Any? {
        added += 1
        local = handler
        localMask = mask
        return "local"
    }

    func remove(_ monitor: Any) { removed += 1 }

    /// Another app's event, as AppKit delivers it, only when the registered mask includes its type.
    func deliver(_ event: NSEvent) {
        if globalMask.contains(NSEvent.EventTypeMask(rawValue: 1 << event.type.rawValue)) { global?(event) }
    }

    /// One of VoiceInk's own events, which only local monitors see.
    func deliverLocal(_ event: NSEvent) {
        if localMask.contains(NSEvent.EventTypeMask(rawValue: 1 << event.type.rawValue)) { _ = local?(event) }
    }
}
