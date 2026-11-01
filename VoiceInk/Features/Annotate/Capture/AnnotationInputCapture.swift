import AppKit
import CoreGraphics
import Foundation

/// What the user draws and clicks on the recorded display while an annotation records.
@MainActor
protocol AnnotationInputCapturing: AnyObject {
    var isPenEnabled: Bool { get }
    func start(displayID: CGDirectDisplayID, startNanoseconds: UInt64)
    func setPenEnabled(_ isEnabled: Bool)
    /// Ends input and returns everything recorded, in annotation time.
    func stop() -> (strokes: [AnnotationStroke], events: [AnnotationEvent], displaySize: CGSize)
}

/// A transparent overlay on the recorded display draws ink while the pen is on or Shift alone is held, as in Hex.
/// VoiceInk's windows are excluded from the recording, so ink never appears in the movie; keyframes draw it
/// later. Clicks and scrolls elsewhere are logged with their positions; keystrokes are not.
@MainActor
final class AnnotationInputCapture: AnnotationInputCapturing {
    /// Scrolls are logged at most this often.
    static let scrollInterval: TimeInterval = 0.5

    private var panel: NSPanel?
    private var ink: InkView?
    private var monitors: [Any] = []
    private var frame: CGRect = .zero
    private var startNanoseconds: UInt64 = 0
    private var events: [AnnotationEvent] = []
    private var lastScroll: TimeInterval = -.infinity
    private(set) var isPenEnabled = false
    private var isShiftHeld = false

    func start(displayID: CGDirectDisplayID, startNanoseconds: UInt64) {
        guard let screen = NSScreen.screens.first(where: {
            $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID == displayID
        }) else { return }
        frame = screen.frame
        self.startNanoseconds = startNanoseconds
        let ink = InkView(frame: CGRect(origin: .zero, size: frame.size))
        ink.time = { [weak self] in self?.now() ?? 0 }
        ink.normalize = { [weak self] point in self.flatMap { AnnotationMarks.normalized(point, in: $0.frame) } }
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.contentView = ink
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .screenSaver
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.setFrame(frame, display: false)
        panel.orderFrontRegardless()
        self.panel = panel
        self.ink = ink

        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .scrollWheel, .flagsChanged]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged], handler: { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
            return event
        }) { monitors.append(local) }
    }

    func setPenEnabled(_ isEnabled: Bool) {
        isPenEnabled = isEnabled
        updateDrawing()
    }

    func stop() -> (strokes: [AnnotationStroke], events: [AnnotationEvent], displaySize: CGSize) {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        let strokes = ink?.finishedStrokes ?? []
        panel?.close()
        panel = nil
        ink = nil
        return (strokes, events, frame.size)
    }

    private func now() -> TimeInterval {
        Double(Int64(bitPattern: DispatchTime.now().uptimeNanoseconds &- startNanoseconds)) / 1_000_000_000
    }

    private func handle(_ event: NSEvent) {
        if event.type == .flagsChanged {
            isShiftHeld = event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .shift
            updateDrawing()
            return
        }
        guard !(panel?.ignoresMouseEvents == false), let point = AnnotationMarks.normalized(NSEvent.mouseLocation, in: frame) else { return }
        let t = now()
        let kind: AnnotationEvent.Kind
        switch event.type {
        case .leftMouseDown: kind = .click
        case .rightMouseDown: kind = .rightClick
        case .scrollWheel:
            guard t - lastScroll >= Self.scrollInterval else { return }
            lastScroll = t
            kind = .scroll
        default: return
        }
        events.append(AnnotationEvent(kind: kind, t: t, x: point.x, y: point.y))
    }

    /// The overlay takes the pointer only while drawing, so clicks reach the apps otherwise.
    private func updateDrawing() {
        panel?.ignoresMouseEvents = !(isPenEnabled || isShiftHeld)
    }
}

/// Draws strokes in progress and fading ones, and keeps every finished stroke.
final class InkView: NSView {
    var time: () -> TimeInterval = { 0 }
    var normalize: (CGPoint) -> CGPoint? = { _ in nil }
    private(set) var finishedStrokes: [AnnotationStroke] = []
    private var current: [CGPoint] = []
    private var currentPoints: [AnnotationStroke.Point] = []
    private var visible: [(path: [CGPoint], endedAt: TimeInterval)] = []
    private var fadeTimer: Timer?

    override var isFlipped: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) { add(event, starting: true) }
    override func mouseDragged(with event: NSEvent) { add(event, starting: false) }

    override func mouseUp(with event: NSEvent) {
        add(event, starting: false)
        if !currentPoints.isEmpty {
            finishedStrokes.append(AnnotationStroke(points: currentPoints))
            visible.append((current, time()))
        }
        current = []
        currentPoints = []
        startFading()
        needsDisplay = true
    }

    private func add(_ event: NSEvent, starting: Bool) {
        if starting {
            current = []
            currentPoints = []
        }
        let local = convert(event.locationInWindow, from: nil)
        current.append(local)
        let global = window?.convertPoint(toScreen: event.locationInWindow) ?? local
        if let point = normalize(global) {
            currentPoints.append(AnnotationStroke.Point(x: point.x, y: point.y, t: time()))
        }
        needsDisplay = true
    }

    private func startFading() {
        guard fadeTimer == nil else { return }
        fadeTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] timer in
            guard let self else { return timer.invalidate() }
            let now = self.time()
            self.visible.removeAll { AnnotationMarks.opacity(endedAt: $0.endedAt, now: now) <= 0 }
            self.needsDisplay = true
            if self.visible.isEmpty {
                timer.invalidate()
                self.fadeTimer = nil
            }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let now = time()
        func stroke(_ points: [CGPoint], opacity: Double) {
            guard points.count > 1 else { return }
            let path = NSBezierPath()
            path.lineWidth = 4
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.move(to: points[0])
            points.dropFirst().forEach { path.line(to: $0) }
            NSColor.systemRed.withAlphaComponent(opacity).setStroke()
            path.stroke()
        }
        for line in visible { stroke(line.path, opacity: AnnotationMarks.opacity(endedAt: line.endedAt, now: now)) }
        stroke(current, opacity: 1)
    }
}
