import Darwin
import Foundation

enum LocalCLIProcessRunner {
    struct Result {
        let status: Int32
        let stdout: Data
        let stderr: Data
    }

    static func run(
        command: String,
        standardInput: Data?,
        timeout: TimeInterval,
        executable: String = "/bin/zsh",
        environment: @escaping () -> [String: String]
    ) async throws -> Result {
        let cancellation = LocalCLICancellation()
        let deadline = DispatchTime.now() + timeout
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let result: Result = try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        try checkTermination(cancellation, deadline: deadline, timeout: timeout)
                        let resolvedEnvironment = environment()
                        try checkTermination(cancellation, deadline: deadline, timeout: timeout)
                        let result = try execute(
                            executable: executable, command: command, environment: resolvedEnvironment,
                            standardInput: standardInput, deadline: deadline, timeout: timeout,
                            cancellation: cancellation
                        )
                        continuation.resume(returning: result)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
            try Task.checkCancellation()
            return result
        } onCancel: {
            cancellation.cancel()
        }
    }

    private static func execute(
        executable: String, command: String, environment: [String: String], standardInput: Data?,
        deadline: DispatchTime, timeout: TimeInterval, cancellation: LocalCLICancellation
    ) throws -> Result {
        let input = try standardInput.map { _ in try LocalCLIPipe() }
        let output = try LocalCLIPipe()
        let error = try LocalCLIPipe()
        try input?.configureParentEnd(input: true)
        try output.configureParentEnd(input: false)
        try error.configureParentEnd(input: false)

        var actions: posix_spawn_file_actions_t?
        try checkSystemCall(posix_spawn_file_actions_init(&actions))
        defer { posix_spawn_file_actions_destroy(&actions) }
        if let input {
            try checkSystemCall(posix_spawn_file_actions_adddup2(&actions, input.readDescriptor, STDIN_FILENO))
        } else {
            try checkSystemCall(posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0))
        }
        try checkSystemCall(posix_spawn_file_actions_adddup2(&actions, output.writeDescriptor, STDOUT_FILENO))
        try checkSystemCall(posix_spawn_file_actions_adddup2(&actions, error.writeDescriptor, STDERR_FILENO))

        var attributes: posix_spawnattr_t?
        try checkSystemCall(posix_spawnattr_init(&attributes))
        defer { posix_spawnattr_destroy(&attributes) }
        // The group is assigned atomically at launch; cancellation never targets the app's group.
        try checkSystemCall(posix_spawnattr_setpgroup(&attributes, 0))
        try checkSystemCall(posix_spawnattr_setflags(
            &attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)
        ))
        let arguments = [executable, "-lc", command].map { strdup($0) }
        let variables = environment.map { strdup("\($0.key)=\($0.value)") }
        defer {
            arguments.forEach { free($0) }
            variables.forEach { free($0) }
        }
        var pid: pid_t = 0
        try checkTermination(cancellation, deadline: deadline, timeout: timeout)
        let launchStatus = (arguments + [nil]).withUnsafeBufferPointer { argv in
            (variables + [nil]).withUnsafeBufferPointer { envp in
                posix_spawn(&pid, executable, &actions, &attributes, argv.baseAddress!, envp.baseAddress!)
            }
        }
        try checkSystemCall(launchStatus)
        input?.closeReadEnd()
        output.closeWriteEnd()
        error.closeWriteEnd()
        var completed = false
        defer { shutdown(pid: pid, completed: completed) }

        var stdout = Data()
        var stderr = Data()
        var inputOffset = 0
        var exit: siginfo_t?
        while true {
            try checkTermination(cancellation, deadline: deadline, timeout: timeout)
            if exit == nil { exit = try exitInformation(pid: pid) }
            if exit != nil { input?.closeWriteEnd() }

            try output.read(into: &stdout)
            try error.read(into: &stderr)
            if let input, let standardInput {
                try input.write(standardInput, offset: &inputOffset)
            }
            if let exit, output.readDescriptor < 0, error.readDescriptor < 0 {
                try checkTermination(cancellation, deadline: deadline, timeout: timeout)
                completed = true
                return Result(status: exit.si_status, stdout: stdout, stderr: stderr)
            }

            var descriptors = [
                pollfd(fd: output.readDescriptor, events: Int16(POLLIN), revents: 0),
                pollfd(fd: error.readDescriptor, events: Int16(POLLIN), revents: 0),
                pollfd(fd: input?.writeDescriptor ?? -1, events: Int16(POLLOUT), revents: 0),
            ]
            let now = DispatchTime.now().uptimeNanoseconds
            let remaining = Double(deadline.uptimeNanoseconds > now ? deadline.uptimeNanoseconds - now : 0) / 1_000_000
            let interval = Int32(max(0, min(output.readDescriptor < 0 && error.readDescriptor < 0 ? 1 : 20, remaining)))
            if poll(&descriptors, nfds_t(descriptors.count), interval) < 0, errno != EINTR {
                throw systemError(errno)
            }
        }
    }

    private static func checkTermination(
        _ cancellation: LocalCLICancellation, deadline: DispatchTime, timeout: TimeInterval
    ) throws {
        if cancellation.isCancelled { throw CancellationError() }
        if DispatchTime.now() >= deadline { throw LocalCLIError.timeout(seconds: timeout) }
    }

    private static func exitInformation(pid: pid_t) throws -> siginfo_t? {
        var info = siginfo_t()
        // Keep the leader waitable until group shutdown, preventing its PID from being reused.
        if waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT) < 0 {
            if errno == EINTR { return nil }
            throw systemError(errno)
        }
        return info.si_pid == pid ? info : nil
    }

    private static func shutdown(pid: pid_t, completed: Bool) {
        if !completed {
            _ = kill(-pid, SIGTERM)
            let grace = DispatchTime.now() + 0.2
            while DispatchTime.now() < grace { usleep(10_000) }
        }
        // Even an exited shell may have children that closed or still hold its pipes.
        _ = kill(-pid, SIGKILL)
        let deadline = DispatchTime.now() + 1
        var status: Int32 = 0
        while DispatchTime.now() < deadline {
            let result = waitpid(pid, &status, WNOHANG)
            if result == pid || (result < 0 && errno == ECHILD) { return }
            usleep(10_000)
        }
        DispatchQueue.global(qos: .utility).async {
            var status: Int32 = 0
            while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
        }
    }

    private static func checkSystemCall(_ status: Int32) throws {
        if status != 0 { throw systemError(status) }
    }

    fileprivate static func systemError(_ status: Int32) -> LocalCLIError {
        .executionFailed(String(cString: strerror(status)))
    }
}

