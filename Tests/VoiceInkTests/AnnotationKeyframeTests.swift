import AVFoundation
import CoreVideo
import XCTest

@testable import VoiceInk

@MainActor final class AnnotationKeyframeTests: XCTestCase {
    // MARK: - Selection

    func testTheBudgetGrowsWithLengthAsHexDoes() {
        XCTAssertEqual(AnnotationKeyframes.budget(for: 30), 6)
        XCTAssertEqual(AnnotationKeyframes.budget(for: 39.9), 6)
        XCTAssertEqual(AnnotationKeyframes.budget(for: 40), 7)
        XCTAssertEqual(AnnotationKeyframes.budget(for: 140), 12)
        XCTAssertEqual(AnnotationKeyframes.budget(for: 1_200), 12)
    }

    func testMarksClicksCuesAndSceneChangesCompeteByScoreAndStayApart() {
        var manifest = AnnotationManifest()
        manifest.duration = 30
        manifest.marks = [AnnotationMark(id: "m1", start: 4, end: 5, strokes: [], box: [0, 0, 1, 1], shape: .circle, description: "circled")]
        manifest.events = [AnnotationEvent(kind: .click, t: 5.1, x: 0.5, y: 0.5), AnnotationEvent(kind: .click, t: 9, x: 0.2, y: 0.2)]
        manifest.transcript = [TimedTranscriptSegment(text: "look here", start: 12, end: 12.6, words: [
            TimedTranscriptWord(text: "Look", start: 12, end: 12.2), TimedTranscriptWord(text: "here.", start: 12.3, end: 12.6),
        ])]
        let scenes = [AnnotationSceneSampler.Change(t: 20, difference: 0.5)]

        let selected = AnnotationKeyframes.select(AnnotationKeyframes.candidates(manifest, sceneChanges: scenes), duration: 30)

        XCTAssertEqual(selected.map(\.reason), [.initial, .mark, .click, .speech, .sceneChange])
        XCTAssertEqual(selected.map(\.t), [0.5, 5.05, 9.25, 12, 20])
        XCTAssertEqual(selected[1].event, "circled")
    }

    func testLongQuietStretchesGetCoverageFrames() {
        let selected = AnnotationKeyframes.select([.init(t: 0.5, score: 30, reason: .initial)], duration: 100)

        // One frame in each of three 33 s stretches.
        XCTAssertEqual(selected.map(\.reason), [.initial, .coverage, .coverage])
        XCTAssertEqual(selected.map { Int($0.t / (100.0 / 3)) }, [0, 1, 2])
    }

    func testAnEarlyBurstLeavesRoomForTheRestOfALongAnnotation() {
        let clicks = (1...10).map { AnnotationKeyframes.Candidate(t: Double($0) + 0.25, score: 60, reason: .click) }

        let selected = AnnotationKeyframes.select(clicks, duration: 100)

        XCTAssertEqual(selected.count, AnnotationKeyframes.budget(for: 100))
        XCTAssertTrue(selected.contains { $0.t >= 35 && $0.t < 70 })
        XCTAssertTrue(selected.contains { $0.t >= 70 })
    }

    func testAQuietMaximumLengthAnnotationIsCoveredEvenly() {
        let selected = AnnotationKeyframes.select([.init(t: 0.5, score: 30, reason: .initial)], duration: 1_200)

        XCTAssertEqual(selected.count, 12)
        XCTAssertGreaterThan(selected.last?.t ?? 0, 1_100)
        XCTAssertTrue(zip(selected, selected.dropFirst()).allSatisfy { $1.t - $0.t <= 150 })
    }

    func testEachWordIsSaidAtOneKeyframeOnly() {
        let transcript = [TimedTranscriptSegment(text: "", start: 0, end: 6, words: [
            TimedTranscriptWord(text: "first", start: 1.6, end: 1.9), TimedTranscriptWord(text: "second", start: 2.6, end: 2.9),
            TimedTranscriptWord(text: "later", start: 5, end: 5.2),
        ])]

        let said = AnnotationKeyframes.said(at: [0.5, 2, 3], in: transcript)

        // Frames 0.75 s and 0.5 s apart split the narration half-way: 1.25 s and 2.5 s.
        XCTAssertEqual(said, [nil, "first", "second later"])
        XCTAssertEqual(said.compactMap { $0 }.joined(separator: " ").split(separator: " ").count, 3)
    }

