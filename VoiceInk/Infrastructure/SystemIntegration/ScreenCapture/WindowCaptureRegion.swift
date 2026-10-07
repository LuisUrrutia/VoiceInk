import Foundation

struct WindowCaptureRegion {
    let displayIndex: Int
    let sourceRect: CGRect

    init?(windowFrame: CGRect, displayFrames: [CGRect]) {
        var largestArea: CGFloat = 0
        var bestMatch: (index: Int, frame: CGRect, intersection: CGRect)?

        for (index, displayFrame) in displayFrames.enumerated() {
            let intersection = windowFrame.intersection(displayFrame)
            guard !intersection.isNull, !intersection.isEmpty else { continue }
            let area = intersection.width * intersection.height
            if area > largestArea {
                largestArea = area
                bestMatch = (index, displayFrame, intersection)
            }
        }

        guard let bestMatch else { return nil }
        displayIndex = bestMatch.index
        sourceRect = bestMatch.intersection.offsetBy(dx: -bestMatch.frame.minX, dy: -bestMatch.frame.minY)
    }

    func pixelSize(pointPixelScale: CGFloat) -> CGSize {
        let scale = min(pointPixelScale, 2800 / max(sourceRect.width, sourceRect.height))
        return CGSize(
            width: max(1, floor(sourceRect.width * scale)),
            height: max(1, floor(sourceRect.height * scale))
        )
    }
}
