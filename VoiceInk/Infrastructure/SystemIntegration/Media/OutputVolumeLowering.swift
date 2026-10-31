import CoreAudio
import Foundation

/// The volume scalars of one output, lowered and restored together.
protocol OutputVolumeControl: AnyObject {
    func read() -> [Float32]?
    func write(_ values: [Float32]) -> Bool
}

protocol OutputVolumeSystem {
    func defaultOutputDevice() -> AudioDeviceID?
    func volumeControl(for deviceID: AudioDeviceID) -> (any OutputVolumeControl)?
}

/// Moves an output between its original volumes and a fraction of them, preserving channel balance.
final class OutputVolumeRamp {
    static let duration: TimeInterval = 1
    /// Bluetooth outputs may acknowledge channel writes late.
    static let settleLimit: TimeInterval = 1.5
    private static let tolerance: Float32 = 0.002

    let original: [Float32]
    private let control: any OutputVolumeControl
    private var accepted: [Float32]
    private var from: [Float32]
    private var target: [Float32]
    private var isRestoring = false
    private(set) var isSettled = false
    private(set) var isFinished = false

    init?(control: any OutputVolumeControl) {
        guard let original = control.read(), !original.isEmpty else { return nil }
        self.control = control
        self.original = original
        accepted = original
        from = original
        target = original
    }

    /// Ramps toward `factor` of the original volumes, or back to them when `factor` is nil.
    func retarget(factor: Float32?) {
        guard !isFinished else { return }
        let current = control.read()
        if let current, current.count != original.count {
            isFinished = true
            return
        }
        if isSettled, current.map({ !Self.matches($0, accepted) }) ?? true {
            // A change after settling is the user's; leave it alone.
            isFinished = true
            return
        }
        from = current ?? accepted
        target = original.map { $0 * (factor ?? 1) }
        isRestoring = factor == nil
        isSettled = false
    }

    func advance(toElapsed elapsed: TimeInterval) {
        guard !isFinished, !isSettled else { return }
        let progress = Float32(min(max(elapsed / Self.duration, 0), 1))
        let eased = progress * progress * (3 - 2 * progress)
        let values = zip(from, target).map { start, end in start + (end - start) * eased }
        guard control.write(values), let actual = control.read(), actual.count == original.count else {
            rollBack()
            return
        }
        accepted = actual
        if progress >= 1, Self.matches(actual, target) || elapsed >= Self.settleLimit {
            isSettled = true
            isFinished = isRestoring
        }
    }

    /// Writes the original volumes at once, unless the user changed them after settling.
    func restoreImmediately() {
        guard !isFinished else { return }
        isFinished = true
        if isSettled, control.read().map({ !Self.matches($0, accepted) }) ?? true { return }
        _ = control.write(original)
    }

    private func rollBack() {
        _ = control.write(original)
        isFinished = true
    }

    private static func matches(_ lhs: [Float32], _ rhs: [Float32]) -> Bool {
        lhs.count == rhs.count && zip(lhs, rhs).allSatisfy { abs($0 - $1) < tolerance }
    }
}

/// Owns lowered outputs across recordings until each one is restored.
@MainActor
final class OutputVolumeLowering {
    static let tickInterval: TimeInterval = 0.016

    private final class Run {
        let ramp: OutputVolumeRamp
        var task: Task<Void, Never>?

        init(ramp: OutputVolumeRamp) { self.ramp = ramp }
    }

    private let system: any OutputVolumeSystem
    private let now: () -> TimeInterval
    private let sleep: (TimeInterval) async throws -> Void
    private var runs: [AudioDeviceID: Run] = [:]

    init(
        system: any OutputVolumeSystem = CoreAudioOutputVolumeSystem(),
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        sleep: @escaping (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }
    ) {
        self.system = system
        self.now = now
        self.sleep = sleep
    }

    var ownsOutput: Bool { !runs.isEmpty }

    /// Lowers the current default output. An output still owned keeps its original volumes.
    @discardableResult
    func lower(to level: Double) -> Bool {
        guard level.isFinite, let deviceID = system.defaultOutputDevice() else { return false }
        let factor = Float32(min(max(level, 0), 1))
        if let run = runs[deviceID] {
            run.ramp.retarget(factor: factor)
            if !run.ramp.isFinished {
                start(run, deviceID: deviceID)
                return true
            }
            discard(deviceID)
        }
        guard let control = system.volumeControl(for: deviceID),
            let ramp = OutputVolumeRamp(control: control)
        else { return false }
        let run = Run(ramp: ramp)
        runs[deviceID] = run
        ramp.retarget(factor: factor)
        start(run, deviceID: deviceID)
        return true
    }

    /// Ramps every owned output back and returns when they finish or a newer lowering supersedes them.
    func restore() async {
        for (deviceID, run) in runs {
            run.ramp.retarget(factor: nil)
            if run.ramp.isFinished {
                discard(deviceID)
            } else {
                start(run, deviceID: deviceID)
            }
        }
        await settle()
    }

    /// Waits for the ramps currently in progress.
    func settle() async {
        for task in runs.values.compactMap(\.task) {
            await task.value
        }
    }

    func restoreImmediately() {
        for deviceID in Array(runs.keys) {
            runs[deviceID]?.ramp.restoreImmediately()
            discard(deviceID)
        }
    }

    private func start(_ run: Run, deviceID: AudioDeviceID) {
        run.task?.cancel()
        let startedAt = now()
        run.task = Task { [weak self, now, sleep] in
            while !Task.isCancelled {
                run.ramp.advance(toElapsed: now() - startedAt)
                if run.ramp.isFinished {
                    if self?.runs[deviceID] === run { self?.runs[deviceID] = nil }
                    return
                }
                if run.ramp.isSettled { return }
                do { try await sleep(Self.tickInterval) } catch { return }
            }
        }
    }

    private func discard(_ deviceID: AudioDeviceID) {
        runs[deviceID]?.task?.cancel()
        runs[deviceID] = nil
    }
}
