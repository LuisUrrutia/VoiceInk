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

/// Adds and removes NSEvent monitors; a seam so tests can deliver events.
@MainActor
protocol AnnotationEventMonitoring {
    func addGlobal(_ mask: NSEvent.EventTypeMask, _ handler: @escaping (NSEvent) -> Void) -> Any?
    func addLocal(_ mask: NSEvent.EventTypeMask, _ handler: @escaping (NSEvent) -> NSEvent?) -> Any?
    func remove(_ monitor: Any)
}

struct SystemEventMonitoring: AnnotationEventMonitoring {
    func addGlobal(_ mask: NSEvent.EventTypeMask, _ handler: @escaping (NSEvent) -> Void) -> Any? {
        NSEvent.addGlobalMonitorForEvents(matching: mask, handler: handler)
    }

    func addLocal(_ mask: NSEvent.EventTypeMask, _ handler: @escaping (NSEvent) -> NSEvent?) -> Any? {
        NSEvent.addLocalMonitorForEvents(matching: mask, handler: handler)
    }

    func remove(_ monitor: Any) { NSEvent.removeMonitor(monitor) }
}

/// A transparent overlay on the recorded display draws ink while the pen is on or Shift alone is held, as in Hex.
/// VoiceInk's windows are excluded from the recording, so ink never appears in the movie; keyframes draw it
/// later. Clicks and scrolls elsewhere are logged with their positions; keystrokes are not.
@MainActor
final class AnnotationInputCapture: AnnotationInputCapturing {
    /// Scrolls are logged at most this often.
    static let scrollInterval: TimeInterval = 0.5
    /// Above application windows; the annotation capsule sits above this, so its controls stay reachable.
    static let overlayLevel = NSWindow.Level.statusBar

    private let monitoring: any AnnotationEventMonitoring
    private let displayFrame: (CGDirectDisplayID) -> CGRect?

    private var panel: NSPanel?
    private(set) var ink: InkView?
    private var monitors: [Any] = []
    private var frame: CGRect = .zero
    private var startNanoseconds: UInt64 = 0
    private var events: [AnnotationEvent] = []
    private var lastScroll: TimeInterval = -.infinity
    private(set) var isPenEnabled = false
    private var isShiftHeld = false
    /// Whether the overlay currently catches the pointer to draw.
    var isTakingPointer: Bool { isPenEnabled || isShiftHeld }

    init(
        monitoring: (any AnnotationEventMonitoring)? = nil,
        displayFrame: @escaping (CGDirectDisplayID) -> CGRect? = { id in
            NSScreen.screens.first {
                $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID == id
            }?.frame
        }
    ) {
        self.monitoring = monitoring ?? SystemEventMonitoring()
        self.displayFrame = displayFrame
    }

    func start(displayID: CGDirectDisplayID, startNanoseconds: UInt64) {
        guard let displayFrame = displayFrame(displayID) else { return }
        frame = displayFrame
        self.startNanoseconds = startNanoseconds
        let ink = InkView(frame: CGRect(origin: .zero, size: frame.size))
        ink.time = { [weak self] in self?.now() ?? 0 }
        ink.normalize = { [weak self] point in self.flatMap { AnnotationMarks.normalized(point, in: $0.frame) } }
        // The overlay's own clicks never reach the monitors, so they refresh the Shift state here.
        ink.shouldDraw = { [weak self] event in
            guard let self else { return false }
            self.refreshShift(from: event)
            return self.isTakingPointer
        }
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.contentView = ink
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = Self.overlayLevel
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.setFrame(frame, display: false)
        panel.orderFrontRegardless()
        self.panel = panel
        self.ink = ink

        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .scrollWheel, .flagsChanged]
        if let global = monitoring.addGlobal(mask, { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }) { monitors.append(global) }
        if let local = monitoring.addLocal([.flagsChanged], { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
            return event
        }) { monitors.append(local) }
    }

    func setPenEnabled(_ isEnabled: Bool) {
        isPenEnabled = isEnabled
        updateDrawing()
    }

    func stop() -> (strokes: [AnnotationStroke], events: [AnnotationEvent], displaySize: CGSize) {
        monitors.forEach(monitoring.remove)
        monitors = []
        // A stroke still being drawn when Stop arrives is kept as drawn so far.
        ink?.finishCurrentStroke()
        let strokes = ink?.finishedStrokes ?? []
        panel?.close()
        panel = nil
        ink = nil
        return (strokes, events, frame.size)
    }

    private func now() -> TimeInterval {
        Double(Int64(bitPattern: DispatchTime.now().uptimeNanoseconds &- startNanoseconds)) / 1_000_000_000
    }

    func handle(_ event: NSEvent) {
        refreshShift(from: event)
        guard event.type != .flagsChanged, !isTakingPointer else { return }
        // A global event's location is in screen coordinates, captured when it happened, as is its timestamp.
        let location = event.window.map { $0.convertPoint(toScreen: event.locationInWindow) } ?? event.locationInWindow
        guard let point = AnnotationMarks.normalized(location, in: frame) else { return }
        let t = event.timestamp - Double(startNanoseconds) / 1_000_000_000
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

    /// Every event carries the modifiers, so a missed Shift release (Secure Input, a lost flagsChanged) heals on the next
    /// event, whether it reaches the overlay or another app.
    private func refreshShift(from event: NSEvent) {
        let isShiftAlone = event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .shift
        guard isShiftAlone != isShiftHeld else { return }
        isShiftHeld = isShiftAlone
        updateDrawing()
    }

    /// The overlay takes the pointer only while drawing, so clicks reach the apps otherwise.
    private func updateDrawing() {
        panel?.ignoresMouseEvents = !isTakingPointer
    }
}

/// Draws strokes in progress and fading ones, and keeps every finished stroke.
final class InkView: NSView {
    var time: () -> TimeInterval = { 0 }
    var normalize: (CGPoint) -> CGPoint? = { _ in nil }
    /// Whether a press should start a stroke; a press with drawing switched off is not ink.
    var shouldDraw: (NSEvent) -> Bool = { _ in true }
    private var isDrawingStroke = false
    private(set) var finishedStrokes: [AnnotationStroke] = []
    private var current: [CGPoint] = []
    private var currentPoints: [AnnotationStroke.Point] = []
    private var visible: [(path: [CGPoint], endedAt: TimeInterval)] = []
    private var fadeTimer: Timer?

    override var isFlipped: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        isDrawingStroke = shouldDraw(event)
        if isDrawingStroke { add(event, starting: true) }
    }

    override func mouseDragged(with event: NSEvent) {
        if isDrawingStroke { add(event, starting: false) }
    }

    override func mouseUp(with event: NSEvent) {
        guard isDrawingStroke else { return }
        add(event, starting: false)
        finishCurrentStroke()
    }

    func finishCurrentStroke() {
        isDrawingStroke = false
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
