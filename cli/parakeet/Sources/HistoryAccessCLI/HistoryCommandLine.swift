import Foundation
import TranscriptionText

public struct HistoryUsageError: Error, Equatable, CustomStringConvertible {
    public let description: String
    init(_ description: String) { self.description = description }
}

public enum HistoryInvocation: Equatable {
    case help
    case version
    case request(HistoryAccessRequest, json: Bool, namespace: AppNamespace)
    case mcp(namespace: AppNamespace)
}

public enum HistoryCommandLine {
    public static let version = "1.0.0"
    public static let usage = """
    Usage: voiceink-history <command> [options]
      list                    Completed entries, newest first
      search QUERY            Entries whose original or enhanced text contains QUERY
      show ID                 One entry by UUID
      mcp                     Read-only MCP server over stdio
    Options:
          --limit N           1-\(HistoryAccess.maximumLimit) entries (default: \(HistoryAccess.defaultLimit); list, search)
          --since TIME        Inclusive lower bound (list, search)
          --until TIME        Exclusive upper bound (list, search)
          --cursor CURSOR     Continue after a previous response's next_cursor
          --json              Version 1 JSON on stdout
          --namespace production|development|local (default: production)
      -h, --help              Show usage
          --version           Show version
    TIME: 90m, 36h, 3d, 2w, now, today, yesterday, YYYY-MM-DD (local midnight),
    an RFC 3339 date-time, or Unix seconds.
    Requires a running VoiceInk with History > Settings > Agent Access enabled.
    The command never opens VoiceInk's stores.
    Exit codes: 0 success, 1 request failed or unknown ID, 2 invalid invocation,
    3 VoiceInk is not running or agent access is off.
    """

    public static func parse(_ arguments: [String], now: Date, calendar: Calendar = .current) throws -> HistoryInvocation {
        var positional: [String] = []
        var json = false
        var namespace = AppNamespace.production
        var limit: Int?
        var since: Int64?
        var until: Int64?
        var cursor: String?
        var index = 0
        var dashDash = false

        func value(_ flag: String) throws -> String {
            index += 1
            guard index < arguments.count else { throw HistoryUsageError("Missing value for \(flag)") }
            return arguments[index]
        }

        while index < arguments.count {
            let argument = arguments[index]
            if dashDash || !argument.hasPrefix("-") || argument == "-" {
                positional.append(argument)
            } else {
                switch argument {
                case "--": dashDash = true
                case "-h", "--help": return .help
                case "--version": return .version
                case "--json": json = true
                case "--namespace":
                    let raw = try value(argument)
                    guard let parsed = AppNamespace(rawValue: raw) else {
                        throw HistoryUsageError("Unsupported namespace: \(raw)")
                    }
                    namespace = parsed
                case "--limit":
                    let raw = try value(argument)
                    guard let parsed = Int(raw), (1...HistoryAccess.maximumLimit).contains(parsed) else {
                        throw HistoryUsageError("--limit must be an integer from 1 to \(HistoryAccess.maximumLimit)")
                    }
                    limit = parsed
                case "--since": since = try HistoryTime.milliseconds(try value(argument), now: now, calendar: calendar)
                case "--until": until = try HistoryTime.milliseconds(try value(argument), now: now, calendar: calendar)
                case "--cursor": cursor = try value(argument)
                default: throw HistoryUsageError("Unknown option: \(argument)")
                }
            }
            index += 1
        }

        guard let command = positional.first else { throw HistoryUsageError("Missing command") }
        let operands = Array(positional.dropFirst())
        let usesPageOptions = limit != nil || since != nil || until != nil || cursor != nil
        if let since, let until, since >= until { throw HistoryUsageError("--since must be earlier than --until") }

        switch command {
        case "list":
            guard operands.isEmpty else { throw HistoryUsageError("list takes no operands") }
            return .request(
                HistoryAccessRequest(
                    command: .list, limit: limit, sinceMilliseconds: since, untilMilliseconds: until, cursor: cursor),
                json: json, namespace: namespace)
        case "search":
            let query = operands.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty else { throw HistoryUsageError("search requires a QUERY") }
            return .request(
                HistoryAccessRequest(
                    command: .search, limit: limit, sinceMilliseconds: since, untilMilliseconds: until, query: query,
                    cursor: cursor),
                json: json, namespace: namespace)
        case "show":
            guard operands.count == 1, UUID(uuidString: operands[0]) != nil else {
                throw HistoryUsageError("show requires one entry UUID")
            }
            guard !usesPageOptions else { throw HistoryUsageError("show does not accept --limit, --since, --until or --cursor") }
            return .request(HistoryAccessRequest(command: .show, id: operands[0]), json: json, namespace: namespace)
        case "mcp":
            guard operands.isEmpty, !usesPageOptions, !json else { throw HistoryUsageError("mcp accepts only --namespace") }
            return .mcp(namespace: namespace)
        default:
            throw HistoryUsageError("Unknown command: \(command)")
        }
    }
}

public enum HistoryTime {
    /// Parses a TIME value into Unix milliseconds. Relative values count back from `now`.
    public static func milliseconds(_ text: String, now: Date, calendar: Calendar = .current) throws -> Int64 {
        guard let date = date(text.trimmingCharacters(in: .whitespaces), now: now, calendar: calendar) else {
            throw HistoryUsageError("Invalid TIME: \(text)")
        }
        let value = (date.timeIntervalSince1970 * 1000).rounded()
        guard value.isFinite, abs(value) < 1e15 else { throw HistoryUsageError("TIME is out of range: \(text)") }
        return Int64(value)
    }

    static func date(_ text: String, now: Date, calendar: Calendar) -> Date? {
        switch text.lowercased() {
        case "now": return now
        case "today": return calendar.startOfDay(for: now)
        case "yesterday": return calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now))
        default: break
        }
        if let last = text.last, let unit = ["m": 60.0, "h": 3_600.0, "d": 86_400.0, "w": 604_800.0][String(last)],
            let amount = Int(text.dropLast()), amount >= 0
        {
            return now.addingTimeInterval(-Double(amount) * unit)
        }
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        if parts.map(\.count) == [4, 2, 2], let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]) {
            let components = DateComponents(year: year, month: month, day: day)
            guard let date = calendar.date(from: components),
                calendar.dateComponents([.year, .month, .day], from: date) == components
            else { return nil }
            return date
        }
        if !text.isEmpty, text.allSatisfy({ $0.isASCII && $0.isNumber }), let seconds = Int64(text) {
            return Date(timeIntervalSince1970: TimeInterval(seconds))
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
}
