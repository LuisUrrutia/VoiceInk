import Darwin
import Foundation

/// A child process launched as the leader of its own process group.
/// The leader stays unreaped until `reap()`, which keeps its PID, and so its group ID, from being reused
/// while the group is signaled.
struct ProcessGroupLeader {
    struct SystemError: Error {
        let code: Int32

        var message: String { String(cString: strerror(code)) }
    }

    let pid: pid_t

    static func spawn(
        executable: String, arguments: [String], environment: [String: String],
        fileActions: inout posix_spawn_file_actions_t?
    ) throws -> ProcessGroupLeader {
        var attributes: posix_spawnattr_t?
        try check(posix_spawnattr_init(&attributes))
        defer { posix_spawnattr_destroy(&attributes) }
        // The group is assigned atomically at launch; group signals never target the app's group.
        try check(posix_spawnattr_setpgroup(&attributes, 0))
        try check(posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)))
        let argv = arguments.map { strdup($0) }
        let envp = environment.map { strdup("\($0.key)=\($0.value)") }
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }
        var pid: pid_t = 0
        let status = (argv + [nil]).withUnsafeBufferPointer { argv in
            (envp + [nil]).withUnsafeBufferPointer { envp in
                posix_spawn(&pid, executable, &fileActions, &attributes, argv.baseAddress!, envp.baseAddress!)
            }
        }
        try check(status)
        return ProcessGroupLeader(pid: pid)
    }

    /// The leader's exit, observed without reaping it.
    func exitInformation() throws -> siginfo_t? {
        var info = siginfo_t()
        if waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT) < 0 {
            if errno == EINTR { return nil }
            throw SystemError(code: errno)
        }
        return info.si_pid == pid ? info : nil
    }

    func signalGroup(_ signal: Int32) {
        _ = kill(-pid, signal)
    }

    /// Reaps the leader, finishing in the background if it has not exited within a second.
    func reap() {
        let deadline = DispatchTime.now() + 1
        var status: Int32 = 0
        while DispatchTime.now() < deadline {
            let result = waitpid(pid, &status, WNOHANG)
            if result == pid || (result < 0 && errno == ECHILD) { return }
            usleep(10_000)
        }
        let pid = pid
        DispatchQueue.global(qos: .utility).async {
            var status: Int32 = 0
            while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
        }
    }

    static func check(_ status: Int32) throws {
        if status != 0 { throw SystemError(code: status) }
    }
}
