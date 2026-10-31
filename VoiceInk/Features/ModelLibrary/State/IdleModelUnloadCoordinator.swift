import Foundation
import os

enum IdleModelUnloadSettings {
    static let isEnabledKey = "UnloadModelWhenIdle"
    static let minutesKey = "UnloadModelIdleMinutes"
    static let minuteChoices = [5, 15, 30, 60]
    static let defaultMinutes = 15

    static func isEnabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: isEnabledKey)
    }

    static func minutes(in defaults: UserDefaults = .standard) -> Int {
        let stored = defaults.integer(forKey: minutesKey)
        return minuteChoices.contains(stored) ? stored : defaultMinutes
    }
}

protocol IdleModelUnloadTimer: AnyObject {
    func cancel()
}

/// Frees resident local speech models after a configured time without use.
///
/// Leases mark model work; the busy predicate covers capture that holds no lease, such as the microphone test.
@MainActor
final class IdleModelUnloadCoordinator {
    enum Activity {
        /// User work: dictation, audio import, History retranscription. Ending it restarts the idle time.
        case use
        /// Prewarm: blocks an unload while it runs but does not count as use.
        case maintenance
    }

    typealias Scheduler = @MainActor (Duration, @escaping @MainActor () -> Void) -> any IdleModelUnloadTimer

    @MainActor
    final class Lease {
        private weak var owner: IdleModelUnloadCoordinator?
        private let activity: Activity
        private var isReleased = false

        fileprivate init(owner: IdleModelUnloadCoordinator, activity: Activity) {
            self.owner = owner
            self.activity = activity
        }

        func release() {
            guard !isReleased else { return }
            isReleased = true
            owner?.end(activity)
        }

        deinit {
            guard !isReleased else { return }
            let owner = owner
            let activity = activity
            Task { @MainActor in owner?.end(activity) }
        }
    }

    static let shared = IdleModelUnloadCoordinator()

    /// While a model stays busy, recheck at most this often instead of waiting a full idle period.
    static let busyRecheckInterval: Duration = .seconds(30)

    private let defaults: UserDefaults
    private let now: () -> ContinuousClock.Instant
    private let schedule: Scheduler
    private var isBusy: @MainActor () -> Bool = { false }
    private var unloadModels: @MainActor () async -> Void = {}
    private var settingsObserver: NSObjectProtocol?
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "IdleModelUnload")

    private(set) var isEnabled: Bool
    private(set) var idleInterval: Duration
    private var activeCounts: [Activity: Int] = [:]
    private var lastUse: ContinuousClock.Instant
    private var timer: (any IdleModelUnloadTimer)?
    private var unloadTask: Task<Void, Never>?
    /// True from an idle unload until the next use, which reloads the model on demand.
    private(set) var hasUnloadedModels = false

    init(
        defaults: UserDefaults = .standard,
        now: @escaping () -> ContinuousClock.Instant = { ContinuousClock.now },
        schedule: @escaping Scheduler = IdleModelUnloadCoordinator.sleepScheduler
    ) {
        self.defaults = defaults
        self.now = now
        self.schedule = schedule
        isEnabled = IdleModelUnloadSettings.isEnabled(in: defaults)
        idleInterval = .seconds(IdleModelUnloadSettings.minutes(in: defaults) * 60)
        lastUse = now()
        settingsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: defaults, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reloadSettings() }
        }
    }

    deinit {
        settingsObserver.map(NotificationCenter.default.removeObserver)
        timer?.cancel()
    }

    func configure(isBusy: @escaping @MainActor () -> Bool, unload: @escaping @MainActor () async -> Void) {
        self.isBusy = isBusy
        unloadModels = unload
        reschedule()
    }

    var activeUseCount: Int { activeCounts.values.reduce(0, +) }
    var isUnloading: Bool { unloadTask != nil }

    func begin(_ activity: Activity) -> Lease {
        activeCounts[activity, default: 0] += 1
        if activity == .use { hasUnloadedModels = false }
        cancelTimer()
        return Lease(owner: self, activity: activity)
    }

    /// Runs model work under a lease, after any unload in progress has released its models.
    func perform<Result>(
        _ activity: Activity, _ operation: () async throws -> Result
    ) async rethrows -> Result {
        let lease = begin(activity)
        defer { lease.release() }
        await waitForPendingUnload()
        return try await operation()
    }

    func waitForPendingUnload() async {
        await unloadTask?.value
    }

    /// Wake and launch prewarm must not reload a model the idle timer freed or is about to free.
    var allowsPrewarm: Bool {
        guard isEnabled else { return true }
        return !hasUnloadedModels && unloadTask == nil && now() < lastUse + idleInterval
    }

    func reloadSettings() {
        let enabled = IdleModelUnloadSettings.isEnabled(in: defaults)
        let interval = Duration.seconds(IdleModelUnloadSettings.minutes(in: defaults) * 60)
        guard enabled != isEnabled || interval != idleInterval else { return }
        isEnabled = enabled
        idleInterval = interval
        if !enabled { hasUnloadedModels = false }
        reschedule()
    }

    private func end(_ activity: Activity) {
        activeCounts[activity, default: 1] -= 1
        if activity == .use { lastUse = now() }
        reschedule()
    }

    private func cancelTimer() {
        timer?.cancel()
        timer = nil
    }

    private func reschedule() {
        cancelTimer()
        guard isEnabled, activeUseCount == 0, unloadTask == nil, !hasUnloadedModels else { return }
        let remaining = lastUse + idleInterval - now()
        timer = schedule(max(remaining, .zero)) { [weak self] in self?.timerFired() }
    }

    private func timerFired() {
        timer = nil
        guard isEnabled, activeUseCount == 0, unloadTask == nil, !hasUnloadedModels else { return }
        guard now() >= lastUse + idleInterval else { return reschedule() }
        guard !isBusy() else {
            timer = schedule(min(idleInterval, Self.busyRecheckInterval)) { [weak self] in self?.timerFired() }
            return
        }
        hasUnloadedModels = true
        let unload = unloadModels
        logger.notice("Unloading idle local speech models")
        unloadTask = Task { @MainActor [weak self] in
            await unload()
            self?.unloadTask = nil
            self?.reschedule()
        }
    }

    static func sleepScheduler(
        _ delay: Duration, _ action: @escaping @MainActor () -> Void
    ) -> any IdleModelUnloadTimer {
        // ContinuousClock keeps counting during system sleep, so an elapsed idle period fires on wake.
        SleepTimer(task: Task { @MainActor in
            do { try await Task.sleep(for: delay, clock: .continuous) } catch { return }
            action()
        })
    }

    private final class SleepTimer: IdleModelUnloadTimer {
        let task: Task<Void, Never>
        init(task: Task<Void, Never>) { self.task = task }
        func cancel() { task.cancel() }
    }
}
