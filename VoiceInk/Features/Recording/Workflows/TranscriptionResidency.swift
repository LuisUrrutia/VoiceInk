import Foundation

/// Defers the global release of shared transcription resources (the Whisper context, `serviceRegistry.cleanup()`
/// with its VAD cache cleanup, transcribe.cpp, enhancement captured contexts and the VoiceInk Refine model)
/// until no dictation owns them.
///
/// Each dictation acquires ownership at capture start; the global release runs only when the last owner releases.
/// Per-recording VAD leases stay with each preparation; the VAD cache keeps its manager while any lease remains.
/// Idle unloading is separate: the residency holds no idle-unload lease, so it never keeps models alive against it.
@MainActor
final class TranscriptionResidency {
    private let releaseResources: @MainActor () async -> Void
    private var owners: Set<UUID> = []
    private var isReleasing = false
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    init(releaseResources: @escaping @MainActor () async -> Void) {
        self.releaseResources = releaseResources
    }

    var isOwned: Bool { !owners.isEmpty }
    var ownerCount: Int { owners.count }

    func acquire(_ owner: UUID) {
        owners.insert(owner)
    }

    /// Drops an owner whose resources a newer dictation takes over, without releasing them.
    func relinquish(_ owner: UUID) {
        owners.remove(owner)
    }

    /// Releases the shared resources once no owner remains, including when none was ever acquired.
    func release(_ releasing: [UUID]) async {
        owners.subtract(releasing)
        await waitForPendingRelease()
        guard owners.isEmpty else { return }
        isReleasing = true
        await releaseResources()
        isReleasing = false
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    /// New owners wait here before loading, so a release in progress cannot free what they load.
    func waitForPendingRelease() async {
        while isReleasing {
            await withCheckedContinuation { releaseWaiters.append($0) }
        }
    }
}
