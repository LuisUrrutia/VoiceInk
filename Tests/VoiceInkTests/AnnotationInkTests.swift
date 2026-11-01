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

    private func mouse(_ type: NSEvent.EventType, at point: CGPoint) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0,
            clickCount: 1, pressure: 1
        ))
    }
}
