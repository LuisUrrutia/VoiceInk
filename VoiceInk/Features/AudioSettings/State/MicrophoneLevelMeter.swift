import Combine
import Foundation

/// The latest meter the recorder's render callback published, read without opening the microphone.
struct MicrophoneLevelReading: Equatable {
    let peakDBFS: Float
    let capturedThroughNanoseconds: UInt64?
}

/// Level bars for the input in use. Adapted from Hex's settings meter (https://github.com/anomalyco/hex, MIT):
/// the peak follows with a gain of 3 and falls by at most 0.12 per reading, shown in six steps; a meter that
/// received no audio for 250 ms is idle and flat.
struct MicrophoneLevelMeter {
    struct Display: Equatable {
        var isReceiving = false
        var step = 0
    }

    static let steps = 6
    static let freshNanoseconds: UInt64 = 250_000_000

    private(set) var display = Display()
    private var level: Float = 0
    private var lastCapturedThrough: UInt64?
    private var lastDeliveryAt: UInt64?

    /// True while the bars stand above rest, so they need frequent readings to follow the voice.
    var isMoving: Bool { display.isReceiving && display.step > 0 }

    /// Takes the latest reading; returns whether the displayed step or idle state changed. Audio counts as
    /// received only when `capturedThroughNanoseconds` advanced, so a stale meter of a closed input reads idle.
    mutating func observe(_ reading: MicrophoneLevelReading?, at now: UInt64) -> Bool {
        let before = display
        let capturedThrough = reading?.capturedThroughNanoseconds
        if let capturedThrough, let lastCapturedThrough, capturedThrough != lastCapturedThrough {
            lastDeliveryAt = now
        }
        lastCapturedThrough = capturedThrough
        let isReceiving = lastDeliveryAt.map { now &- $0 <= Self.freshNanoseconds } ?? false
        if isReceiving, let reading {
            let peak = min(max(pow(10, reading.peakDBFS / 20) * 3, 0), 1)
            level = max(peak, level - 0.12)
        } else {
            level = 0
        }
        display = Display(isReceiving: isReceiving, step: Int((level * Float(Self.steps)).rounded()))
        return display != before
    }
}

/// Polls the recorder's published meter while the Audio settings show it, and publishes only step changes.
/// Bars at rest are read four times a second, so a quiet room causes no redraws; moving bars follow at about
/// 30 Hz, or four times a second with Reduce Motion.
@MainActor
final class MicrophoneLevelMonitor: ObservableObject {
    static let movingInterval: Duration = .milliseconds(33)
    static let restingInterval: Duration = .milliseconds(250)

    @Published private(set) var display = MicrophoneLevelMeter.Display()
    var reducesMotion = false

    private var meter = MicrophoneLevelMeter()
    private let read: @MainActor () -> MicrophoneLevelReading?
    private let now: () -> UInt64
    private var pollTask: Task<Void, Never>?

    init(
        read: @escaping @MainActor () -> MicrophoneLevelReading?,
        now: @escaping () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }
    ) {
        self.read = read
        self.now = now
    }

    convenience init(recorder: Recorder) {
        self.init(read: { [weak recorder] in recorder?.inputLevelReading() })
    }

    func start() {
        guard pollTask == nil else { return }
        pollTask = Task { @MainActor [weak self] in
            while let interval = self?.tick(), !Task.isCancelled {
                try? await Task.sleep(for: interval)
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        meter = MicrophoneLevelMeter()
        if display != meter.display { display = meter.display }
    }

    /// Takes one reading and returns the delay before the next.
    @discardableResult
    func tick() -> Duration {
        if meter.observe(read(), at: now()) {
            display = meter.display
        }
        return meter.isMoving && !reducesMotion ? Self.movingInterval : Self.restingInterval
    }

    deinit {
        pollTask?.cancel()
    }
}
