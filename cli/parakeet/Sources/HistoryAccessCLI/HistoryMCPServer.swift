import Foundation

/// Minimal read-only MCP server (JSON-RPC 2.0, one message per stdio line). Each tool call asks the
/// running app over its socket; the server keeps no History, cache or log of its own.
public final class HistoryMCPServer {
    static let supportedProtocolVersions = ["2024-11-05", "2025-03-26", "2025-06-18"]

    private let now: () -> Date
    private let transport: () throws -> HistoryTransport

    public init(now: @escaping () -> Date, transport: @escaping () throws -> HistoryTransport) {
        self.now = now
        self.transport = transport
    }

    /// Returns the reply line, or `nil` for notifications.
    public func handle(_ line: String) -> Data? {
        guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8), options: .fragmentsAllowed) else {
            return reply(id: NSNull(), error: (-32700, "Parse error"))
        }
        guard let message = object as? [String: Any], message["jsonrpc"] as? String == "2.0" else {
            return reply(id: NSNull(), error: (-32600, "Invalid request"))
        }
        let id = message["id"]
        if let id, !Self.isValidID(id) {
            return reply(id: NSNull(), error: (-32600, "Invalid request"))
        }
        guard let method = message["method"] as? String else {
            return reply(id: id ?? NSNull(), error: (-32600, "Invalid request"))
        }
        // Notifications get no reply, even when malformed.
        guard let id else { return nil }
        let params: [String: Any]
        switch message["params"] {
        case nil: params = [:]
        case let object as [String: Any]: params = object
        default: return reply(id: id, error: (-32602, "params must be an object"))
        }
        switch method {
        case "initialize":
            let requested = params["protocolVersion"] as? String
            let version = requested.flatMap { Self.supportedProtocolVersions.contains($0) ? $0 : nil }
                ?? Self.supportedProtocolVersions.last!
            return reply(id: id, result: [
                "protocolVersion": version,
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "voiceink-history", "version": HistoryCommandLine.version],
                "instructions": """
                Read-only access to completed VoiceInk dictations kept in History on this Mac. \
                VoiceInk must be running with History > Settings > Agent Access enabled. \
                Results are newest first; pass next_cursor back as cursor to read older entries.
                """,
            ])
        case "ping":
            return reply(id: id, result: [:])
        case "tools/list":
            return reply(id: id, result: ["tools": Self.tools])
        case "tools/call":
            guard let name = params["name"] as? String, Self.tools.contains(where: { $0["name"] as? String == name })
            else {
                return reply(id: id, error: (-32602, "Unknown tool"))
            }
            let arguments: [String: Any]
            switch params["arguments"] {
            case nil: arguments = [:]
            case let object as [String: Any]: arguments = object
            default: return reply(id: id, error: (-32602, "arguments must be an object"))
            }
            return reply(id: id, result: call(name, arguments: arguments))
        default:
            return reply(id: id, error: (-32601, "Method not found"))
        }
    }

    private func call(_ name: String, arguments: [String: Any]) -> [String: Any] {
        let request: HistoryAccessRequest
        do {
            request = try Self.request(for: name, arguments: arguments, now: now())
        } catch {
            return Self.toolError("\(error)")
        }
        let response: HistoryAccessResponse
        do {
            response = try transport().send(request)
        } catch HistoryClientError.unavailable(let message), HistoryClientError.protocolFailure(let message) {
            return Self.toolError(message)
        } catch {
            return Self.toolError("Could not read History.")
        }
        if let failure = response.error {
            return Self.toolError("\(failure.code.rawValue): \(failure.message)")
        }
        let data = HistoryOutput.json(response)
        return [
            "content": [["type": "text", "text": String(decoding: data, as: UTF8.self)]],
            "structuredContent": (try? JSONSerialization.jsonObject(with: data)) ?? [:],
            "isError": false,
        ]
    }

    private static func isValidID(_ id: Any) -> Bool {
        if id is String { return true }
        guard let number = id as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return false }
        return number.doubleValue.rounded() == number.doubleValue
    }

    static func request(for name: String, arguments: [String: Any], now: Date) throws -> HistoryAccessRequest {
        let schema = tools.first { $0["name"] as? String == name }?["inputSchema"] as? [String: Any]
        let allowed = Set((schema?["properties"] as? [String: Any]).map { Array($0.keys) } ?? [])
        if let unknown = arguments.keys.sorted().first(where: { !allowed.contains($0) }) {
            throw HistoryUsageError("Unknown argument: \(unknown)")
        }
        func string(_ key: String) throws -> String? {
            guard let value = arguments[key] else { return nil }
            guard let text = value as? String else { throw HistoryUsageError("\(key) must be a string") }
            return text
        }
        func time(_ key: String) throws -> Int64? {
            try string(key).map { try HistoryTime.milliseconds($0, now: now) }
        }
        switch name {
        case "get_history_entry":
            guard let id = try string("id"), UUID(uuidString: id) != nil else {
                throw HistoryUsageError("id must be an entry UUID")
            }
            return HistoryAccessRequest(command: .show, id: id)
        default:
            var limit: Int?
            if let value = arguments["limit"] {
                // Check the full value before narrowing, so huge integers cannot wrap into range.
                guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                    number.doubleValue == number.doubleValue.rounded(),
                    (1...Double(HistoryAccess.maximumLimit)).contains(number.doubleValue)
                else {
                    throw HistoryUsageError("limit must be an integer from 1 to \(HistoryAccess.maximumLimit)")
                }
                limit = number.intValue
            }
            let isSearch = name == "search_history"
            let query = try string("query")?.trimmingCharacters(in: .whitespacesAndNewlines)
            if isSearch, query?.isEmpty ?? true { throw HistoryUsageError("query is required") }
            return HistoryAccessRequest(
                command: isSearch ? .search : .list, limit: limit, sinceMilliseconds: try time("since"),
                untilMilliseconds: try time("until"), query: isSearch ? query : nil, cursor: try string("cursor"))
        }
    }

    private static func toolError(_ message: String) -> [String: Any] {
        ["content": [["type": "text", "text": message]], "isError": true]
    }

    private func reply(id: Any, result: [String: Any]) -> Data {
        Self.serialize(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private func reply(id: Any, error: (code: Int, message: String)) -> Data {
        Self.serialize(["jsonrpc": "2.0", "id": id, "error": ["code": error.code, "message": error.message]])
    }

    private static func serialize(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]))
            ?? Data(#"{"error":{"code":-32603,"message":"Internal error"},"id":null,"jsonrpc":"2.0"}"#.utf8)
    }

    private static let timeDescription =
        "90m, 36h, 3d, 2w, now, today, yesterday, YYYY-MM-DD (local midnight), RFC 3339, or Unix seconds"

    private static let pageProperties: [String: Any] = [
        "limit": [
            "type": "integer", "minimum": 1, "maximum": HistoryAccess.maximumLimit,
            "description": "Entries to return (default \(HistoryAccess.defaultLimit))",
        ],
        "since": ["type": "string", "description": "Inclusive lower bound: \(timeDescription)"],
        "until": ["type": "string", "description": "Exclusive upper bound: \(timeDescription)"],
        "cursor": ["type": "string", "description": "next_cursor from a previous response"],
    ]

    private static let annotations: [String: Any] = [
        "readOnlyHint": true, "destructiveHint": false, "idempotentHint": true, "openWorldHint": false,
    ]

    static let tools: [[String: Any]] = [
        [
            "name": "list_history",
            "title": "List VoiceInk History",
            "description":
                "Completed VoiceInk dictations, newest first, with original and enhanced text, timestamp, mode, models and durations.",
            "inputSchema": ["type": "object", "properties": pageProperties, "additionalProperties": false],
            "annotations": annotations,
        ],
        [
            "name": "search_history",
            "title": "Search VoiceInk History",
            "description":
                "Completed dictations whose original or enhanced text contains the query (case- and diacritic-insensitive substring), newest first.",
            "inputSchema": [
                "type": "object",
                "properties": pageProperties.merging(
                    ["query": ["type": "string", "description": "Text to find"]], uniquingKeysWith: { $1 }),
                "required": ["query"],
                "additionalProperties": false,
            ],
            "annotations": annotations,
        ],
        [
            "name": "get_history_entry",
            "title": "Get VoiceInk History Entry",
            "description": "One completed dictation by its UUID.",
            "inputSchema": [
                "type": "object",
                "properties": ["id": ["type": "string", "description": "Entry UUID"]],
                "required": ["id"],
                "additionalProperties": false,
            ],
            "annotations": annotations,
        ],
    ]
}
