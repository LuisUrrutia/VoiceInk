import AppKit
import ApplicationServices
import Foundation
import ScreenCaptureKit
import Vision
import os

@MainActor
class ScreenCaptureService: ObservableObject {
    private nonisolated static let logger = Logger(
        subsystem: "com.prakashjoshipax.voiceink", category: "ScreenCaptureService")
    @Published var isCapturing = false
    @Published var lastCapturedText: String?

    static func requestScreenCapturePermissionRegistration() async -> Bool {
        if CGPreflightScreenCaptureAccess() {
            return true
        }

        if CGRequestScreenCaptureAccess() {
            return true
        }

        do {
            _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            return CGPreflightScreenCaptureAccess()
        }

        return CGPreflightScreenCaptureAccess()
    }

    func captureAndExtractText() async -> String? {
        guard !isCapturing, !Task.isCancelled else { return nil }

        isCapturing = true
        defer {
            isCapturing = false
        }

        let currentPID = ProcessInfo.processInfo.processIdentifier
        let focusedWindowHint = makeFocusedWindowHint(excluding: currentPID)

        guard
            let contextText = await Self.captureAndExtractWindowText(
                focusedWindowHint: focusedWindowHint,
                currentPID: currentPID
            )
        else {
            return nil
        }

        guard !Task.isCancelled else { return nil }
        lastCapturedText = contextText
        return contextText
    }

    private func makeFocusedWindowHint(excluding currentPID: pid_t) -> ActiveWindowSelector.FocusedWindow? {
        guard let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier,
            frontmostPID != currentPID
        else {
            return nil
        }

        var focusedTitle: String?
        var focusedFrame: CGRect?
        var focusedWindowID: CGWindowID?
        let processHint = ActiveWindowSelector.FocusedWindow(
            processID: frontmostPID, windowID: nil, title: nil, frame: nil
        )

        if AXIsProcessTrusted() {
            let appElement = AXUIElementCreateApplication(frontmostPID)
            // This lookup also runs during context capture; never use the multi-second AX default.
            guard AXUIElementSetMessagingTimeout(appElement, 0.03) == .success else { return processHint }
            if let focusedWindow = copyAXElementAttribute(kAXFocusedWindowAttribute, from: appElement) {
                guard AXUIElementSetMessagingTimeout(focusedWindow, 0.03) == .success else { return processHint }
                focusedWindowID = AccessibilityWindowID.resolve(focusedWindow)
                focusedTitle = normalized(copyStringAttribute(kAXTitleAttribute, from: focusedWindow))

                if let position = copyCGPointAttribute(kAXPositionAttribute, from: focusedWindow),
                    let size = copyCGSizeAttribute(kAXSizeAttribute, from: focusedWindow)
                {
                    focusedFrame = CGRect(origin: position, size: size)
                }
            }
        }

        return ActiveWindowSelector.FocusedWindow(
            processID: frontmostPID,
            windowID: focusedWindowID,
            title: focusedTitle,
            frame: focusedFrame
        )
    }

