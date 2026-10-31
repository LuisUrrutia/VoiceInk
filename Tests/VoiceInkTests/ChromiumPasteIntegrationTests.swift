import AppKit
import XCTest
@testable import VoiceInk

/// Posts real keyboard events, so it runs only against a disposable browser
/// process named by `VOICEINK_CHROMIUM_PASTE_PID`. Insertion is checked in the page.
@MainActor
final class ChromiumPasteIntegrationTests: XCTestCase {
    func testOptInDeliveryTypesIntoAffectedChromiumWithoutTouchingClipboard() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let processID = environment["VOICEINK_CHROMIUM_PASTE_PID"].flatMap(pid_t.init),
            let application = NSRunningApplication(processIdentifier: processID)
        else { throw XCTSkip("Set VOICEINK_CHROMIUM_PASTE_PID to a disposable Chromium 155/156 process") }
        // Failed deliveries copy their text to the clipboard, so require posting access first.
        guard AXIsProcessTrusted() else { throw XCTSkip("VoiceInk Dev needs Accessibility access to post events") }
        let trials = environment["VOICEINK_CHROMIUM_PASTE_TRIALS"].flatMap(Int.init) ?? 20
        let target = PasteApplication(application)
        XCTAssertTrue(ChromiumPasteRace().losesSyntheticPaste(target))
        let clipboardChangeCount = NSPasteboard.general.changeCount

        var results: [CursorPaster.PasteResult] = []
        for trial in 0..<trials {
            let delivery = RecordingDeliverySession(destination: .originalApplication(target))
            results.append(await CursorPaster.startPasteAtCursor("V\(trial);", deliverySession: delivery).value.result)
            try await Task.sleep(for: .seconds(0.35))
        }

        XCTAssertEqual(results, Array(repeating: .commandPosted, count: trials))
        XCTAssertEqual(NSPasteboard.general.changeCount, clipboardChangeCount)
    }
}
