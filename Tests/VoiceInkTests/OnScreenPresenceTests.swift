import AppKit
import SwiftUI
import XCTest

@testable import VoiceInk

@MainActor final class OnScreenPresenceTests: XCTestCase {
    func testScrollingAMountedRowOutOfViewReportsItHiddenAndBackReportsItShown() {
        let model = ScrollModel()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled, .closable],
            backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ScrollingRow(model: model))
        window.orderFrontRegardless()
        defer { window.contentView = nil; window.orderOut(nil) }
        settle(window)
        XCTAssertEqual(model.reports.last, true, "The top row starts on screen")

        model.position.scrollTo(edge: .bottom)
        settle(window)
        XCTAssertEqual(model.reports.last, false, "The settings form keeps the row mounted while it scrolls away")

        model.position.scrollTo(edge: .top)
        settle(window)
        XCTAssertEqual(model.reports.last, true)

        window.close()
        settle(window)
        XCTAssertEqual(model.reports.last, false, "A closed retained window hides the row")
    }

    private func settle(_ window: NSWindow) {
        for _ in 0..<3 {
            window.contentView?.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
    }
}

@MainActor private final class ScrollModel: ObservableObject {
    @Published var position = ScrollPosition(edge: .top)
    var reports: [Bool] = []
}

private struct ScrollingRow: View {
    @ObservedObject var model: ScrollModel

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                Color.red.frame(height: 20).onScreenChange { model.reports.append($0) }
                Color.gray.frame(height: 2_000)
            }
        }
        .scrollPosition($model.position)
    }
}
