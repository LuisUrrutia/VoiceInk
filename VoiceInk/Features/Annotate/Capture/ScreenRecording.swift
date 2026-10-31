import AVFoundation
import AppKit
import CoreMedia
import Foundation
import ScreenCaptureKit
import os

struct ScreenRecordingResult: Equatable, Sendable {
    var display: AnnotationManifest.Display
    /// Uptime when the movie's first frame was written, if recording started.
    var firstFrameNanoseconds: UInt64?
}

/// Records one display to a movie, without VoiceInk's own windows.
protocol ScreenRecording: AnyObject {
    func start(displayID: CGDirectDisplayID, writingTo url: URL) async throws -> AnnotationManifest.Display
    func stop() async throws -> ScreenRecordingResult
}

enum ScreenRecordingError: LocalizedError, Equatable {
    case displayUnavailable
    case notStarted
    case finishTimedOut

    var errorDescription: String? {
        switch self {
        case .displayUnavailable: String(localized: "The display to record is not available.")
        case .notStarted: String(localized: "Screen recording has not started.")
        case .finishTimedOut: String(localized: "The screen recording did not finish writing its movie.")
        }
    }
}

/// ScreenCaptureKit's stream with a recording output (macOS 15): H.264 MP4, long edge at most 2560 pixels, up to
/// 60 frames per second, cursor included and VoiceInk excluded.
final class ScreenCaptureKitRecording: NSObject, ScreenRecording, SCStreamDelegate, SCRecordingOutputDelegate, SCStreamOutput,
    @unchecked Sendable
{
    static let maximumLongEdge = 2_560
    static let finishTimeout: Duration = .seconds(10)

    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "ScreenRecording")
    private let sampleQueue = DispatchQueue(label: "com.prakashjoshipax.voiceink.annotationFrames", qos: .userInitiated)
    private let state = OSAllocatedUnfairLock(initialState: State())
    private var stream: SCStream?
    private var display: AnnotationManifest.Display?
    /// Called on a background queue with each captured frame; the movie is written separately.
    var onFrame: ((CMSampleBuffer) -> Void)?

    private struct State {
        var recordingStarted = false
        var firstFrameNanoseconds: UInt64?
        var finish: CheckedContinuation<Void, Error>?
        var finished = false
        var failure: Error?
    }

    func start(displayID: CGDirectDisplayID, writingTo url: URL) async throws -> AnnotationManifest.Display {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw ScreenRecordingError.displayUnavailable
        }
        let own = content.applications.filter { $0.processID == getpid() }
        let filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
        let scale = Double(filter.pointPixelScale)
        let size = Self.outputSize(points: filter.contentRect.size, scale: scale)

        let configuration = SCStreamConfiguration()
        configuration.width = size.width
        configuration.height = size.height
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        configuration.showsCursor = true
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.queueDepth = 8
        configuration.capturesAudio = false

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
        let recordingConfiguration = SCRecordingOutputConfiguration()
        recordingConfiguration.outputURL = url
        recordingConfiguration.outputFileType = .mp4
        recordingConfiguration.videoCodecType = .h264
        try stream.addRecordingOutput(SCRecordingOutput(configuration: recordingConfiguration, delegate: self))
        try await stream.startCapture()
        self.stream = stream
        let recorded = AnnotationManifest.Display(id: displayID, width: size.width, height: size.height, scale: scale)
        self.display = recorded
        return recorded
    }

    /// Stops capture and waits for the movie to close, for at most `finishTimeout` in all; a stream or delegate that
    /// never answers is abandoned rather than awaited.
    func stop() async throws -> ScreenRecordingResult {
        guard let stream, let display else { throw ScreenRecordingError.notStarted }
        self.stream = nil
        let outcome = await Self.firstOutcome(timeout: Self.finishTimeout) {
            try? await stream.stopCapture()
            try await self.waitForFinish()
        }
        try outcome.get()
        return ScreenRecordingResult(display: display, firstFrameNanoseconds: state.withLock { $0.firstFrameNanoseconds })
    }

    /// The operation's result or a timeout, whichever comes first; the loser keeps running unobserved.
    static func firstOutcome(
        timeout: Duration, _ operation: @escaping @Sendable () async throws -> Void
    ) async -> Result<Void, Error> {
        let pending = OSAllocatedUnfairLock<CheckedContinuation<Result<Void, Error>, Never>?>(initialState: nil)
        @Sendable func resolve(_ result: Result<Void, Error>) {
            pending.withLock { continuation in
                continuation?.resume(returning: result)
                continuation = nil
            }
        }
        return await withCheckedContinuation { continuation in
            pending.withLock { $0 = continuation }
            Task {
                do {
                    try await operation()
                    resolve(.success(()))
                } catch {
                    resolve(.failure(error))
                }
            }
            Task {
                try? await Task.sleep(for: timeout)
                resolve(.failure(ScreenRecordingError.finishTimedOut))
            }
        }
    }

    /// Even pixel sizes with the long edge capped, keeping the display's aspect ratio.
    static func outputSize(points: CGSize, scale: Double) -> (width: Int, height: Int) {
        var width = Double(points.width) * scale
        var height = Double(points.height) * scale
        let longEdge = max(width, height)
        if longEdge > Double(maximumLongEdge) {
            let factor = Double(maximumLongEdge) / longEdge
            width *= factor
            height *= factor
        }
        func even(_ value: Double) -> Int { max(2, Int(value.rounded(.down)) & ~1) }
        return (even(width), even(height))
    }

    private func waitForFinish() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let resume: Result<Void, Error>? = state.withLock { state in
                if state.finished { return state.failure.map { .failure($0) } ?? .success(()) }
                state.finish = continuation
                return nil
            }
            if let resume { continuation.resume(with: resume) }
        }
    }

    private func finish(with failure: Error?) {
        let continuation = state.withLock { state -> CheckedContinuation<Void, Error>? in
            guard !state.finished else { return nil }
            state.finished = true
            state.failure = failure
            defer { state.finish = nil }
            return state.finish
        }
        if let failure { continuation?.resume(throwing: failure) } else { continuation?.resume() }
    }

    // MARK: - Delegates

    func recordingOutputDidStartRecording(_ recordingOutput: SCRecordingOutput) {
        state.withLock { $0.recordingStarted = true }
    }

    func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        finish(with: nil)
    }

    func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        logger.error("Screen recording output failed: \(error, privacy: .public)")
        finish(with: error)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        logger.error("Screen recording stream stopped: \(error, privacy: .public)")
        finish(with: error)
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid else { return }
        // ScreenCaptureKit stamps frames on the host clock, which is the uptime clock the narration uses; the first
        // frame after the movie started recording places the movie on the annotation timeline.
        let presentation = sampleBuffer.presentationTimeStamp
        if presentation.isValid, presentation.seconds > 0 {
            let nanoseconds = UInt64(presentation.seconds * 1_000_000_000)
            state.withLock { if $0.recordingStarted, $0.firstFrameNanoseconds == nil { $0.firstFrameNanoseconds = nanoseconds } }
        }
        onFrame?(sampleBuffer)
    }
}

extension NSScreen {
    /// The display under the pointer, else the main display.
    static var displayUnderPointer: CGDirectDisplayID? {
        let location = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(location, $0.frame, false) } ?? NSScreen.main
        return screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }
}
