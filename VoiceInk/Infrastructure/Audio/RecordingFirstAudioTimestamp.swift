import Atomics

final class RecordingFirstAudioTimestamp: Sendable {
    private let boundary = ManagedAtomic<UInt64>(.max)
    private let first = ManagedAtomic<UInt64>(0)

    var nanoseconds: UInt64? {
        let start = boundary.load(ordering: .acquiring)
        let value = first.load(ordering: .acquiring)
        return value == 0 || (start != .max && value < start) ? nil : value
    }

    func arm(at nanoseconds: UInt64) {
        boundary.store(.max, ordering: .releasing)
        first.store(0, ordering: .releasing)
        boundary.store(nanoseconds, ordering: .releasing)
    }

    func disarm() {
        boundary.store(.max, ordering: .releasing)
    }

    func capture(at nanoseconds: UInt64) {
        let start = boundary.load(ordering: .acquiring)
        guard nanoseconds >= start else { return }
        let previous = first.load(ordering: .acquiring)
        guard previous == 0 || previous < start else { return }
        _ = first.compareExchange(expected: previous, desired: nanoseconds, ordering: .acquiringAndReleasing)
    }
}
