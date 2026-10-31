import AVFoundation
import AppKit
import XCTest

@testable import VoiceInk

/// Opt-in: `TEST_RUNNER_VOICEINK_SCREEN_RECORDING=1` records the main display for a second with ScreenCaptureKit.
/// Needs Screen Recording for the test host.
final class AnnotationScreenRecordingIntegrationTests: XCTestCase {
    func testScreenCaptureKitWritesAPlayableMovie() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["VOICEINK_SCREEN_RECORDING"] == "1", "Set TEST_RUNNER_VOICEINK_SCREEN_RECORDING=1")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AnnotationScreen-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("recording.mp4")
        let pointerDisplay = await MainActor.run { NSScreen.displayUnderPointer }
        let displayID = try XCTUnwrap(pointerDisplay)
        let recording = ScreenCaptureKitRecording()

        let display = try await recording.start(displayID: displayID, writingTo: url)
        try await Task.sleep(for: .seconds(1.5))
        let result = try await recording.stop()

        XCTAssertNotNil(result.firstFrameNanoseconds)
        XCTAssertLessThanOrEqual(max(display.width, display.height), ScreenCaptureKitRecording.maximumLongEdge)
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        XCTAssertGreaterThan(duration, 0.5)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let size = try await track.load(.naturalSize)
        XCTAssertEqual(Int(size.width), display.width)
        XCTAssertEqual(Int(size.height), display.height)
    }
}
