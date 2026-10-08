import CoreGraphics
import Testing
@testable import VoiceInk

struct ActiveWindowSelectorTests {
    private let currentPID: pid_t = 100
    private let focusedPID: pid_t = 200
    private let frame = CGRect(x: 10, y: 20, width: 800, height: 600)

    @Test func identifiesFocusedWindowWithIdenticalFramesAndTitles() {
        let windows = [window(1, title: "Terminal"), window(2, title: "Terminal")]
        let focus = focusedWindow(windowID: 2, title: "Terminal", frame: frame)

        let selected = ActiveWindowSelector.select(from: windows, focusedWindow: focus, excluding: currentPID)

        #expect(selected?.windowID == 2)
    }

    @Test func identityTakesPriorityOverStaleFrameAndTitle() {
        let movedFrame = CGRect(x: 300, y: 200, width: 900, height: 700)
        let windows = [window(1, title: "Old title"), window(2, title: "New title", frame: movedFrame)]
        let focus = focusedWindow(windowID: 2, title: "Old title", frame: frame)

        let selected = ActiveWindowSelector.select(from: windows, focusedWindow: focus, excluding: currentPID)

        #expect(selected?.windowID == 2)
    }

    @Test(arguments: [CGWindowID?.none, CGWindowID(99)])
    func fallsBackToClosestFrameWithoutMatchingIdentity(windowID: CGWindowID?) {
        let nearFrame = frame.offsetBy(dx: 5, dy: 5)
        let windows = [window(1, frame: frame.offsetBy(dx: 300, dy: 0)), window(2, frame: nearFrame)]
        let focus = focusedWindow(windowID: windowID, frame: frame)

        let selected = ActiveWindowSelector.select(from: windows, focusedWindow: focus, excluding: currentPID)

        #expect(selected?.windowID == 2)
    }

    @Test func fallsBackToNormalizedTitleOutsideFrameTolerance() {
        let windows = [window(1, title: "Other"), window(2, title: "  Document \n")]
        let focus = focusedWindow(title: "Document", frame: frame.offsetBy(dx: 300, dy: 0))

        let selected = ActiveWindowSelector.select(from: windows, focusedWindow: focus, excluding: currentPID)

        #expect(selected?.windowID == 2)
    }

    @Test(arguments: [CGFloat(96), CGFloat(97)])
    func appliesFrameToleranceBeforeTitle(offset: CGFloat) {
        let windows = [window(1, title: "Geometry"), window(2, title: "Title", frame: frame.offsetBy(dx: 300, dy: 0))]
        let focus = focusedWindow(title: "Title", frame: frame.offsetBy(dx: offset, dy: 0))

        let selected = ActiveWindowSelector.select(from: windows, focusedWindow: focus, excluding: currentPID)

        #expect(selected?.windowID == (offset == 96 ? 1 : 2))
    }

    @Test func fallsBackToFirstWindowOfFocusedApplication() {
        let windows = [window(1, processID: 300), window(2), window(3)]
        let focus = focusedWindow(windowID: 99, title: "Missing")

        let selected = ActiveWindowSelector.select(from: windows, focusedWindow: focus, excluding: currentPID)

        #expect(selected?.windowID == 2)
    }

    @Test func doesNotMatchIdentityFromAnotherApplication() {
        let windows = [window(1, processID: 300), window(2)]
        let focus = focusedWindow(windowID: 1)

        let selected = ActiveWindowSelector.select(from: windows, focusedWindow: focus, excluding: currentPID)

        #expect(selected?.windowID == 2)
    }

    @Test func excludesUncapturableWindowsBeforeMatchingIdentity() {
        let windows = [
            window(1, processID: currentPID),
            window(2, windowLayer: 1),
            window(3, isOnScreen: false),
            window(4, frame: CGRect(x: 0, y: 0, width: 0, height: 600)),
            window(5, frame: CGRect(x: 0, y: 0, width: 800, height: 0)),
            window(6, processID: nil),
            window(7),
        ]

        for windowID in CGWindowID(1)...6 {
            let focus = focusedWindow(windowID: windowID)

            let selected = ActiveWindowSelector.select(from: windows, focusedWindow: focus, excluding: currentPID)

            #expect(selected?.windowID == 7)
        }
    }

    @Test func selectsFirstCandidateWithoutFocusedWindow() {
        let windows = [window(1, processID: currentPID), window(2, processID: 300), window(3)]

        let selected = ActiveWindowSelector.select(from: windows, focusedWindow: nil, excluding: currentPID)

        #expect(selected?.windowID == 2)
    }

    @Test func selectsFirstCandidateWhenFocusedApplicationHasNoWindows() {
        let windows = [window(1, processID: 300), window(2, processID: 400)]
        let focus = focusedWindow(windowID: 99)

        let selected = ActiveWindowSelector.select(from: windows, focusedWindow: focus, excluding: currentPID)

        #expect(selected?.windowID == 1)
    }

    @Test func returnsNilWithoutCapturableWindows() {
        let windows = [window(1, processID: currentPID), window(2, isOnScreen: false)]
        let focus = focusedWindow(windowID: 2)

        let selected = ActiveWindowSelector.select(from: windows, focusedWindow: focus, excluding: currentPID)

        #expect(selected == nil)
    }

    private func window(
        _ windowID: CGWindowID,
        title: String? = nil,
        frame: CGRect? = nil,
        windowLayer: Int = 0,
        isOnScreen: Bool = true
    ) -> ActiveWindowSelector.Window {
        window(windowID, processID: focusedPID, title: title, frame: frame, windowLayer: windowLayer, isOnScreen: isOnScreen)
    }

    private func window(
        _ windowID: CGWindowID,
        processID: pid_t?,
        title: String? = nil,
        frame: CGRect? = nil,
        windowLayer: Int = 0,
        isOnScreen: Bool = true
    ) -> ActiveWindowSelector.Window {
        ActiveWindowSelector.Window(
            windowID: windowID,
            processID: processID,
            title: title,
            frame: frame ?? self.frame,
            windowLayer: windowLayer,
            isOnScreen: isOnScreen
        )
    }

    private func focusedWindow(
        windowID: CGWindowID? = nil,
        title: String? = nil,
        frame: CGRect? = nil
    ) -> ActiveWindowSelector.FocusedWindow {
        ActiveWindowSelector.FocusedWindow(processID: focusedPID, windowID: windowID, title: title, frame: frame)
    }
}
