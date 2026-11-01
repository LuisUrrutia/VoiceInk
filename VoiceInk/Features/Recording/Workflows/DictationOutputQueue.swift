import Foundation

/// Admits dictations and releases their outputs in submission order, one delivery at a time.
///
/// Adapted from Hex's `OrderedOutputs` and `MAX_PENDING_OUTPUTS`. A dictation holds an admission from capture start
/// until its job is removed, and `capacity` bounds those admissions. Each job submits its delivery, or a skipped
/// placeholder when it was canceled or discarded, under the sequence it received at Stop; the queue releases the run of
/// consecutive sequences, ignores a late completion for a skipped sequence, and awaits each delivery (its paste,
/// including the Auto Send wait) before releasing the next.
@MainActor
final class DictationOutputQueue {
    typealias Delivery = @MainActor () async -> Void

    private enum Entry {
        case waiting(destination: PasteDestination?, continuation: CheckedContinuation<Bool, Never>)
        case skipped
    }

    var capacity: Int
    /// A live capture, or one inside its awaited hardware stop.
    var isCaptureActive: @MainActor () -> Bool = { false }
    var isRecordingShortcutHeld: @MainActor () -> Bool = { false }
    var frontmost: @MainActor () -> PasteApplication? = { .frontmost }

    private var admitted: Set<UUID> = []
    private var lastAssignedSequence: UInt64 = 0
    private var nextReleasedSequence: UInt64 = 1
    private var entries: [UInt64: Entry] = [:]
    private var isDelivering = false

    init(capacity: Int) {
        self.capacity = capacity
    }

    var admittedCount: Int { admitted.count }
    var waitingCount: Int { entries.count }

    /// Reserves a slot at capture start; false when the queue is full.
    func admit(_ dictationID: UUID) -> Bool {
        guard admitted.contains(dictationID) || admitted.count < capacity else { return false }
        admitted.insert(dictationID)
        return true
    }

    func withdraw(_ dictationID: UUID) {
        admitted.remove(dictationID)
    }

    /// The submission order, taken at Stop.
    func assignSequence() -> UInt64 {
        lastAssignedSequence += 1
        return lastAssignedSequence
    }

    /// Runs `delivery` when every earlier sequence has been delivered or skipped and the release rule allows it.
    /// Returns false without running it when the sequence was skipped first or the waiting task is canceled.
    @discardableResult
    func deliver(sequence: UInt64, destination: PasteDestination?, _ delivery: Delivery) async -> Bool {
        guard await turn(sequence: sequence, destination: destination) else { return false }
        defer {
            isDelivering = false
            releaseReadyOutputs()
        }
        await delivery()
        return true
    }

    /// A placeholder for a job that will not deliver; it replaces a waiting delivery that has not been released.
    func skip(_ sequence: UInt64) {
        guard sequence >= nextReleasedSequence, sequence <= lastAssignedSequence else { return }
        if case .waiting(_, let continuation) = entries[sequence] {
            continuation.resume(returning: false)
        }
        entries[sequence] = .skipped
        releaseReadyOutputs()
    }

    /// Rechecks a held head delivery, such as after a capture's hardware stop.
    func releaseHeldOutputs() {
        releaseReadyOutputs()
    }

    /// While another dictation captures, only a delivery whose destination is already frontmost may run, and only while
    /// no recording shortcut is held, so a paste never takes focus from the capture or lands during a press.
    func mayRelease(to destination: PasteDestination?) -> Bool {
        guard isCaptureActive() else { return true }
        guard !isRecordingShortcutHeld() else { return false }
        guard case .originalApplication(let application?) = destination else { return true }
        return application == frontmost()
    }

    private func turn(sequence: UInt64, destination: PasteDestination?) async -> Bool {
        guard !Task.isCancelled, sequence >= nextReleasedSequence, entries[sequence] == nil else { return false }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                entries[sequence] = .waiting(destination: destination, continuation: continuation)
                releaseReadyOutputs()
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.skip(sequence) }
        }
    }

    private func releaseReadyOutputs() {
        while !isDelivering, let entry = entries[nextReleasedSequence] {
            if case .waiting(let destination, let continuation) = entry {
                guard mayRelease(to: destination) else { return }
                isDelivering = true
                entries[nextReleasedSequence] = nil
                nextReleasedSequence += 1
                continuation.resume(returning: true)
            } else {
                entries[nextReleasedSequence] = nil
                nextReleasedSequence += 1
            }
        }
    }
}