    func testSegmentsWithoutWordsAreAssignedOnceToo() {
        let transcript = [
            TimedTranscriptSegment(text: "open settings", start: 0.2, end: 1.5),
            TimedTranscriptSegment(text: "this toggle", start: 4, end: 5),
        ]

        XCTAssertEqual(AnnotationKeyframes.said(at: [0.5, 4.5, 4.9], in: transcript), ["open settings", "this toggle", nil])
    }

    // MARK: - Scene changes

    func testSceneChangesNeedMoreThanACursorWorthOfDifference() {
        let sampler = AnnotationSceneSampler(startNanoseconds: 0)
        let dark = [Float](repeating: 0.1, count: 64 * 36)
        var cursor = dark
        for y in 10..<14 { for x in 10..<14 { cursor[y * 64 + x] = 1 } }
        let bright = [Float](repeating: 0.9, count: 64 * 36)

        sampler.ingest(dark, at: 0)
        sampler.ingest(cursor, at: 0.22)
        sampler.ingest(bright, at: 0.44)

        XCTAssertEqual(sampler.changes.map(\.t), [0.44])
        // A change across every block: 0.8 × 1.4, capped at 1 as in Hex.
        XCTAssertEqual(sampler.changes.first?.difference ?? 0, 1, accuracy: 0.01)
    }

    func testThumbnailsAreTheLumaOfBGRAFrames() throws {
        let buffer = try pixelBuffer(width: 128, height: 72) { x, _ in x < 64 ? (0, 0, 0) : (255, 255, 255) }

        let thumbnail = try XCTUnwrap(AnnotationSceneSampler.thumbnail(of: buffer))

        XCTAssertEqual(thumbnail.count, 64 * 36)
        XCTAssertEqual(thumbnail[0], 0, accuracy: 0.01)
        XCTAssertEqual(thumbnail[63], 1, accuracy: 0.01)
    }

    // MARK: - Rendering

    func testKeyframesShowRecentInkClicksAndTheirNumber() throws {
        var manifest = AnnotationManifest()
        manifest.strokes = [AnnotationStroke(points: [.init(x: 0.2, y: 0.5, t: 1), .init(x: 0.8, y: 0.5, t: 1.3)])]
        manifest.marks = AnnotationMarks.marks(manifest.strokes, displaySize: CGSize(width: 800, height: 600))
        manifest.events = [AnnotationEvent(kind: .click, t: 1.2, x: 0.5, y: 0.8)]
        let keyframe = AnnotationKeyframe(index: 3, t: 1.4, reason: .mark)

        let image = try XCTUnwrap(AnnotationRenderer.annotate(try solid(800, 600, gray: 1), keyframe: keyframe, manifest: manifest))

        let ink = try color(of: image, x: 400, y: 300)
        XCTAssertGreaterThan(ink.red, 0.9)
        XCTAssertLessThan(ink.green, 0.4)
        // The inner ring's radius is 14 points scaled to this 800-pixel frame.
        let ripple = try color(of: image, x: 400 + 7, y: 480)
        XCTAssertGreaterThan(ripple.blue, 0.8)
        XCTAssertLessThan(ripple.red, 0.3)
        let badge = try color(of: image, x: 34, y: 34)
        XCTAssertGreaterThan(badge.red, 0.8)
        XCTAssertTrue(AnnotationRenderer.strokes(at: 5, in: manifest).isEmpty, "old ink is not drawn on later frames")
    }

