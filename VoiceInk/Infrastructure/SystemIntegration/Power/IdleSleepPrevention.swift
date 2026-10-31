import Foundation
import IOKit.pwr_mgt
import os

protocol PowerAssertionClient: Sendable {
    func createIdleSleepAssertion(named name: String) -> Result<IOPMAssertionID, IdleSleepPreventionError>
    func releaseAssertion(_ id: IOPMAssertionID) -> IOReturn
}

struct IdleSleepPreventionError: Error, Equatable {
    let status: IOReturn
}

struct IOKitPowerAssertionClient: PowerAssertionClient {
    func createIdleSleepAssertion(named name: String) -> Result<IOPMAssertionID, IdleSleepPreventionError> {
        var id: IOPMAssertionID = 0
        let status = IOPMAssertionCreateWithName(
            kIOPMAssertPreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            name as CFString,
            &id
        )
        return status == kIOReturnSuccess ? .success(id) : .failure(IdleSleepPreventionError(status: status))
    }

    func releaseAssertion(_ id: IOPMAssertionID) -> IOReturn {
        IOPMAssertionRelease(id)
    }
}

/// Holds IOKit no-idle-sleep assertions for dictation sessions. Assertion calls wait on
/// powerd, so they run on a serial queue that also orders each release after its creation.
final class IdleSleepPrevention: @unchecked Sendable {
    static let shared = IdleSleepPrevention()
    static let dictationAssertionName = "VoiceInk dictation"

    private let client: PowerAssertionClient
    private let queue: DispatchQueue
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "IdleSleepPrevention")
    // Confined to `queue`.
    private var assertions: [UUID: IOPMAssertionID] = [:]
    private var isTerminated = false

    init(
        client: PowerAssertionClient = IOKitPowerAssertionClient(),
        queue: DispatchQueue = DispatchQueue(label: "com.prakashjoshipax.voiceink.idleSleepPrevention", qos: .userInitiated)
    ) {
        self.client = client
        self.queue = queue
    }

    func begin(name: String = dictationAssertionName) -> Hold {
        let hold = Hold(owner: self)
        let holdID = hold.id
        queue.async { self.acquire(holdID, name: name) }
        return hold
    }

    /// Releases every outstanding assertion and refuses later ones; called on app termination.
    func releaseAll() {
        queue.sync {
            isTerminated = true
            for id in assertions.keys { release(id) }
        }
    }

    private func acquire(_ holdID: UUID, name: String) {
        guard !isTerminated else { return }
        switch client.createIdleSleepAssertion(named: name) {
        case .success(let assertionID):
            assertions[holdID] = assertionID
        case .failure(let error):
            logger.warning("Could not prevent idle sleep during dictation: IOReturn \(error.status, privacy: .public)")
        }
    }

    private func release(_ holdID: UUID) {
        guard let assertionID = assertions.removeValue(forKey: holdID) else { return }
        let status = client.releaseAssertion(assertionID)
        if status != kIOReturnSuccess {
            logger.warning("Could not release idle-sleep assertion: IOReturn \(status, privacy: .public)")
        }
    }

    fileprivate func enqueueRelease(_ holdID: UUID) {
        queue.async { self.release(holdID) }
    }

    /// One session's assertion. Releasing is idempotent, and an unreleased hold releases on deinit.
    final class Hold: Sendable {
        fileprivate let id = UUID()
        private let owner: IdleSleepPrevention
        private let isReleased = OSAllocatedUnfairLock(initialState: false)

        fileprivate init(owner: IdleSleepPrevention) {
            self.owner = owner
        }

        func release() {
            let shouldRelease = isReleased.withLock { isReleased in
                defer { isReleased = true }
                return !isReleased
            }
            if shouldRelease { owner.enqueueRelease(id) }
        }

        deinit { release() }
    }
}
