import CoreGraphics
import Foundation

/// One drawn stroke. Points are normalized to the recorded display (0...1, origin top-left); `t` is seconds since
/// the annotation started.
struct AnnotationStroke: Codable, Equatable, Sendable {
    struct Point: Codable, Equatable, Sendable {
        var x: Double
        var y: Double
        var t: TimeInterval
    }

    var points: [Point]
    var start: TimeInterval { points.first?.t ?? 0 }
    var end: TimeInterval { points.last?.t ?? 0 }
}

/// A group of strokes drawn together, with the shape it most resembles, as Hex's marks (`sketch.rs`, MIT).
struct AnnotationMark: Codable, Equatable, Sendable {
    enum Shape: String, Codable, Sendable {
        case tap, circle, underline, line, mark
    }

    var id: String
    var start: TimeInterval
    var end: TimeInterval
    var strokes: [Int]
    /// Normalized `[x0, y0, x1, y1]`.
    var box: [Double]
    var shape: Shape
    var description: String
}

/// A click or scroll on the recorded display, normalized like strokes. Keys are never recorded.
struct AnnotationEvent: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case click, rightClick, scroll
    }

    var kind: Kind
    var t: TimeInterval
    var x: Double
    var y: Double
}

enum AnnotationMarks {
    /// Strokes this close in time belong to one mark, up to `maximumStrokes`.
    static let gap: TimeInterval = 1.2
    static let maximumStrokes = 6
    /// Below this diagonal, in points, a stroke is a tap.
    static let tapDiagonal: Double = 14

    /// Marks in drawing order, `m1`, `m2`, … `displaySize` (points) turns normalized coordinates into lengths.
    static func marks(_ strokes: [AnnotationStroke], displaySize: CGSize) -> [AnnotationMark] {
        var groups: [[Int]] = []
        for (index, stroke) in strokes.enumerated() where !stroke.points.isEmpty {
            if let last = groups.last?.last, stroke.start - strokes[last].end <= gap, groups[groups.count - 1].count < maximumStrokes {
                groups[groups.count - 1].append(index)
            } else {
                groups.append([index])
            }
        }
        return groups.enumerated().map { offset, group in
            let points = group.flatMap { strokes[$0].points }
            let box = bounds(points)
            let shapes = group.map { shape(of: strokes[$0], displaySize: displaySize) }
            let shape: AnnotationMark.Shape = shapes.allSatisfy { $0 == shapes[0] } ? shapes[0] : .mark
            var mark = AnnotationMark(
                id: "m\(offset + 1)", start: strokes[group[0]].start, end: group.map { strokes[$0].end }.max() ?? 0,
                strokes: group, box: box, shape: shape, description: ""
            )
            mark.description = describe(mark)
            return mark
        }
    }

    /// Hex's single-stroke rules without its arrow and inner-loop detection: a tap, a stroke that goes round
    /// something, a nearly straight stroke (an underline when it is over 2.5 times wider than tall), else a mark.
    static func shape(of stroke: AnnotationStroke, displaySize: CGSize) -> AnnotationMark.Shape {
        let points = stroke.points.map { CGPoint(x: $0.x * displaySize.width, y: $0.y * displaySize.height) }
        guard let first = points.first, let last = points.last else { return .tap }
        let xs = points.map(\.x), ys = points.map(\.y)
        let width = (xs.max() ?? 0) - (xs.min() ?? 0)
        let height = (ys.max() ?? 0) - (ys.min() ?? 0)
        guard hypot(width, height) >= tapDiagonal else { return .tap }
        let length = zip(points, points.dropFirst()).reduce(0) { $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y) }
        let chord = hypot(last.x - first.x, last.y - first.y)
        var twiceArea = zip(points, points.dropFirst()).reduce(0) { $0 + $1.0.x * $1.1.y - $1.1.x * $1.0.y }
        twiceArea += last.x * first.y - first.x * last.y
        if encloses(gap: chord, length: length, width: width, height: height, area: abs(twiceArea) / 2) { return .circle }
        if chord > 0.88 * length { return width > 2.5 * height ? .underline : .line }
        return .mark
    }

    /// Hex's `encloses`: the path ends near where it began, is long relative to its box, fills it, and is not too flat.
    static func encloses(gap: Double, length: Double, width: Double, height: Double, area: Double) -> Bool {
        let big = max(width, height), small = min(width, height)
        let perimeter = Double.pi / 2 * (3 * (width + height) - ((3 * width + height) * (width + 3 * height)).squareRoot())
        return gap < 0.35 * big && length > 2 * big && small >= 18 && area > 0.32 * width * height
            && (small > 0.42 * big || (small > 0.2 * big && gap < 0.6 * small && length <= 3.5 * perimeter))
    }

    static func describe(_ mark: AnnotationMark) -> String {
        let (x0, y0, x1, y1) = (mark.box[0], mark.box[1], mark.box[2], mark.box[3])
        let region = String(format: "x %.2f–%.2f, y %.2f–%.2f", x0, x1, y0, y1)
        let many = mark.strokes.count > 1 ? " (\(mark.strokes.count) strokes)" : ""
        switch mark.shape {
        case .circle: return "circled region \(region)\(many)"
        case .underline: return String(format: "underlined x %.2f–%.2f at y %.2f", x0, x1, (y0 + y1) / 2) + many
        case .line: return String(format: "drew a line from x %.2f, y %.2f to x %.2f, y %.2f", x0, y0, x1, y1)
        case .tap: return String(format: "tapped x %.2f, y %.2f", (x0 + x1) / 2, (y0 + y1) / 2) + many
        case .mark: return "marked region \(region)\(many)"
        }
    }

    static func bounds(_ points: [AnnotationStroke.Point]) -> [Double] {
        guard let first = points.first else { return [0, 0, 0, 0] }
        return points.reduce([first.x, first.y, first.x, first.y]) { box, point in
            [min(box[0], point.x), min(box[1], point.y), max(box[2], point.x), max(box[3], point.y)]
        }
    }

    /// A point in global AppKit coordinates (origin bottom-left) normalized to `frame` with origin top-left.
    static func normalized(_ point: CGPoint, in frame: CGRect) -> CGPoint? {
        // Inclusive on every edge: the display's top row is its frame's maximum y.
        guard frame.width > 0, frame.height > 0, (frame.minX...frame.maxX).contains(point.x),
            (frame.minY...frame.maxY).contains(point.y)
        else { return nil }
        return CGPoint(x: (point.x - frame.minX) / frame.width, y: (frame.maxY - point.y) / frame.height)
    }

    /// Ink stays fully visible this long after a stroke ends, then fades out over the same time, as in Hex.
    static let holdDuration: TimeInterval = 0.65
    static let fadeDuration: TimeInterval = 0.65

    static func opacity(endedAt end: TimeInterval?, now: TimeInterval) -> Double {
        guard let end else { return 1 }
        let elapsed = now - end
        if elapsed <= holdDuration { return 1 }
        return max(0, 1 - (elapsed - holdDuration) / fadeDuration)
    }
}