    func testTheContactSheetStaysWithinHexsLimits() throws {
        let frames = try (0..<12).map { (image: try solid(1_600, 1_000, gray: 0.5), label: "#\($0 + 1) 00:0\($0 % 10)") }

        let sheet = try XCTUnwrap(AnnotationRenderer.contactSheet(frames))

        XCTAssertLessThanOrEqual(max(sheet.width, sheet.height), 1_600)
        XCTAssertLessThanOrEqual(sheet.width * sheet.height, 1_560_000)
        XCTAssertGreaterThan(sheet.width, 1_000)
    }

    func testFramesAreDecodedFromTheMovieOnTheAnnotationTimeline() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AnnotationKeyframeTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("recording.mp4")
        try await writeMovie(to: url, secondsBlackThenWhite: 1)

        let images = try await MovieFrameSource(url: url, offset: 0.5).images(at: [1.0, 2.2])

        XCTAssertEqual(images.count, 2)
        XCTAssertLessThan(try color(of: XCTUnwrap(images[0]), x: 32, y: 32).red, 0.2)
        XCTAssertGreaterThan(try color(of: XCTUnwrap(images[1]), x: 32, y: 32).red, 0.8)
    }

    // MARK: - Processing

    func testProcessingRendersFramesAContactSheetAndListsThemForTheAgent() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AnnotationKeyframeTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AnnotationStore(rootURL: root, movesToTrash: false)
        var manifest = AnnotationManifest()
        manifest.duration = 12
        manifest.status = .processing
        manifest.events = [AnnotationEvent(kind: .click, t: 4, x: 0.5, y: 0.5)]
        try store.createDirectory(for: manifest.id)
        try store.save(manifest)
        let recorder = AnnotationRecorder(dependencies: {
            var dependencies = AnnotationRecorder.Dependencies()
            dependencies.store = store
            return dependencies
        }())
        let processor = AnnotationProcessor()
        var copied: [String] = []
        let image = try solid(640, 400, gray: 0.8)
        processor.configure(
            environment: .init(
                chooseModel: { nil }, makeTranscriber: { _ in fatalError("no model") },
                requestContext: { _ in TranscriptionRequestContext(languages: ["en"]) }, copy: { copied.append($0) },
                notify: { _ in }, frameSource: { _, _ in StillFrames(image: image) }
            ),
            recorder: recorder
        )

        processor.process(manifest.id)
        await processor.waitUntilIdle()

        let saved = try store.load(id: manifest.id)
        XCTAssertEqual(saved.keyframes.map(\.reason), [.initial, .click])
        XCTAssertEqual(saved.contactSheet, AnnotationManifest.contactSheetFileName)
        for keyframe in saved.keyframes {
            XCTAssertTrue(FileManager.default.fileExists(atPath: store.directory(for: manifest.id).appendingPathComponent(keyframe.file!).path))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.url(for: manifest.id, file: "contact-sheet.png").path))
        let summary = try XCTUnwrap(copied.first)
        XCTAssertTrue(summary.contains("Open contact-sheet.png and frames/ in that folder before changing anything"))
        XCTAssertTrue(summary.contains("- #2 (00:04) [clicked at x 0.50, y 0.50]"))
    }

    func testABundleRemovedWhileFramesDecodeIsNotRecreatedOrHandedOff() async throws {
        let fixture = try makeProcessing { store, id in
            RemovingFrames(image: try self.solid(320, 200, gray: 0.5), remove: store.directory(for: id))
        }

        fixture.processor.process(fixture.id)
        await fixture.processor.waitUntilIdle()

        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.store.directory(for: fixture.id).path))
        XCTAssertTrue(fixture.copied.values.isEmpty)
    }

    func testFrameAndContactSheetWriteFailuresFailTheAnnotationWithoutAHandoff() async throws {
        for blocked in ["frames", "contact-sheet.png"] {
            let image = try solid(320, 200, gray: 0.5)
            let fixture = try makeProcessing { _, _ in StillFrames(image: image) }
            let path = fixture.store.directory(for: fixture.id).appendingPathComponent(blocked)
            if blocked == "frames" {
                FileManager.default.createFile(atPath: path.path, contents: Data())
            } else {
                try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false)
            }

            fixture.processor.process(fixture.id)
            await fixture.processor.waitUntilIdle()

            XCTAssertEqual(try fixture.store.load(id: fixture.id).status, .failed, blocked)
            XCTAssertTrue(fixture.copied.values.isEmpty, blocked)
        }
    }

    private final class Copies {
        var values: [String] = []
    }

    private struct ProcessingFixture {
        let processor: AnnotationProcessor
        /// The processor holds the recorder weakly, as the app's shared instances outlive it.
        let recorder: AnnotationRecorder
        let store: AnnotationStore
        let id: UUID
        let copied: Copies
    }

    private func makeProcessing(
        frames: @escaping (AnnotationStore, UUID) throws -> any AnnotationFrameSource
    ) throws -> ProcessingFixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AnnotationKeyframeTests-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let store = AnnotationStore(rootURL: root, movesToTrash: false)
        var manifest = AnnotationManifest()
        manifest.duration = 12
        manifest.status = .processing
        try store.createDirectory(for: manifest.id)
        try store.save(manifest)
        var dependencies = AnnotationRecorder.Dependencies()
        dependencies.store = store
        let recorder = AnnotationRecorder(dependencies: dependencies)
        let processor = AnnotationProcessor()
        let copied = Copies()
        let source = try frames(store, manifest.id)
        processor.configure(
            environment: .init(
                chooseModel: { nil }, makeTranscriber: { _ in fatalError("no model") },
                requestContext: { _ in TranscriptionRequestContext(languages: ["en"]) }, copy: { copied.values.append($0) },
                notify: { _ in }, frameSource: { _, _ in source }
            ),
            recorder: recorder
        )
        return ProcessingFixture(processor: processor, recorder: recorder, store: store, id: manifest.id, copied: copied)
    }

    // MARK: - Fixtures

    private func solid(_ width: Int, _ height: Int, gray: CGFloat) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(srgbRed: gray, green: gray, blue: gray, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try XCTUnwrap(context.makeImage())
    }

    /// The color at `x`, `y` measured from the top-left, as the normalized coordinates are.
    private func color(of image: CGImage, x: Int, y: Int) throws -> (red: CGFloat, green: CGFloat, blue: CGFloat) {
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = try XCTUnwrap(CGContext(
            data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(image, in: CGRect(x: -x, y: y - image.height + 1, width: image.width, height: image.height))
        return (CGFloat(pixel[0]) / 255, CGFloat(pixel[1]) / 255, CGFloat(pixel[2]) / 255)
    }

    private func pixelBuffer(width: Int, height: Int, color: (Int, Int) -> (UInt8, UInt8, UInt8)) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &buffer)
        let pixels = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(pixels, [])
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(pixels)).assumingMemoryBound(to: UInt8.self)
        let rowBytes = CVPixelBufferGetBytesPerRow(pixels)
        for y in 0..<height {
            for x in 0..<width {
                let (red, green, blue) = color(x, y)
                let offset = y * rowBytes + x * 4
                base[offset] = blue
                base[offset + 1] = green
                base[offset + 2] = red
                base[offset + 3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(pixels, [])
        return pixels
    }

    /// A 64×64 H.264 movie: black for `secondsBlackThenWhite`, then white for as long.
    private func writeMovie(to url: URL, secondsBlackThenWhite seconds: Int) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 64,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<(seconds * 2 * 10) {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            let value: UInt8 = frame < seconds * 10 ? 0 : 255
            let buffer = try pixelBuffer(width: 64, height: 64) { _, _ in (value, value, value) }
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 10))
        }
        input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed)
    }
}

private struct StillFrames: AnnotationFrameSource {
    let image: CGImage
    func images(at times: [TimeInterval]) async throws -> [CGImage?] { times.map { _ in image } }
}

/// Removes the bundle while "decoding", as Finder could.
private struct RemovingFrames: AnnotationFrameSource {
    let image: CGImage
    let remove: URL
    func images(at times: [TimeInterval]) async throws -> [CGImage?] {
        try? FileManager.default.removeItem(at: remove)
        return times.map { _ in image }
    }
}
