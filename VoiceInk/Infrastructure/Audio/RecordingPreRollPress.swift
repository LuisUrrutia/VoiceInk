import Foundation

/// Bridges shortcut-thread presses to the current microphone without waiting for the main thread.
final class RecordingPreRollPress: @unchecked Sendable {
    private let lock = NSLock()
    private weak var hardware: (any RecordingHardware)?

    func bind(_ hardware: (any RecordingHardware)?) {
        lock.lock()
        self.hardware = hardware
        lock.unlock()
    }

    func hold(at eventTime: TimeInterval) {
        guard eventTime.isFinite, eventTime > 0,
            eventTime < Double(UInt64.max) / 1_000_000_000
        else { return }
        lock.lock()
        let hardware = self.hardware
        lock.unlock()
        hardware?.holdPreRoll(forPressAt: UInt64(eventTime * 1_000_000_000))
    }
}
