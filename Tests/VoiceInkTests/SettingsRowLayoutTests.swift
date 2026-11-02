import AppKit
import SwiftUI
import XCTest

@testable import VoiceInk

@MainActor final class SettingsRowLayoutTests: XCTestCase {
    func testSwitchStaysBesideALongDescriptionThatWraps() throws {
        let frames = FrameRecorder()
        let summary = String(repeating: "Record calls and transcribe them on this Mac. ", count: 4)
        let form = Form {
            Section {
                Toggle(isOn: .constant(true)) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Meetings")
                        Text(summary).settingsDescription()
                    }
                    .recordFrame("label", in: frames)
                }
                .recordFrame("row", in: frames)
            }
        }
        .formStyle(AppSettingsFormStyle())

        render(form, width: 640)

        let label = try XCTUnwrap(frames["label"])
        let row = try XCTUnwrap(frames["row"])
        XCTAssertGreaterThan(label.height, 50, "The description wraps instead of pushing the switch down")
        XCTAssertEqual(row.height, label.height, accuracy: 1, "The switch shares the label's first line")
        XCTAssertLessThan(label.maxX, row.maxX - SettingsRowLayout.spacing)
    }

    func testFlexibleControlsBesideAShortLabelUseTheFreeSpace() throws {
        let frames = FrameRecorder()
        let form = Form {
            Section {
                LabeledContent("Lowered Volume") {
                    HStack(spacing: 8) {
                        Slider(value: .constant(0.2), in: 0...1).labelsHidden().frame(maxWidth: 180)
                            .recordFrame("slider", in: frames)
                        Text("20%").monospacedDigit()
                    }
                }
                LabeledContent("Screen Sharing Clipboard Push") {
                    TextField("Optional shell command", text: .constant("")).textFieldStyle(.roundedBorder)
                        .recordFrame("field", in: frames)
                }
            }
        }
        .formStyle(AppSettingsFormStyle())

        render(form, width: 732)

        XCTAssertEqual(try XCTUnwrap(frames["slider"]).width, 180, accuracy: 1, "The slider reaches its maximum width")
        XCTAssertGreaterThan(try XCTUnwrap(frames["field"]).width, 150, "The command field does not collapse")
    }

    func testControlTooWideForTheLabelMovesBelowIt() throws {
        let frames = FrameRecorder()
        let row = SettingsRowLayout {
            Text("Transcript folder for recorded meetings").recordFrame("label", in: frames)
            Color.gray.frame(width: 420, height: 20).recordFrame("control", in: frames)
        }

        render(row.frame(width: 500), width: 500)

        let label = try XCTUnwrap(frames["label"])
        let control = try XCTUnwrap(frames["control"])
        XCTAssertEqual(control.minY, label.maxY + SettingsRowLayout.stackedSpacing, accuracy: 1)
        XCTAssertEqual(control.maxX, 500, accuracy: 1)
    }

    func testSideBySideNeedsRoomForTheShorterOfTheLabelAndTheMinimum() {
        XCTAssertTrue(SettingsRowLayout.isSideBySide(availableWidth: 400, labelIdealWidth: 900, controlWidth: 40))
        XCTAssertTrue(SettingsRowLayout.isSideBySide(availableWidth: 200, labelIdealWidth: 60, controlWidth: 100))
        XCTAssertFalse(SettingsRowLayout.isSideBySide(availableWidth: 400, labelIdealWidth: 900, controlWidth: 220))
    }

    private func render(_ view: some View, width: CGFloat) {
        let host = NSHostingView(rootView: view.coordinateSpace(.named(FrameRecorder.space)))
        host.frame = CGRect(x: 0, y: 0, width: width, height: 400)
        for _ in 0..<3 {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
    }
}

@MainActor private final class FrameRecorder {
    nonisolated static let space = "SettingsRowLayoutTests"
    private var frames: [String: CGRect] = [:]
    subscript(name: String) -> CGRect? { frames[name] }
    func record(_ name: String, _ frame: CGRect) { frames[name] = frame }
}

private extension View {
    func recordFrame(_ name: String, in recorder: FrameRecorder) -> some View {
        onGeometryChange(for: CGRect.self) { $0.frame(in: .named(FrameRecorder.space)) } action: {
            recorder.record(name, $0)
        }
    }
}
