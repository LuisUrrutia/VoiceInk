import Foundation
import XCTest
@testable import VoiceInk

@MainActor
final class RecordingEnhancementCancellationTests: XCTestCase {
    func testRecordingCancellationStopsEnhancementProcessAndKeepsOriginalTarget() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = directory.appendingPathComponent("started")
        let target = PasteApplication(processID: 123, bundleIdentifier: "fixture.original")
        let session = RecordingDeliverySession(destination: .originalApplication(target))
        let task = Task {
            try await TranscriptionPipeline.performEnhancement(deliverySession: session) {
                try await LocalCLIService.executeCommand(
                    commandTemplate: ": > " + self.quote(marker.path) + "; /usr/bin/perl -e 'alarm 8; sleep 8; print \"late\";'",
                    systemPrompt: "synthetic", userPrompt: "synthetic", fullPrompt: "synthetic", timeout: 5
                )
            }
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !FileManager.default.fileExists(atPath: marker.path), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
        let start = ContinuousClock.now

        session.cancel()
        do { _ = try await task.value; XCTFail("Canceled enhancement must fail") }
        catch { XCTAssertTrue(error is CancellationError, "Unexpected error: \(error)") }

        XCTAssertLessThan(start.duration(to: .now), .seconds(3))
        XCTAssertEqual(session.destination, .originalApplication(target))
    }

    func testAlreadyCanceledRecordingDoesNotBeginEnhancement() async {
        let session = RecordingDeliverySession(destination: .currentApplication)
        session.cancel()
        var invoked = false

        do {
            _ = try await TranscriptionPipeline.performEnhancement(deliverySession: session) {
                invoked = true
                return "late"
            }
            XCTFail("An already canceled recording must fail")
        } catch { XCTAssertTrue(error is CancellationError) }

        XCTAssertFalse(invoked)
    }

    func testParentTaskCancellationReachesEnhancementWithoutSession() async {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await TranscriptionPipeline.performEnhancement(deliverySession: nil) {
                try await Task.sleep(for: .seconds(8))
                return "late"
            }
        }

        do { _ = try await task.value; XCTFail("A canceled parent task must fail") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    func testCanceledNoncooperativeEnhancementCannotPublishLateResult() async throws {
        let session = RecordingDeliverySession(destination: .currentApplication)
        let task = Task {
            try await TranscriptionPipeline.performEnhancement(deliverySession: session) {
                session.cancel()
                return "late"
            }
        }

        do { _ = try await task.value; XCTFail("A late successful result must be rejected") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    func testSuccessfulEnhancementCanBeFollowedByNormalDeliveryOwnership() async throws {
        let session = RecordingDeliverySession(destination: .currentApplication)

        let result = try await TranscriptionPipeline.performEnhancement(deliverySession: session) { "exact result" }
        let delivery = Task { try await Task.sleep(for: .seconds(8)) }
        session.own(delivery)
        session.cancel()

        XCTAssertEqual(result, "exact result")
        do { try await delivery.value; XCTFail("The next owned task must be canceled") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    private func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func makeDirectory() throws -> URL {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let directory = root.appendingPathComponent(".tmp/recording-enhancement-tests/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