private final class LocalCLICancellation: @unchecked Sendable {
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

private final class LocalCLIPipe {
    private(set) var readDescriptor: Int32
    private(set) var writeDescriptor: Int32
    private var readBuffer = [UInt8](repeating: 0, count: 64 * 1024)

    init() throws {
        var descriptors: [Int32] = [0, 0]
        guard pipe(&descriptors) == 0 else { throw LocalCLIProcessRunner.systemError(errno) }
        readDescriptor = descriptors[0]
        writeDescriptor = descriptors[1]
        _ = fcntl(readDescriptor, F_SETFD, FD_CLOEXEC)
        _ = fcntl(writeDescriptor, F_SETFD, FD_CLOEXEC)
    }

    deinit {
        closeReadEnd()
        closeWriteEnd()
    }

    func configureParentEnd(input: Bool) throws {
        let descriptor = input ? writeDescriptor : readDescriptor
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0,
            !input || fcntl(descriptor, F_SETNOSIGPIPE, 1) == 0
        else { throw LocalCLIProcessRunner.systemError(errno) }
    }

    func closeReadEnd() {
        guard readDescriptor >= 0 else { return }
        close(readDescriptor)
        readDescriptor = -1
    }

    func closeWriteEnd() {
        guard writeDescriptor >= 0 else { return }
        close(writeDescriptor)
        writeDescriptor = -1
    }

    func read(into data: inout Data) throws {
        guard readDescriptor >= 0 else { return }
        let count = Darwin.read(readDescriptor, &readBuffer, readBuffer.count)
        if count > 0 {
            data.append(contentsOf: readBuffer.prefix(count))
        } else if count == 0 {
            closeReadEnd()
        } else if errno != EAGAIN && errno != EINTR {
            throw LocalCLIProcessRunner.systemError(errno)
        }
    }

    func write(_ data: Data, offset: inout Int) throws {
        guard writeDescriptor >= 0 else { return }
        if offset == data.count { closeWriteEnd(); return }
        let count = data.withUnsafeBytes { bytes in
            Darwin.write(writeDescriptor, bytes.baseAddress!.advanced(by: offset), min(64 * 1024, data.count - offset))
        }
        if count > 0 {
            offset += count
        } else if count < 0 {
            if errno == EPIPE { closeWriteEnd() }
            else if errno != EAGAIN && errno != EINTR { throw LocalCLIProcessRunner.systemError(errno) }
        }
    }
}
