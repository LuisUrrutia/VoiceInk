import Darwin
import Foundation
import os

struct CustomCommandDeliveryContext {
    let transcript: String
    var includesTranscriptEnvironment = true

    var standardInput: String {
        transcript
    }

    var environment: [String: String] {
        guard includesTranscriptEnvironment else { return [:] }
        return [
            "VOICEINK_TRANSCRIPT": transcript
        ]
    }
}

struct CustomCommandDeliveryResult {
    let status: Int32
    let stdout: String
    let stderr: String
}

enum CustomCommandDeliveryError: Error, LocalizedError {
    case commandNotConfigured
    case noTextToDeliver
    case launchFailed(String)
    case timeout(seconds: Double)
    case nonZeroExit(status: Int32, stderr: String)

    var errorDescription: String? {
        switch self {
        case .commandNotConfigured:
            return String(localized: "Custom command is empty.")
        case .noTextToDeliver:
            return String(localized: "No transcription text was available for the custom command.")
        case .launchFailed(let message):
            return String(format: String(localized: "Custom command could not start: %@"), message)
        case .timeout(let seconds):
            return String(format: String(localized: "Custom command timed out after %.0f seconds."), seconds)
        case .nonZeroExit(let status, let stderr):
            let details = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if details.isEmpty {
                return String(format: String(localized: "Custom command exited with status %d."), status)
            }
            return String(
                format: String(localized: "Custom command exited with status %d: %@"), status,
                String(details.prefix(300)))
        }
    }
}

enum CustomCommandDeliveryRunner {
    private static let logger = Logger(
        subsystem: "com.prakashjoshipax.voiceink", category: "CustomCommandDeliveryRunner")

    static func run(
        command: String,
        timeout: TimeInterval,
        context: CustomCommandDeliveryContext
    ) async throws -> CustomCommandDeliveryResult {
        let trimmedCommand = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCommand.isEmpty else {
            throw CustomCommandDeliveryError.commandNotConfigured
        }

        let cancellation = CommandCancellation()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    execute(
                        command: trimmedCommand,
                        timeout: timeout,
                        context: context,
                        cancellation: cancellation,
                        continuation: continuation
                    )
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    private static func execute(
        command: String,
        timeout: TimeInterval,
        context: CustomCommandDeliveryContext,
        cancellation: CommandCancellation,
        continuation: CheckedContinuation<CustomCommandDeliveryResult, Error>
    ) {
        guard !cancellation.isCancelled else {
            continuation.resume(throwing: CancellationError())
            return
        }
        let environment = ShellCommandEnvironment.commandEnvironment(
            additionalEnvironment: context.environment
        )
        guard !cancellation.isCancelled else {
            continuation.resume(throwing: CancellationError())
            return
        }

        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        // A command that exits without reading stdin must fail the write, not raise SIGPIPE in the app.
        _ = fcntl(inputPipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)

        let outputCollector = PipeOutputCollector(handle: outputPipe.fileHandleForReading)
        let errorCollector = PipeOutputCollector(handle: errorPipe.fileHandleForReading)
        let outputCollectors = [outputCollector, errorCollector]
        let inputWriteGroup = DispatchGroup()

        let leader: ProcessGroupLeader
        do {
            var actions: posix_spawn_file_actions_t?
            try ProcessGroupLeader.check(posix_spawn_file_actions_init(&actions))
            defer { posix_spawn_file_actions_destroy(&actions) }
            try ProcessGroupLeader.check(posix_spawn_file_actions_adddup2(
                &actions, inputPipe.fileHandleForReading.fileDescriptor, STDIN_FILENO))
            try ProcessGroupLeader.check(posix_spawn_file_actions_adddup2(
                &actions, outputPipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO))
            try ProcessGroupLeader.check(posix_spawn_file_actions_adddup2(
                &actions, errorPipe.fileHandleForWriting.fileDescriptor, STDERR_FILENO))
            leader = try ProcessGroupLeader.spawn(
                executable: "/bin/zsh", arguments: ["/bin/zsh", "-lc", command], environment: environment,
                fileActions: &actions
            )
        } catch {
            try? inputPipe.fileHandleForWriting.close()
            outputCollectors.forEach { $0.stop() }
            let message = (error as? ProcessGroupLeader.SystemError)?.message ?? error.localizedDescription
            continuation.resume(throwing: CustomCommandDeliveryError.launchFailed(message))
            return
        }
        // The child holds its own copies; the parent's would keep the output pipes from reaching EOF.
        try? inputPipe.fileHandleForReading.close()
        try? outputPipe.fileHandleForWriting.close()
        try? errorPipe.fileHandleForWriting.close()

        let timeoutDeadline = DispatchTime.now() + timeout
        startWritingStandardInput(context.standardInput, to: inputPipe.fileHandleForWriting, group: inputWriteGroup)

        var exit: siginfo_t?
        while !cancellation.isCancelled && DispatchTime.now() < timeoutDeadline {
            exit = (try? leader.exitInformation()) ?? nil
            if exit != nil { break }
            usleep(10_000)
        }
        guard let exit else {
            terminate(leader)
            try? inputPipe.fileHandleForWriting.close()
            _ = waitForCollectors(outputCollectors, timeout: 1)
            outputCollectors.forEach { $0.stop() }
            _ = waitForGroup(inputWriteGroup, timeout: 1)
            continuation.resume(throwing: cancellation.isCancelled
                ? CancellationError() : CustomCommandDeliveryError.timeout(seconds: timeout))
            return
        }
        leader.reap()
        // Process reported only the low byte of an exit value, which waitid keeps whole.
        let status = exit.si_code == CLD_EXITED ? exit.si_status & 0xff : exit.si_status

        _ = waitForCollectors(outputCollectors, timeout: 2)
        outputCollectors.forEach { $0.stop() }
        _ = waitForGroup(inputWriteGroup, timeout: 1)

        let stdout = outputCollector.stringValue()
        let stderr = errorCollector.stringValue()

        guard !cancellation.isCancelled else {
            continuation.resume(throwing: CancellationError())
            return
        }

        guard status == 0 else {
            continuation.resume(
                throwing: CustomCommandDeliveryError.nonZeroExit(
                    status: status,
                    stderr: stderr
                )
            )
            return
        }

        continuation.resume(
            returning: CustomCommandDeliveryResult(
                status: status,
                stdout: stdout,
                stderr: stderr
            )
        )
    }

    private static func startWritingStandardInput(_ input: String, to handle: FileHandle, group: DispatchGroup) {
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            defer {
                try? handle.close()
                group.leave()
            }

            guard let inputData = input.data(using: .utf8),
                !inputData.isEmpty
            else {
                return
            }

            do {
                try handle.write(contentsOf: inputData)
            } catch {
                // The command may exit before reading stdin; its exit status is handled separately.
            }
        }
    }

