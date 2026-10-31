import Darwin
import Foundation
import XCTest
@testable import HistoryAccessCLI
import TranscriptionText

final class HistoryAccessCLITests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private let entry = HistoryAccessEntry(
        id: "6F9619FF-8B86-D011-B42D-00C04FC964FF", timestamp: "2026-09-21T14:13:20.000Z",
        originalText: "hello world", enhancedText: nil, mode: "Email", transcriptionModel: "parakeet-tdt-0.6b-v3",
        enhancementModel: nil, prompt: nil, durationMilliseconds: 4_200, transcriptionDurationMilliseconds: 310,
        enhancementDurationMilliseconds: nil)

    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    // MARK: - Command line

    func testListParsesPageOptionsIntoOneRequest() throws {
        let invocation = try HistoryCommandLine.parse(
            ["list", "--limit", "5", "--since", "3d", "--until", "now", "--cursor", "abc", "--json",
             "--namespace", "development"], now: now)

        XCTAssertEqual(invocation, .request(
            HistoryAccessRequest(command: .list, limit: 5, sinceMilliseconds: 1_789_740_800_000,
                                 untilMilliseconds: 1_790_000_000_000, cursor: "abc"),
            json: true, namespace: .development))
    }

    func testSearchJoinsOperandsAndShowRequiresOneUUID() throws {
        XCTAssertEqual(
            try HistoryCommandLine.parse(["search", "release", "notes"], now: now),
            .request(HistoryAccessRequest(command: .search, query: "release notes"), json: false, namespace: .production))
        XCTAssertEqual(
            try HistoryCommandLine.parse(["show", entry.id], now: now),
            .request(HistoryAccessRequest(command: .show, id: entry.id), json: false, namespace: .production))
        XCTAssertEqual(try HistoryCommandLine.parse(["mcp", "--namespace", "local"], now: now), .mcp(namespace: .local))
    }

    func testInvalidInvocationsAreRejected() {
        let invalid: [[String]] = [
            [], ["delete"], ["list", "extra"], ["search"], ["search", "  "], ["show"], ["show", "not-a-uuid"],
            ["show", entry.id, "--limit", "2"], ["list", "--limit", "0"], ["list", "--limit", "201"],
            ["list", "--since", "soon"], ["list", "--since", "now", "--until", "1d"], ["list", "--bogus"],
            ["list", "--namespace", "beta"], ["mcp", "--json"], ["mcp", "--limit", "3"], ["list", "--limit"],
        ]
        for arguments in invalid {
            XCTAssertThrowsError(try HistoryCommandLine.parse(arguments, now: now), "\(arguments)")
        }
    }

    func testTimeValues() throws {
        func ms(_ text: String) throws -> Int64 { try HistoryTime.milliseconds(text, now: now, calendar: utc) }

        XCTAssertEqual(try ms("90m"), 1_790_000_000_000 - 5_400_000)
        XCTAssertEqual(try ms("36h"), 1_790_000_000_000 - 129_600_000)
        XCTAssertEqual(try ms("2w"), 1_790_000_000_000 - 1_209_600_000)
        XCTAssertEqual(try ms("today"), 1_789_948_800_000)
        XCTAssertEqual(try ms("yesterday"), 1_789_862_400_000)
        XCTAssertEqual(try ms("2026-10-20"), 1_792_454_400_000)
        XCTAssertEqual(try ms("2026-10-20T10:00:00+02:00"), 1_792_483_200_000)
        XCTAssertEqual(try ms("2026-10-20T08:00:00.250Z"), 1_792_483_200_250)
        XCTAssertEqual(try ms("1790000000"), 1_790_000_000_000)
        for invalid in ["", "3x", "2026-02-30", "2026-1-2", "next week", "1.5d"] {
            XCTAssertThrowsError(try ms(invalid), invalid)
        }
    }

    // MARK: - Application

    func testJSONOutputKeepsNullableFieldsAndExitsZero() throws {
        let transport = FakeTransport(response: .page([entry], nextCursor: "next"))
        var output = Data()
        var errors: [String] = []

        let code = HistoryCLIApplication.run(
            arguments: ["list", "--json", "--limit", "1"], stdout: { output.append($0) }, stderr: { errors.append($0) },
            now: now, transport: { _ in transport })

        XCTAssertEqual(code, 0)
        XCTAssertEqual(errors, [])
        XCTAssertEqual(transport.requests, [HistoryAccessRequest(command: .list, limit: 1)])
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: output) as? [String: Any])
        XCTAssertEqual(object["version"] as? Int, 1)
        XCTAssertEqual(object["truncated"] as? Bool, true)
        XCTAssertEqual(object["next_cursor"] as? String, "next")
        let first = try XCTUnwrap((object["entries"] as? [[String: Any]])?.first)
        XCTAssertEqual(first["original_text"] as? String, "hello world")
        XCTAssertEqual(first["duration_ms"] as? Int, 4_200)
        XCTAssertTrue(first["enhanced_text"] is NSNull)
        XCTAssertTrue(first["enhancement_model"] is NSNull)
        XCTAssertEqual(
            Set(first.keys),
            ["id", "timestamp", "original_text", "enhanced_text", "mode", "transcription_model", "enhancement_model",
             "prompt", "duration_ms", "transcription_duration_ms", "enhancement_duration_ms"])
    }

    func testTextOutputUsesLocalTimeAndPreferredText() {
        var enhanced = entry
        enhanced.enhancedText = "Hello, world."
        var output = Data()

        let code = HistoryCLIApplication.run(
            arguments: ["search", "hello"], stdout: { output.append($0) }, stderr: { _ in }, now: now,
            timeZone: TimeZone(identifier: "UTC")!, transport: { _ in FakeTransport(response: .page([enhanced], nextCursor: "c")) })

        XCTAssertEqual(code, 0)
        XCTAssertEqual(String(decoding: output, as: UTF8.self), """
        2026-09-21 14:13:20  Email · parakeet-tdt-0.6b-v3 · 4.2 s
        \(entry.id)
        Hello, world.

        More entries: --cursor c

        """)
    }

    func testExitCodesSeparateUsageFailuresAndUnavailableApp() {
        func run(_ arguments: [String], _ transport: FakeTransport) -> (Int32, [String]) {
            var errors: [String] = []
            let code = HistoryCLIApplication.run(
                arguments: arguments, stdout: { _ in }, stderr: { errors.append($0) }, now: now, transport: { _ in transport })
            return (code, errors)
        }
        let notFound = FakeTransport(response: .failure(HistoryAccessFailure(.notFound, "No entry")))
        let unavailable = FakeTransport(error: HistoryClientError.unavailable("VoiceInk is not running"))

        XCTAssertEqual(run(["show", entry.id], notFound).0, 1)
        XCTAssertEqual(run(["show", entry.id], notFound).1, ["not_found: No entry"])
        XCTAssertEqual(run(["list"], unavailable).0, 3)
        XCTAssertEqual(run(["list", "--limit", "x"], notFound).0, 2)
        XCTAssertEqual(run(["--help"], notFound).0, 0)
        XCTAssertTrue(notFound.requests.allSatisfy { $0.command == .show })
    }

    // MARK: - MCP

    func testMCPInitializeNegotiatesVersionAndIgnoresNotifications() throws {
        let server = HistoryMCPServer(now: { self.now }, transport: { FakeTransport(response: .page([], nextCursor: nil)) })

        let reply = try json(server.handle(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26"}}"#))
        let unknownVersion = try json(server.handle(#"{"jsonrpc":"2.0","id":2,"method":"initialize","params":{"protocolVersion":"1999-01-01"}}"#))

        XCTAssertEqual((reply["result"] as? [String: Any])?["protocolVersion"] as? String, "2025-03-26")
        XCTAssertEqual((unknownVersion["result"] as? [String: Any])?["protocolVersion"] as? String, "2025-06-18")
        XCTAssertNil(server.handle(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#))
        XCTAssertEqual(try json(server.handle("{oops"))["error"].flatMap { ($0 as? [String: Any])?["code"] as? Int }, -32700)
        XCTAssertEqual(try json(server.handle(#"{"jsonrpc":"2.0","id":3,"method":"resources/list"}"#))["error"]
            .flatMap { ($0 as? [String: Any])?["code"] as? Int }, -32601)
    }

    func testMCPToolsAreReadOnly() throws {
        let server = HistoryMCPServer(now: { self.now }, transport: { FakeTransport(response: .page([], nextCursor: nil)) })

        let reply = try json(server.handle(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#))

        let tools = try XCTUnwrap((reply["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.compactMap { $0["name"] as? String }, ["list_history", "search_history", "get_history_entry"])
        for tool in tools {
            let annotations = try XCTUnwrap(tool["annotations"] as? [String: Any])
            XCTAssertEqual(annotations["readOnlyHint"] as? Bool, true)
            XCTAssertEqual(annotations["destructiveHint"] as? Bool, false)
        }
    }

    func testMCPToolCallsMapArgumentsAndReportErrorsAsToolResults() throws {
        let transport = FakeTransport(response: .page([entry], nextCursor: nil))
        let server = HistoryMCPServer(now: { self.now }, transport: { transport })

        let search = try json(server.handle(#"""
        {"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"search_history","arguments":{"query":"hello","limit":3,"since":"1d"}}}
        """#))
        let missingQuery = try json(server.handle(#"{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"search_history","arguments":{}}}"#))
        let badLimit = try json(server.handle(#"{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"list_history","arguments":{"limit":true}}}"#))
        let unknown = try json(server.handle(#"{"jsonrpc":"2.0","id":10,"method":"tools/call","params":{"name":"delete_history"}}"#))

        let result = try XCTUnwrap(search["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, false)
        let structured = try XCTUnwrap(result["structuredContent"] as? [String: Any])
        XCTAssertEqual((structured["entries"] as? [[String: Any]])?.first?["id"] as? String, entry.id)
        XCTAssertEqual(transport.requests, [HistoryAccessRequest(
            command: .search, limit: 3, sinceMilliseconds: 1_789_913_600_000, query: "hello")])
        XCTAssertEqual((missingQuery["result"] as? [String: Any])?["isError"] as? Bool, true)
        XCTAssertEqual((badLimit["result"] as? [String: Any])?["isError"] as? Bool, true)
        XCTAssertEqual((unknown["error"] as? [String: Any])?["code"] as? Int, -32602)
        XCTAssertEqual(transport.requests.count, 1)
    }

    func testMCPRejectsMalformedEnvelopesAndArgumentsWithoutQuerying() throws {
        let transport = FakeTransport(response: .page([entry], nextCursor: nil))
        let server = HistoryMCPServer(now: { self.now }, transport: { transport })
        func errorCode(_ line: String) throws -> Int? {
            (try json(server.handle(line))["error"] as? [String: Any])?["code"] as? Int
        }
        func isToolError(_ arguments: String) throws -> Bool? {
            let line = #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"list_history","arguments":"#
                + arguments + "}}"
            return (try json(server.handle(line))["result"] as? [String: Any])?["isError"] as? Bool
        }

        XCTAssertEqual(try errorCode("{}"), -32600)
        XCTAssertEqual(try errorCode("[]"), -32600)
        XCTAssertEqual(try errorCode(#"{"id":1,"method":"ping"}"#), -32600)
        XCTAssertEqual(try errorCode(#"{"jsonrpc":"2.0","id":true,"method":"ping"}"#), -32600)
        XCTAssertEqual(try errorCode(#"{"jsonrpc":"2.0","id":1,"method":"tools/list","params":[]}"#), -32602)
        XCTAssertEqual(try errorCode(
            #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"list_history","arguments":"x"}}"#), -32602)
        XCTAssertEqual(try isToolError(#"{"since_ms":5}"#), true)
        XCTAssertEqual(try isToolError(#"{"limit":18446744073709551617}"#), true)
        XCTAssertEqual(try isToolError(#"{"limit":2.5}"#), true)
        XCTAssertEqual(try isToolError(#"{"limit":"5"}"#), true)
        XCTAssertEqual(try isToolError(#"{"query":"x"}"#), true)
        XCTAssertNil(server.handle(#"{"jsonrpc":"2.0","method":"tools/call","params":"bad"}"#))
        XCTAssertEqual(transport.requests, [])
        XCTAssertEqual(try isToolError(#"{"limit":200}"#), false)
        XCTAssertEqual(transport.requests, [HistoryAccessRequest(command: .list, limit: 200)])
    }

    func testMCPReportsUnavailableAppAsToolError() throws {
        let server = HistoryMCPServer(now: { self.now }, transport: {
            FakeTransport(error: HistoryClientError.unavailable("VoiceInk is not running"))
        })

        let reply = try json(server.handle(#"{"jsonrpc":"2.0","id":"a","method":"tools/call","params":{"name":"get_history_entry","arguments":{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF"}}}"#))

        let result = try XCTUnwrap(reply["result"] as? [String: Any])
        XCTAssertEqual(reply["id"] as? String, "a")
        XCTAssertEqual(result["isError"] as? Bool, true)
        XCTAssertEqual((result["content"] as? [[String: Any]])?.first?["text"] as? String, "VoiceInk is not running")
    }

    // MARK: - Socket client

    func testSocketClientExchangesOneLineWithAnOwnerSocket() throws {
        let directory = try shortTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let socketURL = directory.appendingPathComponent("s")
        let server = try LineServer(path: socketURL.path, reply: HistoryAccessResponse.single(entry))
        let client = HistorySocketClient(socketURL: socketURL)

        let response = try client.send(HistoryAccessRequest(command: .show, id: entry.id))

        XCTAssertEqual(response, .single(entry))
        let received = try XCTUnwrap(server.waitForRequest())
        XCTAssertEqual(try JSONDecoder().decode(HistoryAccessRequest.self, from: received),
                       HistoryAccessRequest(command: .show, id: entry.id))
    }

    func testSocketClientRefusesMissingPathsAndNonSockets() throws {
        let directory = try shortTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("file")
        try Data().write(to: file)

        XCTAssertThrowsError(try HistorySocketClient(socketURL: directory.appendingPathComponent("missing"))
            .send(HistoryAccessRequest(command: .list))) { error in
            guard case HistoryClientError.unavailable = error else { return XCTFail("\(error)") }
        }
        XCTAssertThrowsError(try HistorySocketClient(socketURL: file).send(HistoryAccessRequest(command: .list))) { error in
            XCTAssertEqual(error as? HistoryClientError,
                           .unavailable("Refusing \(file.path): it is not a socket owned by the current user."))
        }
    }

    func testNamespacesUseIsolatedSocketPathsWithinTheSocketLimit() throws {
        let paths = try AppNamespace.allCases.map {
            try XCTUnwrap(HistoryAccess.socketURL(storeDirectoryName: $0.storeDirectoryName)).path
        }

        XCTAssertEqual(Set(paths).count, 3)
        XCTAssertTrue(paths.allSatisfy { $0.utf8.count < 104 }, "\(paths)")
        XCTAssertTrue(paths[1].hasSuffix("/com.prakashjoshipax.VoiceInk.dev.history.sock"))
    }

    // MARK: - Helpers

    private func json(_ data: Data?) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(data)) as? [String: Any])
    }

    private func shortTemporaryDirectory() throws -> URL {
        let url = URL(fileURLWithPath: "/tmp/vih-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }
}

private final class FakeTransport: HistoryTransport {
    private let result: Result<HistoryAccessResponse, Error>
    private(set) var requests: [HistoryAccessRequest] = []

    init(response: HistoryAccessResponse) { result = .success(response) }
    init(error: Error) { result = .failure(error) }

    func send(_ request: HistoryAccessRequest) throws -> HistoryAccessResponse {
        requests.append(request)
        return try result.get()
    }
}

/// Accepts one connection, records its request line and answers with a fixed response.
private final class LineServer {
    private let descriptor: Int32
    private let received = DispatchSemaphore(value: 0)
    private var request: Data?

    init(path: String, reply: HistoryAccessResponse) throws {
        descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: Array(path.utf8))
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(descriptor, 1) == 0 else { throw POSIXError(.EADDRINUSE) }
        var payload = try JSONEncoder().encode(reply)
        payload.append(UInt8(ascii: "\n"))
        let descriptor = descriptor
        Thread.detachNewThread { [self] in
            let client = accept(descriptor, nil, nil)
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 1024)
            while true {
                let count = recv(client, &buffer, buffer.count, 0)
                guard count > 0 else { break }
                if let newline = buffer[..<count].firstIndex(of: UInt8(ascii: "\n")) {
                    data.append(contentsOf: buffer[..<newline])
                    break
                }
                data.append(contentsOf: buffer[..<count])
            }
            request = data
            payload.withUnsafeBytes { _ = Darwin.send(client, $0.baseAddress!, $0.count, 0) }
            close(client)
            received.signal()
        }
    }

    deinit { close(descriptor) }

    func waitForRequest() -> Data? {
        received.wait(timeout: .now() + 5) == .success ? request : nil
    }
}