    private nonisolated static func captureAndExtractWindowText(
        focusedWindowHint: ActiveWindowSelector.FocusedWindow?,
        currentPID: pid_t
    ) async -> String? {
        do {
            try Task.checkCancellation()
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            try Task.checkCancellation()

            guard
                let window = findActiveWindow(
                    in: content.windows,
                    focusedWindowHint: focusedWindowHint,
                    currentPID: currentPID
                )
            else {
                logger.debug("No active window available for context capture")
                return nil
            }

            let title = window.title ?? window.owningApplication?.applicationName ?? "Unknown"
            let appName = window.owningApplication?.applicationName ?? "Unknown"

            guard let region = WindowCaptureRegion(
                windowFrame: window.frame, displayFrames: content.displays.map(\.frame)
            ) else {
                logger.debug("Active window does not intersect an available display")
                return nil
            }

            let filter = SCContentFilter(display: content.displays[region.displayIndex], including: [window])

            let configuration = SCStreamConfiguration()
            let pixelSize = region.pixelSize(pointPixelScale: CGFloat(filter.pointPixelScale))
            configuration.sourceRect = region.sourceRect
            configuration.width = Int(pixelSize.width)
            configuration.height = Int(pixelSize.height)
            configuration.showsCursor = false
            configuration.ignoreShadowsDisplay = true

            let cgImage = try await SCScreenshotManager.captureImage(
                contentFilter: filter, configuration: configuration)
            try Task.checkCancellation()

            var contextText = """
                Active Window: \(title)
                Application: \(appName)

                """

            let extractedText = await extractText(from: cgImage)
            try Task.checkCancellation()
            if let extractedText, !extractedText.isEmpty {
                contextText += "Window Content:\n\(extractedText)"
            } else {
                logger.debug("No text detected in captured window")
                contextText += "Window Content:\nNo text detected via OCR"
            }

            return contextText

        } catch {
            logger.error("Window context capture failed: \(error.localizedDescription, privacy: .private)")
            return nil
        }
    }

    private nonisolated static func findActiveWindow(
        in windows: [SCWindow],
        focusedWindowHint: ActiveWindowSelector.FocusedWindow?,
        currentPID: pid_t
    ) -> SCWindow? {
        let candidates = windows.map { window in
            ActiveWindowSelector.Window(
                windowID: window.windowID,
                processID: window.owningApplication?.processID,
                title: window.title,
                frame: window.frame,
                windowLayer: window.windowLayer,
                isOnScreen: window.isOnScreen
            )
        }

        guard let selected = ActiveWindowSelector.select(
            from: candidates,
            focusedWindow: focusedWindowHint,
            excluding: currentPID
        ) else { return nil }

        return windows.first(where: { $0.windowID == selected.windowID })
    }

    private nonisolated static func extractText(from cgImage: CGImage) async -> String? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true

        let requestHandler = VNImageRequestHandler(cgImage: cgImage, options: [:])

        return await withTaskCancellationHandler {
            do {
                try Task.checkCancellation()
                try requestHandler.perform([request])
                try Task.checkCancellation()
                guard let observations = request.results else {
                    return nil
                }
                let text =
                    observations
                    .compactMap { $0.topCandidates(1).first?.string }
                    .joined(separator: "\n")
                return text.isEmpty ? nil : text
            } catch is CancellationError {
                return nil
            } catch {
                logger.error("Window text recognition failed: \(error.localizedDescription, privacy: .private)")
                return nil
            }
        } onCancel: {
            request.cancel()
        }
    }

    private func copyAXElementAttribute(_ attribute: String, from element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
            let value,
            CFGetTypeID(value) == AXUIElementGetTypeID()
        else {
            return nil
        }

        return (value as! AXUIElement)
    }

    private func copyStringAttribute(_ attribute: String, from element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }

        return value as? String
    }

    private func copyCGPointAttribute(_ attribute: String, from element: AXUIElement) -> CGPoint? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
            let value,
            CFGetTypeID(value) == AXValueGetTypeID(),
            AXValueGetType(value as! AXValue) == .cgPoint
        else {
            return nil
        }

        let axValue = value as! AXValue
        var point = CGPoint.zero
        guard AXValueGetValue(axValue, .cgPoint, &point) else {
            return nil
        }

        return point
    }

    private func copyCGSizeAttribute(_ attribute: String, from element: AXUIElement) -> CGSize? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
            let value,
            CFGetTypeID(value) == AXValueGetTypeID(),
            AXValueGetType(value as! AXValue) == .cgSize
        else {
            return nil
        }

        let axValue = value as! AXValue
        var size = CGSize.zero
        guard AXValueGetValue(axValue, .cgSize, &size) else {
            return nil
        }

        return size
    }

    private nonisolated static func normalized(_ text: String?) -> String? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func normalized(_ text: String?) -> String? {
        Self.normalized(text)
    }
}
