import Foundation

extension ModelProvider {
    /// Runs on this Mac and shares its resident model and compute, so transcriptions serialize.
    var transcribesLocally: Bool {
        switch self {
        case .whisper, .fluidAudio, .transcribeCpp, .nativeApple: true
        default: false
        }
    }
}

/// Admits dictation transcriptions: local providers one at a time in sequence order, cloud providers
/// concurrently up to `cloudConcurrency`. A canceled waiting entry leaves without blocking later ones.
@MainActor
final class TranscriptionLane {
    nonisolated static let cloudConcurrency = 2

    private enum Kind {
        case local, cloud

        var capacity: Int { self == .local ? 1 : TranscriptionLane.cloudConcurrency }
    }

    private struct Waiter {
        let id: UUID
        let sequence: UInt64
        let continuation: CheckedContinuation<Void, Error>
    }

    private var running: [Kind: Int] = [:]
    private var waiting: [Kind: [Waiter]] = [:]

    func runningCount(local: Bool) -> Int { running[local ? .local : .cloud, default: 0] }
    func waitingCount(local: Bool) -> Int { waiting[local ? .local : .cloud, default: []].count }

    func run<Result>(
        sequence: UInt64, provider: ModelProvider, _ operation: @MainActor () async throws -> Result
    ) async throws -> Result {
        let kind: Kind = provider.transcribesLocally ? .local : .cloud
        try await admit(kind, sequence: sequence)
        defer { leave(kind) }
        return try await operation()
    }

    private func admit(_ kind: Kind, sequence: UInt64) async throws {
        try Task.checkCancellation()
        // A free slot admits without suspending, so a lone dictation runs as it did without the lane.
        if running[kind, default: 0] < kind.capacity, waiting[kind, default: []].isEmpty {
            running[kind, default: 0] += 1
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                guard !Task.isCancelled else { return continuation.resume(throwing: CancellationError()) }
                var queue = waiting[kind, default: []]
                let index = queue.firstIndex { $0.sequence > sequence } ?? queue.endIndex
                queue.insert(Waiter(id: id, sequence: sequence, continuation: continuation), at: index)
                waiting[kind] = queue
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancelWaiter(id, kind: kind) }
        }
    }

    private func cancelWaiter(_ id: UUID, kind: Kind) {
        guard let index = waiting[kind]?.firstIndex(where: { $0.id == id }),
            let waiter = waiting[kind]?.remove(at: index)
        else { return }
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func leave(_ kind: Kind) {
        running[kind, default: 1] -= 1
        while running[kind, default: 0] < kind.capacity, let next = waiting[kind]?.first {
            waiting[kind]?.removeFirst()
            running[kind, default: 0] += 1
            next.continuation.resume()
        }
    }
}
