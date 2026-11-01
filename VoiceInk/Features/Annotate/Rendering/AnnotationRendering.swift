import AVFoundation
import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Frames of the recorded movie at annotation times.
protocol AnnotationFrameSource {
    func images(at times: [TimeInterval]) async throws -> [CGImage?]
}

/// Decodes frames from `recording.mp4` near each requested time, at most 1600 pixels on the long edge, the
/// size Hex sends a reading model (about 1–1.5k tokens per image).
struct MovieFrameSource: AnnotationFrameSource {
    static let maximumEdge: CGFloat = 1_600

    let url: URL
    /// Where the movie's first frame lies on the annotation timeline.
    let offset: TimeInterval

    func images(at times: [TimeInterval]) async throws -> [CGImage?] {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: Self.maximumEdge, height: Self.maximumEdge)
        let tolerance = CMTime(seconds: 0.05, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
        var images: [CGImage?] = []
        for time in times {
            let movieTime = min(max(0, time - offset), max(0, duration - 0.05))
            images.append(try? await generator.image(at: CMTime(seconds: movieTime, preferredTimescale: 600)).image)
        }
        return images
    }
}

/// Draws what the agent should see on each keyframe and tiles them into a contact sheet, after Hex's `render.rs`
/// (MIT): red ink of marks just drawn, a blue ripple at clicks, and a numbered badge.
enum AnnotationRenderer {
    static let inkColor = CGColor(srgbRed: 1, green: 59 / 255, blue: 48 / 255, alpha: 1)
    static let clickColor = CGColor(srgbRed: 0, green: 136 / 255, blue: 1, alpha: 1)
    static let sheetBackground = CGColor(srgbRed: 28 / 255, green: 29 / 255, blue: 34 / 255, alpha: 1)
    static let sheetMaximumEdge: CGFloat = 1_600
    static let sheetMaximumPixels: CGFloat = 1_560_000
    static let sheetPadding: CGFloat = 6

    /// Ink of marks that ended within the mark gap before this frame.
    static func strokes(at t: TimeInterval, in manifest: AnnotationManifest) -> [AnnotationStroke] {
        manifest.marks.filter { $0.end <= t + 0.1 && t - $0.end <= AnnotationMarks.gap + 0.1 }
            .flatMap { $0.strokes }
            .compactMap { manifest.strokes.indices.contains($0) ? manifest.strokes[$0] : nil }
    }

    static func clicks(at t: TimeInterval, in manifest: AnnotationManifest) -> [AnnotationEvent] {
        manifest.events.filter { $0.kind != .scroll && abs($0.t + AnnotationKeyframes.clickDelay - t) <= 0.4 }
    }

    static func annotate(_ image: CGImage, keyframe: AnnotationKeyframe, manifest: AnnotationManifest) -> CGImage? {
        let width = image.width, height = image.height
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        let size = CGSize(width: width, height: height)
        context.draw(image, in: CGRect(origin: .zero, size: size))
        // Normalized coordinates start at the top-left; Core Graphics starts at the bottom-left.
        func point(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: x * Double(width), y: (1 - y) * Double(height)) }
        let scale = CGFloat(max(width, height)) / 1_600

        context.setStrokeColor(inkColor)
        context.setLineWidth(max(3, 5 * scale))
        context.setLineCap(.round)
        context.setLineJoin(.round)
        for stroke in strokes(at: keyframe.t, in: manifest) where stroke.points.count > 1 {
            context.beginPath()
            context.move(to: point(stroke.points[0].x, stroke.points[0].y))
            stroke.points.dropFirst().forEach { context.addLine(to: point($0.x, $0.y)) }
            context.strokePath()
        }
        context.setStrokeColor(clickColor)
        context.setLineWidth(max(2, 4 * scale))
        for click in clicks(at: keyframe.t, in: manifest) {
            let center = point(click.x, click.y)
            for radius in [14 * scale, 26 * scale] {
                context.strokeEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: 2 * radius, height: 2 * radius))
            }
        }
        drawBadge("\(keyframe.index)", in: context, size: size, scale: scale)
        return context.makeImage()
    }

    /// The keyframes in a grid at most 1600 pixels on the long edge and 1.56 megapixels, with time labels.
    static func contactSheet(_ images: [(image: CGImage, label: String)]) -> CGImage? {
        guard let first = images.first?.image else { return nil }
        let count = images.count
        let columns = Int(ceil(sqrt(Double(count))))
        let rows = Int(ceil(Double(count) / Double(columns)))
        let aspect = CGFloat(first.height) / CGFloat(first.width)
        var tileWidth = (sheetMaximumEdge - 2 * sheetPadding - CGFloat(columns - 1) * sheetPadding) / CGFloat(columns)
        func sheetSize(_ tile: CGFloat) -> CGSize {
            CGSize(
                width: 2 * sheetPadding + CGFloat(columns) * tile + CGFloat(columns - 1) * sheetPadding,
                height: 2 * sheetPadding + CGFloat(rows) * tile * aspect + CGFloat(rows - 1) * sheetPadding
            )
        }
        while tileWidth > 16 {
            let size = sheetSize(tileWidth)
            if max(size.width, size.height) <= sheetMaximumEdge, size.width * size.height <= sheetMaximumPixels { break }
            tileWidth *= 0.95
        }
        let tileWidthPixels = floor(tileWidth), tileHeight = floor(tileWidth * aspect)
        let size = sheetSize(tileWidthPixels)
        guard let context = CGContext(
            data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.setFillColor(sheetBackground)
        context.fill(CGRect(origin: .zero, size: size))
        context.interpolationQuality = .high
        for (offset, item) in images.enumerated() {
            let column = offset % columns, row = offset / columns
            let origin = CGPoint(
                x: sheetPadding + CGFloat(column) * (tileWidthPixels + sheetPadding),
                y: size.height - sheetPadding - CGFloat(row + 1) * tileHeight - CGFloat(row) * sheetPadding
            )
            context.draw(item.image, in: CGRect(origin: origin, size: CGSize(width: tileWidthPixels, height: tileHeight)))
            drawLabel(item.label, in: context, at: CGPoint(x: origin.x + 6, y: origin.y + 6))
        }
        return context.makeImage()
    }

    static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    }

    private static func drawBadge(_ text: String, in context: CGContext, size: CGSize, scale: CGFloat) {
        let diameter = max(28, 44 * scale)
        let rect = CGRect(x: 12 * scale, y: size.height - 12 * scale - diameter, width: diameter, height: diameter)
        context.setFillColor(inkColor)
        context.fillEllipse(in: rect)
        drawText(text, in: context, rect: rect, fontSize: diameter * 0.55)
    }

    private static func drawLabel(_ text: String, in context: CGContext, at origin: CGPoint) {
        let rect = CGRect(x: origin.x, y: origin.y, width: CGFloat(text.count) * 9 + 12, height: 22)
        context.setFillColor(CGColor(gray: 0, alpha: 0.65))
        context.fill(rect)
        drawText(text, in: context, rect: rect, fontSize: 13)
    }

    private static func drawText(_ text: String, in context: CGContext, rect: CGRect, fontSize: CGFloat) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: fontSize), .foregroundColor: NSColor.white,
        ]
        let string = NSAttributedString(string: text, attributes: attributes)
        let textSize = string.size()
        string.draw(at: CGPoint(x: rect.midX - textSize.width / 2, y: rect.midY - textSize.height / 2))
        NSGraphicsContext.restoreGraphicsState()
    }
}