    private static func terminate(_ leader: ProcessGroupLeader) {
        leader.signalGroup(SIGTERM)
        let grace = DispatchTime.now() + 2
        while ((try? leader.exitInformation()) ?? nil) == nil, DispatchTime.now() < grace {
            usleep(10_000)
        }
        // Children can ignore TERM or outlive the shell; the unreaped leader keeps the group ID reserved.
        leader.signalGroup(SIGKILL)
        if !leader.waitForOtherMembersToExit(timeout: 1) {
            logger.error("Custom command process group \(leader.pid, privacy: .public) did not exit after SIGKILL")
        }
        leader.reap()
    }

    private static func waitForGroup(_ group: DispatchGroup, timeout: TimeInterval) -> Bool {
        group.wait(timeout: .now() + timeout) == .success
    }

    private static func waitForCollectors(_ collectors: [PipeOutputCollector], timeout: TimeInterval) -> Bool {
        let deadline = DispatchTime.now() + timeout
        return collectors.allSatisfy { $0.wait(until: deadline) }
    }
}

private final class CommandCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

private final class PipeOutputCollector {
    private let handle: FileHandle
    private let buffer = LockedDataBuffer()
    private let drainTracker = PipeDrainTracker()
    private let stopLock = NSLock()
    private var stopped = false

    init(handle: FileHandle) {
        self.handle = handle
        handle.readabilityHandler = { [weak self] handle in
            self?.readAvailableData(from: handle)
        }
    }

    func stop() {
        stopLock.lock()
        guard !stopped else {
            stopLock.unlock()
            return
        }
        stopped = true
        stopLock.unlock()

        handle.readabilityHandler = nil
        drainTracker.finish()
    }

    func wait(until deadline: DispatchTime) -> Bool {
        drainTracker.wait(until: deadline)
    }

    func stringValue() -> String {
        buffer.stringValue()
    }

    private func readAvailableData(from handle: FileHandle) {
        let data = handle.availableData
        if data.isEmpty {
            drainTracker.finish()
        } else {
            buffer.append(data)
        }
    }
}

private final class PipeDrainTracker {
    private let lock = NSLock()
    private let group = DispatchGroup()
    private var didFinish = false

    init() {
        group.enter()
    }

    func finish() {
        lock.lock()
        defer { lock.unlock() }

        guard !didFinish else { return }
        didFinish = true
        group.leave()
    }

    func wait(until deadline: DispatchTime) -> Bool {
        group.wait(timeout: deadline) == .success
    }
}

private final class LockedDataBuffer {
    private let lock = NSLock()
    private var data = Data()

    func append(_ newData: Data) {
        guard !newData.isEmpty else { return }
        lock.lock()
        data.append(newData)
        lock.unlock()
    }

    func stringValue() -> String {
        lock.lock()
        let value = data
        lock.unlock()
        return String(data: value, encoding: .utf8) ?? ""
    }
}
