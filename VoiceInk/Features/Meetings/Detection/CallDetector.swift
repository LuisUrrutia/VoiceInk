import Foundation

/// When a call app's microphone use is a call, and when it ended, with Hex's timing (`meeting_detection.rs`).
/// Pure: feed it the providers using the microphone at each observation.
struct CallDetector {
    enum Event: Equatable {
        case started(MeetingProvider)
        case ended(MeetingProvider)
    }

    /// A provider on the microphone this long is a call.
    static let stableFor: TimeInterval = 2
    /// A started call is over after this long off the microphone.
    static let endedAfter: TimeInterval = 3
    /// A declined or ignored offer is not repeated until the provider leaves the microphone this long.
    static let absentForReset: TimeInterval = 60
    /// Longer gaps between observations, such as sleep, restart every run.
    static let maximumObservationGap: TimeInterval = 10

    private struct Run {
        var since: TimeInterval
        var lastSeen: TimeInterval
        var started = false
    }

    private var runs: [MeetingProvider: Run] = [:]
    /// Snoozed providers and when they were first seen off the microphone since.
    private var snoozed: [MeetingProvider: TimeInterval?] = [:]
    private var lastObservation: TimeInterval?

    /// Events for this observation, at most one per provider.
    mutating func observe(_ providers: Set<MeetingProvider>, at now: TimeInterval) -> [Event] {
        if let last = lastObservation, now - last > Self.maximumObservationGap {
            runs = runs.filter { $0.value.started }.mapValues { Run(since: now, lastSeen: $0.lastSeen, started: true) }
        }
        lastObservation = now
        var events: [Event] = []
        for provider in snoozed.keys {
            if providers.contains(provider) {
                snoozed[provider] = .some(nil)
            } else if let absentSince = snoozed[provider] ?? nil {
                if now - absentSince >= Self.absentForReset { snoozed[provider] = nil }
            } else {
                snoozed[provider] = .some(now)
            }
        }
        for provider in providers {
            var run = runs[provider] ?? Run(since: now, lastSeen: now)
            run.lastSeen = now
            if !run.started, now - run.since >= Self.stableFor {
                run.started = true
                events.append(.started(provider))
            }
            runs[provider] = run
        }
        for (provider, run) in runs where !providers.contains(provider) {
            guard now - run.lastSeen >= (run.started ? Self.endedAfter : 0) else { continue }
            runs[provider] = nil
            if run.started { events.append(.ended(provider)) }
        }
        return events.sorted { $0.sortKey < $1.sortKey }
    }

    /// Whether an offer for this started call may be shown; false while the user's earlier answer stands.
    func isSnoozed(_ provider: MeetingProvider) -> Bool {
        snoozed[provider] != nil
    }

    /// Suppresses offers for `provider` until it has been off the microphone for `absentForReset`.
    mutating func snooze(_ provider: MeetingProvider) {
        snoozed[provider] = .some(nil)
    }
}

private extension CallDetector.Event {
    var sortKey: String {
        switch self {
        case .started(let provider): "1\(provider.rawValue)"
        case .ended(let provider): "0\(provider.rawValue)"
        }
    }
}
