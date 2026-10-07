import Foundation

@MainActor
final class RecordingFinalization {
    private var activeID: UUID?
    private var waiters: [CheckedContinuation<Void, Never>] = []

    var isRunning: Bool { activeID != nil }

    func begin() -> UUID? {
        guard activeID == nil else { return nil }
        let id = UUID()
        activeID = id
        return id
    }

    func finish(_ id: UUID) {
        guard activeID == id else { return }
        activeID = nil
        let pendingWaiters = waiters
        waiters.removeAll()
        for waiter in pendingWaiters {
            waiter.resume()
        }
    }

    func waitUntilFinished() async {
        while activeID != nil {
            await withCheckedContinuation { waiters.append($0) }
        }
    }
}
