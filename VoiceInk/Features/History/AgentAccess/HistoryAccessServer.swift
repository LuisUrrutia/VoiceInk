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

    static let maximumConnections = 4
    static let ioTimeoutSeconds = 5

    let socketURL: URL
    private let handler: @Sendable (Data) async -> Data
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "HistoryAccess")
    private let lock = NSLock()
    private var listener: DispatchSourceRead?
    private var boundFile: (device: dev_t, inode: ino_t)?
    private var activeConnections = 0
    private let acceptQueue = DispatchQueue(label: "com.prakashjoshipax.voiceink.history-access.accept")
    private let connectionQueue = DispatchQueue(
        label: "com.prakashjoshipax.voiceink.history-access.connection", attributes: .concurrent)

    init(socketURL: URL, handler: @escaping @Sendable (Data) async -> Data) {
        self.socketURL = socketURL
        self.handler = handler
    }

    deinit { stop() }

    func start() throws {
        let path = socketURL.path
        guard path.utf8.count < MemoryLayout.size(ofValue: sockaddr_un().sun_path) else {
            throw StartError.pathTooLong
        }
        try Self.verifyPrivateDirectory(socketURL.deletingLastPathComponent().path)
        try Self.removeStaleSocket(path)

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
        }
        ownsDescriptor = false
        source.resume()
    }

    func stop() {
        let (source, file) = lock.withLock {
            defer {
                listener = nil
                boundFile = nil
            }
            return (listener, boundFile)
        }
        source?.cancel()
        // Remove only the socket this server bound, never a newer instance's.
        var info = stat()
        if let file, lstat(socketURL.path, &info) == 0, info.st_dev == file.device, info.st_ino == file.inode {
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
                guard activeConnections < Self.maximumConnections else { return false }
                activeConnections += 1
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
        switch Self.readRequest(from: client) {
        case .request(let data):
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
        if let response { Self.write(response, to: client) }
        close(client)
        lock.withLock { activeConnections -= 1 }
    }

    // MARK: - Socket helpers

    private enum ReadResult {
        case request(Data)
        case tooLarge
        case failed
    }

    private static func readRequest(from client: Int32) -> ReadResult {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
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
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
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

    private static func removeStaleSocket(_ path: String) throws {
        var info = stat()
        guard lstat(path, &info) == 0 else { return }
        guard info.st_mode & S_IFMT == S_IFSOCK else { throw StartError.notASocket }
        if acceptsConnections(path) { throw StartError.inUse }
        unlink(path)
    }

    private static func acceptsConnections(_ path: String) -> Bool {
        let probe = socket(AF_UNIX, SOCK_STREAM, 0)
        guard probe >= 0 else { return false }
        defer { close(probe) }
        var address = address(path)
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(probe, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
            }
        }
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
