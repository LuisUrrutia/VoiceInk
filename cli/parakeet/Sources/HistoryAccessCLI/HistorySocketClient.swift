import Darwin
import Foundation
import TranscriptionText

public enum HistoryClientError: Error, Equatable {
    /// VoiceInk is not running, agent access is off, or the socket is not private to this user.
    case unavailable(String)
    case protocolFailure(String)
}

public protocol HistoryTransport {
    func send(_ request: HistoryAccessRequest) throws -> HistoryAccessResponse
}

/// Talks only to the running app's owner-only socket; it never opens VoiceInk's stores.
public struct HistorySocketClient: HistoryTransport {
    public static let maximumResponseBytes = 64 * 1024 * 1024
    public let socketURL: URL
    public var timeoutSeconds = 30

    public init(socketURL: URL) {
        self.socketURL = socketURL
    }

    public init(namespace: AppNamespace) throws {
        guard let url = HistoryAccess.socketURL(storeDirectoryName: namespace.storeDirectoryName) else {
            throw HistoryClientError.unavailable("Could not locate the per-user temporary directory.")
        }
        self.init(socketURL: url)
    }

    public func send(_ request: HistoryAccessRequest) throws -> HistoryAccessResponse {
        let path = socketURL.path
        let unavailable = HistoryClientError.unavailable(
            "VoiceInk is not running, or History > Settings > Agent Access is off (\(path)).")
        var info = stat()
        guard lstat(path, &info) == 0 else { throw unavailable }
        guard info.st_mode & S_IFMT == S_IFSOCK, info.st_uid == getuid() else {
            throw HistoryClientError.unavailable("Refusing \(path): it is not a socket owned by the current user.")
        }
        var address = sockaddr_un()
        guard path.utf8.count < MemoryLayout.size(ofValue: address.sun_path) else { throw unavailable }
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            let bytes = Array(path.utf8)
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }

        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw unavailable }
        defer { close(descriptor) }
        var enabled: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: timeoutSeconds, tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { throw unavailable }

        var payload = try JSONEncoder().encode(request)
        payload.append(UInt8(ascii: "\n"))
        try payload.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = Darwin.send(descriptor, raw.baseAddress! + offset, raw.count - offset, 0)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw HistoryClientError.protocolFailure("Could not send the request to VoiceInk.")
                }
                offset += written
            }
        }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = recv(descriptor, &buffer, buffer.count, 0)
            if count < 0 {
                if errno == EINTR { continue }
                throw HistoryClientError.protocolFailure("VoiceInk did not answer in time.")
            }
            if count == 0 { break }
            if let newline = buffer[..<count].firstIndex(of: UInt8(ascii: "\n")) {
                data.append(contentsOf: buffer[..<newline])
                break
            }
            data.append(contentsOf: buffer[..<count])
            guard data.count <= Self.maximumResponseBytes else {
                throw HistoryClientError.protocolFailure("VoiceInk's response exceeds the size limit.")
            }
        }
        do {
            let response = try JSONDecoder().decode(HistoryAccessResponse.self, from: data)
            guard response.version == HistoryAccess.protocolVersion else {
                throw HistoryClientError.protocolFailure("VoiceInk answered with protocol version \(response.version).")
            }
            return response
        } catch let error as HistoryClientError {
            throw error
        } catch {
            throw HistoryClientError.protocolFailure("VoiceInk's response is not valid version 1 JSON.")
        }
    }
}
