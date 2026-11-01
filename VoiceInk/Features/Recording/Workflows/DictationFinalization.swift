import Foundation

/// The engine's barriers: one capture barrier and a finish per job.
///
/// The capture barrier covers the awaited hardware stop, the WAV close and the stopped capture's History row,
/// along with failed starts, cancellation and reset. A job's finish covers its own preparation and resource release.
/// No capture barrier begins while a job finishes, so cancellation and reset still observe that cleanup.
@MainActor
final class DictationFinalization {
    private var captureID: UUID?
    private var finishingJobs: Set<UUID> = []
    private var waiters: [CheckedContinuation<Void, Never>] = []

    var isRunning: Bool { captureID != nil || !finishingJobs.isEmpty }

    func beginCapture() -> UUID? {
        guard !isRunning else { return nil }
        let id = UUID()
        captureID = id
        return id
    }

    func finishCapture(_ id: UUID) {
        guard captureID == id else { return }
        captureID = nil
        resumeWaiters()
    }

    func beginFinish(of jobID: UUID) -> Bool {
        guard captureID == nil, !finishingJobs.contains(jobID) else { return false }
        finishingJobs.insert(jobID)
        return true
    }

    func endFinish(of jobID: UUID) {
        guard finishingJobs.remove(jobID) != nil else { return }
        resumeWaiters()
    }

    func waitUntilFinished() async {
        while isRunning {
            await withCheckedContinuation { waiters.append($0) }
        }
    }

    func waitForCapture() async {
        while captureID != nil {
            await withCheckedContinuation { waiters.append($0) }
        }
    }

    private func resumeWaiters() {
        let pendingWaiters = waiters
        waiters.removeAll()
        for waiter in pendingWaiters {
            waiter.resume()
        }
    }
}
