import Darwin
import Foundation
import OSLog

/// Owner-only Unix domain socket serving one newline-terminated request per connection.
/// Never logs request or response content.
final class HistoryAccessServer: @unchecked Sendable {
    enum StartError: Error, Equatable {
        case pathTooLong
        case unsafeDirectory
        case notASocket
        case inUse
        case system(operation: String, code: Int32)
    }

    enum SocketProbe: Equatable {
        case live
        case dead
        /// The probe itself failed, so the socket's state is unknown and it must be kept.
        case indeterminate(Int32)
    }

    static let maximumConnections = 4
    static let ioTimeoutSeconds = 5

    let socketURL: URL
    private let handler: @Sendable (Data) async -> Data
    private let probe: (String) -> SocketProbe
    private let requestDeadline: TimeInterval
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "HistoryAccess")
    private let lock = NSLock()
    private var listener: DispatchSourceRead?
    private var boundFile: (dev_t, ino_t)?
    private var isServing = false
    private var clients: Set<Int32> = []
    private let acceptQueue = DispatchQueue(label: "com.prakashjoshipax.voiceink.history-access.accept")
    private let connectionQueue = DispatchQueue(
        label: "com.prakashjoshipax.voiceink.history-access.connection", attributes: .concurrent)

    init(
        socketURL: URL,
        requestDeadline: TimeInterval = TimeInterval(ioTimeoutSeconds),
        probe: @escaping (String) -> SocketProbe = HistoryAccessServer.probeSocket,
        handler: @escaping @Sendable (Data) async -> Data
    ) {
        self.socketURL = socketURL
        self.requestDeadline = requestDeadline
        self.probe = probe
        self.handler = handler
    }

    deinit { stop() }

    func start() throws {
        let path = socketURL.path
        guard path.utf8.count < MemoryLayout.size(ofValue: sockaddr_un().sun_path) else {
            throw StartError.pathTooLong
        }
        try Self.verifyPrivateDirectory(socketURL.deletingLastPathComponent().path)
        try removeStaleSocket(path)

        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw Self.systemError("socket") }
        var ownsDescriptor = true
        defer { if ownsDescriptor { close(descriptor) } }
        _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)

        var address = Self.address(path)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else { throw Self.systemError("bind") }
        var info = stat()
        guard chmod(path, 0o600) == 0, lstat(path, &info) == 0, listen(descriptor, 16) == 0,
            fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK) == 0
        else {
            let error = Self.systemError("listen")
            unlink(path)
            throw error
        }

        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: acceptQueue)
        source.setEventHandler { [weak self] in self?.acceptPending(on: descriptor) }
        source.setCancelHandler { close(descriptor) }
        lock.withLock {
            listener = source
            boundFile = (info.st_dev, info.st_ino)
            isServing = true
        }
        ownsDescriptor = false
        source.resume()
    }

    /// Revokes access at once: accepted connections are shut down and pending results are discarded.
    func stop() {
        let (source, file) = lock.withLock {
            defer {
                listener = nil
                boundFile = nil
                isServing = false
            }
            // Descriptors stay registered until `finish` closes them, so none can be reused here.
            for client in clients { shutdown(client, SHUT_RDWR) }
            return (listener, boundFile)
        }
        source?.cancel()
        // Remove only the socket this server bound, never a newer instance's.
        if let file, Self.identity(of: socketURL.path).map({ $0 == file }) == true {
            unlink(socketURL.path)
        }
    }

    private func acceptPending(on listenDescriptor: Int32) {
        while true {
            let client = accept(listenDescriptor, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                return
            }
            Self.configureClient(client)

            var peerUID: uid_t = 0
            var peerGID: gid_t = 0
            guard getpeereid(client, &peerUID, &peerGID) == 0, peerUID == getuid() else {
                logger.warning("Rejected a History access connection from another user")
                close(client)
                continue
            }
            let admitted = lock.withLock {
                guard isServing, clients.count < Self.maximumConnections else { return false }
                clients.insert(client)
                return true
            }
            guard admitted else {
                Self.write(
                    HistoryAccessService.encode(.failure(HistoryAccessFailure(.busy, "Too many concurrent requests."))),
                    to: client)
                close(client)
                continue
            }
            connectionQueue.async { [self] in serve(client) }
        }
    }

    private func serve(_ client: Int32) {
        switch Self.readRequest(from: client, deadline: .now + .seconds(requestDeadline)) {
        case .request(let data):
            guard lock.withLock({ isServing }) else { return finish(client, response: nil) }
            let handler = handler
            Task.detached { [self] in
                let output = await handler(data)
                connectionQueue.async { [self] in finish(client, response: output) }
            }
        case .tooLarge:
            finish(client, response: HistoryAccessService.encode(.failure(HistoryAccessFailure(
                .invalidRequest, "The request exceeds \(HistoryAccess.maximumRequestBytes) bytes."))))
        case .failed:
            logger.debug("A History access client disconnected or timed out before sending a request")
            finish(client, response: nil)
        }
    }

    private func finish(_ client: Int32, response: Data?) {
        // A stop after this check shuts the still-registered descriptor down, failing the write.
        if let response, lock.withLock({ isServing }) { Self.write(response, to: client) }
        lock.withLock { _ = clients.remove(client) }
        close(client)
    }

    // MARK: - Socket helpers

    private enum ReadResult {
        case request(Data)
        case tooLarge
        case failed
    }

    /// The whole request must arrive before `deadline`, so slow writers cannot hold a connection slot.
    private static func readRequest(from client: Int32, deadline: ContinuousClock.Instant) -> ReadResult {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            // A monotonic clock keeps wall-clock adjustments from stretching or cutting the allowance.
            let remaining = (deadline - .now).components
            guard remaining.seconds > 0 || remaining.attoseconds > 0 else { return .failed }
            var timeout = timeval(
                tv_sec: Int(remaining.seconds), tv_usec: max(1, Int32(remaining.attoseconds / 1_000_000_000_000)))
            setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            let count = recv(client, &buffer, buffer.count, 0)
            if count < 0 {
                if errno == EINTR { continue }
                return .failed
            }
            if count == 0 { return data.isEmpty ? .failed : .request(data) }
            if let newline = buffer[..<count].firstIndex(of: UInt8(ascii: "\n")) {
                data.append(contentsOf: buffer[..<newline])
                return data.count > HistoryAccess.maximumRequestBytes ? .tooLarge : .request(data)
            }
            data.append(contentsOf: buffer[..<count])
            if data.count > HistoryAccess.maximumRequestBytes { return .tooLarge }
        }
    }

    private static func write(_ response: Data, to client: Int32) {
        var payload = response
        payload.append(UInt8(ascii: "\n"))
        payload.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let written = send(client, base + offset, raw.count - offset, 0)
                if written < 0 {
                    if errno == EINTR { continue }
                    return
                }
                offset += written
            }
        }
    }

    private static func configureClient(_ client: Int32) {
        _ = fcntl(client, F_SETFD, FD_CLOEXEC)
        // Accepted sockets inherit the listener's O_NONBLOCK on Darwin; requests use bounded blocking I/O.
        _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) & ~O_NONBLOCK)
        var enabled: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: ioTimeoutSeconds, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    }

    /// Other users must not reach the socket between `bind` and `chmod`, so its directory must already be private.
    private static func verifyPrivateDirectory(_ path: String) throws {
        var info = stat()
        guard lstat(path, &info) == 0 else { throw systemError("lstat") }
        guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid(), info.st_mode & 0o077 == 0 else {
            throw StartError.unsafeDirectory
        }
    }

    private func removeStaleSocket(_ path: String) throws {
        var info = stat()
        guard lstat(path, &info) == 0 else { return }
        guard info.st_mode & S_IFMT == S_IFSOCK else { throw StartError.notASocket }
        switch probe(path) {
        case .live:
            throw StartError.inUse
        case .indeterminate(let code):
            throw StartError.system(operation: "probe", code: code)
        case .dead:
            // Unlink only the socket that was probed, not one a concurrent instance bound since.
            guard Self.identity(of: path).map({ $0 == (info.st_dev, info.st_ino) }) == true else {
                throw StartError.inUse
            }
            unlink(path)
        }
    }

    /// A nonblocking connect never waits on a full backlog; only a refused connection proves the socket is dead.
    static func probeSocket(_ path: String) -> SocketProbe {
        let probe = socket(AF_UNIX, SOCK_STREAM, 0)
        guard probe >= 0 else { return .indeterminate(errno) }
        defer { close(probe) }
        guard fcntl(probe, F_SETFL, fcntl(probe, F_GETFL) | O_NONBLOCK) == 0 else { return .indeterminate(errno) }
        var address = address(path)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(probe, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if result == 0 { return .live }
        switch errno {
        case EINPROGRESS, EAGAIN, EISCONN: return .live
        case ECONNREFUSED: return .dead
        case let code: return .indeterminate(code)
        }
    }

    private static func identity(of path: String) -> (dev_t, ino_t)? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        return (info.st_dev, info.st_ino)
    }

    private static func address(_ path: String) -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            let bytes = Array(path.utf8.prefix(raw.count - 1))
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        return address
    }

    private static func systemError(_ operation: String) -> StartError {
        .system(operation: operation, code: errno)
    }
}
