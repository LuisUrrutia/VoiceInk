import Foundation

// Shared with cli/parakeet through a symlink: keep this file Foundation-only.
public enum HistoryAccess {
    public static let protocolVersion = 1
    public static let defaultLimit = 20
    public static let maximumLimit = 200
    public static let maximumRequestBytes = 16 * 1024
    public static let maximumQueryCharacters = 1_000

    /// The per-user Darwin temporary directory is private (0700) and short enough for `sun_path` (104 bytes).
    public static func socketURL(storeDirectoryName: String) -> URL? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, buffer.count) > 0 else { return nil }
        return URL(fileURLWithPath: String(cString: buffer), isDirectory: true)
            .appendingPathComponent("\(storeDirectoryName).history.sock", isDirectory: false)
    }

    public static func timestampString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

public struct HistoryAccessRequest: Codable, Equatable, Sendable {
    public enum Command: String, Codable, Sendable {
        case list, search, show
    }

    public var version: Int
    public var command: Command
    public var limit: Int?
    public var sinceMilliseconds: Int64?
    public var untilMilliseconds: Int64?
    public var query: String?
    public var cursor: String?
    public var id: String?

    public init(
        command: Command, limit: Int? = nil, sinceMilliseconds: Int64? = nil, untilMilliseconds: Int64? = nil,
        query: String? = nil, cursor: String? = nil, id: String? = nil, version: Int = HistoryAccess.protocolVersion
    ) {
        self.version = version
        self.command = command
        self.limit = limit
        self.sinceMilliseconds = sinceMilliseconds
        self.untilMilliseconds = untilMilliseconds
        self.query = query
        self.cursor = cursor
        self.id = id
    }

    enum CodingKeys: String, CodingKey {
        case version, command, limit, query, cursor, id
        case sinceMilliseconds = "since_ms"
        case untilMilliseconds = "until_ms"
    }
}

public struct HistoryAccessEntry: Codable, Equatable, Sendable {
    public var id: String
    /// RFC 3339 UTC with milliseconds.
    public var timestamp: String
    public var originalText: String
    /// `nil` when the entry was not enhanced or enhancement failed.
    public var enhancedText: String?
    public var mode: String?
    public var transcriptionModel: String?
    public var enhancementModel: String?
    public var prompt: String?
    public var durationMilliseconds: Int
    public var transcriptionDurationMilliseconds: Int?
    public var enhancementDurationMilliseconds: Int?

    public init(
        id: String, timestamp: String, originalText: String, enhancedText: String?, mode: String?,
        transcriptionModel: String?, enhancementModel: String?, prompt: String?, durationMilliseconds: Int,
        transcriptionDurationMilliseconds: Int?, enhancementDurationMilliseconds: Int?
    ) {
        self.id = id
        self.timestamp = timestamp
        self.originalText = originalText
        self.enhancedText = enhancedText
        self.mode = mode
        self.transcriptionModel = transcriptionModel
        self.enhancementModel = enhancementModel
        self.prompt = prompt
        self.durationMilliseconds = durationMilliseconds
        self.transcriptionDurationMilliseconds = transcriptionDurationMilliseconds
        self.enhancementDurationMilliseconds = enhancementDurationMilliseconds
    }

    enum CodingKeys: String, CodingKey {
        case id, timestamp, mode, prompt
        case originalText = "original_text"
        case enhancedText = "enhanced_text"
        case transcriptionModel = "transcription_model"
        case enhancementModel = "enhancement_model"
        case durationMilliseconds = "duration_ms"
        case transcriptionDurationMilliseconds = "transcription_duration_ms"
        case enhancementDurationMilliseconds = "enhancement_duration_ms"
    }

    // Nullable fields stay present as `null` so consumers see one stable shape.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(timestamp, forKey: .timestamp)
        try container.encode(originalText, forKey: .originalText)
        try container.encode(enhancedText, forKey: .enhancedText)
        try container.encode(mode, forKey: .mode)
        try container.encode(transcriptionModel, forKey: .transcriptionModel)
        try container.encode(enhancementModel, forKey: .enhancementModel)
        try container.encode(prompt, forKey: .prompt)
        try container.encode(durationMilliseconds, forKey: .durationMilliseconds)
        try container.encode(transcriptionDurationMilliseconds, forKey: .transcriptionDurationMilliseconds)
        try container.encode(enhancementDurationMilliseconds, forKey: .enhancementDurationMilliseconds)
    }
}

public struct HistoryAccessFailure: Codable, Equatable, Sendable, Error {
    public enum Code: String, Codable, Sendable {
        case invalidRequest = "invalid_request"
        case unsupportedVersion = "unsupported_version"
        case notFound = "not_found"
        case busy
        case internalError = "internal_error"
    }

    public var code: Code
    public var message: String

    public init(_ code: Code, _ message: String) {
        self.code = code
        self.message = message
    }
}

/// `entries` answers list and search, `entry` answers show, and `error` replaces both.
public struct HistoryAccessResponse: Codable, Equatable, Sendable {
    public var version: Int
    public var entries: [HistoryAccessEntry]?
    public var truncated: Bool?
    public var nextCursor: String?
    public var entry: HistoryAccessEntry?
    public var error: HistoryAccessFailure?

    public static func page(_ entries: [HistoryAccessEntry], nextCursor: String?) -> Self {
        Self(version: HistoryAccess.protocolVersion, entries: entries, truncated: nextCursor != nil, nextCursor: nextCursor)
    }

    public static func single(_ entry: HistoryAccessEntry) -> Self {
        Self(version: HistoryAccess.protocolVersion, entry: entry)
    }

    public static func failure(_ failure: HistoryAccessFailure) -> Self {
        Self(version: HistoryAccess.protocolVersion, error: failure)
    }

    enum CodingKeys: String, CodingKey {
        case version, entries, truncated, entry, error
        case nextCursor = "next_cursor"
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        if let error {
            try container.encode(error, forKey: .error)
        } else if let entries {
            try container.encode(entries, forKey: .entries)
            try container.encode(truncated ?? false, forKey: .truncated)
            try container.encode(nextCursor, forKey: .nextCursor)
        } else if let entry {
            try container.encode(entry, forKey: .entry)
        }
    }
}
