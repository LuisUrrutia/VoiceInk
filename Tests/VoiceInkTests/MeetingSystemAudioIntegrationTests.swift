import AVFoundation
import XCTest

@testable import VoiceInk

/// Opt-in: `TEST_RUNNER_VOICEINK_PROCESS_TAP=1` records a real process tap while `afplay` plays a tone in another
/// process. Needs System Audio Recording for the test host and an audible default output.
final class MeetingSystemAudioIntegrationTests: XCTestCase {
    func testProcessTapRecordsAnotherProcessesOutput() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["VOICEINK_PROCESS_TAP"] == "1", "Set TEST_RUNNER_VOICEINK_PROCESS_TAP=1")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MeetingTap-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("system.wav")
        let capture = ProcessTapSystemAudioCapture()

        try capture.start(writingTo: url, meetingStartNanoseconds: DispatchTime.now().uptimeNanoseconds)
        let player = Process()
        player.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        player.arguments = ["/System/Library/Sounds/Ping.aiff"]
        try player.run()
        player.waitUntilExit()
        Thread.sleep(forTimeInterval: 0.5)
        let result = capture.stop()

        XCTAssertNil(result.failure)
        XCTAssertTrue(result.heardSignal, "The tap delivered only silence; check System Audio Recording")
        XCTAssertFalse(result.timeline.anchors.isEmpty)
        let file = try AVAudioFile(forReading: url)
        XCTAssertEqual(file.fileFormat.sampleRate, 16_000)
        XCTAssertGreaterThan(file.length, 16_000)
    }
}
