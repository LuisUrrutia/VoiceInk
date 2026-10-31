import Foundation
import SwiftData

/// Answers agent requests from an isolated, read-only context; it never saves or mutates History.
struct HistoryAccessService: Sendable {
    let container: ModelContainer

    func respond(to requestData: Data) async -> Data {
        let response: HistoryAccessResponse
        do {
            let request = try JSONDecoder().decode(HistoryAccessRequest.self, from: requestData)
            response = await self.response(for: request)
        } catch {
            response = .failure(HistoryAccessFailure(.invalidRequest, "The request is not valid version 1 JSON."))
        }
        return Self.encode(response)
    }

    func response(for request: HistoryAccessRequest) async -> HistoryAccessResponse {
        let query: HistoryAccessQuery
        do {
            query = try HistoryAccessQuery(request)
        } catch let failure as HistoryAccessFailure {
            return .failure(failure)
        } catch {
            return .failure(HistoryAccessFailure(.invalidRequest, "The request is not valid."))
        }
        let container = container
        let task = Task.detached(priority: .utility) { () throws -> HistoryAccessResponse in
            let context = ModelContext(container)
            context.autosaveEnabled = false
            return try query.run(in: context)
        }
        do {
            return try await task.value
        } catch let failure as HistoryAccessFailure {
            return .failure(failure)
        } catch {
            return .failure(HistoryAccessFailure(.internalError, "VoiceInk could not read History."))
        }
    }

    static func encode(_ response: HistoryAccessResponse) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(response))
            ?? Data(#"{"error":{"code":"internal_error","message":"Encoding failed."},"version":1}"#.utf8)
    }
}

enum HistoryAccessQuery: Equatable, Sendable {
    case page(search: String?, since: Date, until: Date, cursor: HistoryCursor?, limit: Int)
    case entry(UUID)

    init(_ request: HistoryAccessRequest) throws {
        guard request.version == HistoryAccess.protocolVersion else {
            throw HistoryAccessFailure(.unsupportedVersion, "Only protocol version 1 is supported.")
        }
        switch request.command {
        case .show:
            guard let raw = request.id, let id = UUID(uuidString: raw) else {
                throw HistoryAccessFailure(.invalidRequest, "show requires an entry UUID.")
            }
            self = .entry(id)
        case .list, .search:
            let limit = request.limit ?? HistoryAccess.defaultLimit
            guard (1...HistoryAccess.maximumLimit).contains(limit) else {
                throw HistoryAccessFailure(.invalidRequest, "limit must be between 1 and \(HistoryAccess.maximumLimit).")
            }
            let since = request.sinceMilliseconds.map(Self.date(milliseconds:)) ?? .distantPast
            let until = request.untilMilliseconds.map(Self.date(milliseconds:)) ?? .distantFuture
            guard since < until else {
                throw HistoryAccessFailure(.invalidRequest, "since must be earlier than until.")
            }
            var cursor: HistoryCursor?
            if let raw = request.cursor {
                guard let decoded = HistoryCursor(encoded: raw) else {
                    throw HistoryAccessFailure(.invalidRequest, "cursor is not a value returned by VoiceInk.")
                }
                cursor = decoded
            }
            var search: String?
            if request.command == .search {
                let text = request.query?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !text.isEmpty, text.count <= HistoryAccess.maximumQueryCharacters else {
                    throw HistoryAccessFailure(
                        .invalidRequest, "search requires a query of 1 to \(HistoryAccess.maximumQueryCharacters) characters.")
                }
                search = text
            }
            self = .page(search: search, since: since, until: until, cursor: cursor, limit: limit)
        }
    }

    private static func date(milliseconds: Int64) -> Date {
        Date(timeIntervalSince1970: Double(milliseconds) / 1000)
    }

    func run(in context: ModelContext) throws -> HistoryAccessResponse {
        switch self {
        case .entry(let id):
            var descriptor = FetchDescriptor<Transcription>(predicate: Self.entryPredicate(id))
            descriptor.fetchLimit = 1
            guard let transcription = try context.fetch(descriptor).first else {
                throw HistoryAccessFailure(.notFound, "No completed History entry has that ID.")
            }
            return .single(HistoryAccessEntry(transcription))
        case .page(let search, let since, let until, let cursor, let limit):
            let items = try context.fetch(
                Self.pageDescriptor(search: search, since: since, until: until, cursor: cursor, limit: limit))
            let page = items.prefix(limit)
            let next = items.count > limit ? page.last.map { HistoryCursor(timestamp: $0.timestamp, id: $0.id) } : nil
            return .page(page.map(HistoryAccessEntry.init), nextCursor: next?.encoded)
        }
    }

    // Legacy rows predate statuses and are completed transcriptions.
    private static let completed: String? = TranscriptionStatus.completed.rawValue

    private static func entryPredicate(_ id: UUID) -> Predicate<Transcription> {
        let completed = completed
        return #Predicate<Transcription> { transcription in
            transcription.id == id
                && (transcription.transcriptionStatus == nil || transcription.transcriptionStatus == completed)
        }
    }

    /// Same order and exclusive composite cursor as main-window History, with one extra row for exhaustion.
    static func pageDescriptor(
        search: String?, since: Date, until: Date, cursor: HistoryCursor?, limit: Int
    ) -> FetchDescriptor<Transcription> {
        let completed = completed
        let cursorTimestamp = cursor?.timestamp ?? .distantFuture
        let cursorID = cursor?.id ?? UUID()
        var descriptor = FetchDescriptor<Transcription>(sortBy: [
            SortDescriptor(\Transcription.timestamp, order: .reverse),
            SortDescriptor(\Transcription.id, order: .reverse)
        ])
        if let search {
            descriptor.predicate = #Predicate<Transcription> { transcription in
                transcription.timestamp >= since && transcription.timestamp < until
                    && (transcription.timestamp < cursorTimestamp
                        || (transcription.timestamp == cursorTimestamp && transcription.id < cursorID))
                    && (transcription.transcriptionStatus == nil || transcription.transcriptionStatus == completed)
                    && (transcription.text.localizedStandardContains(search)
                        || (transcription.enhancedText?.localizedStandardContains(search) ?? false))
            }
        } else {
            descriptor.predicate = #Predicate<Transcription> { transcription in
                transcription.timestamp >= since && transcription.timestamp < until
                    && (transcription.timestamp < cursorTimestamp
                        || (transcription.timestamp == cursorTimestamp && transcription.id < cursorID))
                    && (transcription.transcriptionStatus == nil || transcription.transcriptionStatus == completed)
            }
        }
        descriptor.fetchLimit = limit + 1
        return descriptor
    }
}

extension HistoryCursor: Equatable {
    static func == (lhs: HistoryCursor, rhs: HistoryCursor) -> Bool {
        lhs.timestamp == rhs.timestamp && lhs.id == rhs.id
    }

    /// Opaque to clients; keeps the exact stored timestamp so ties resume without gaps or repeats.
    var encoded: String {
        String(timestamp.timeIntervalSinceReferenceDate.bitPattern, radix: 16) + "_" + id.uuidString
    }

    init?(encoded: String) {
        let parts = encoded.split(separator: "_", omittingEmptySubsequences: false)
        guard parts.count == 2, let bits = UInt64(parts[0], radix: 16), let id = UUID(uuidString: String(parts[1]))
        else { return nil }
        let interval = Double(bitPattern: bits)
        guard interval.isFinite else { return nil }
        self.init(timestamp: Date(timeIntervalSinceReferenceDate: interval), id: id)
    }
}

extension HistoryAccessEntry {
    init(_ transcription: Transcription) {
        self.init(
            id: transcription.id.uuidString,
            timestamp: HistoryAccess.timestampString(transcription.timestamp),
            originalText: transcription.text,
            enhancedText: transcription.enhancedHistoryText,
            mode: transcription.modeName,
            transcriptionModel: transcription.transcriptionModelName,
            enhancementModel: transcription.aiEnhancementModelName,
            prompt: transcription.promptName,
            durationMilliseconds: Self.milliseconds(transcription.duration) ?? 0,
            transcriptionDurationMilliseconds: transcription.transcriptionDuration.flatMap(Self.milliseconds),
            enhancementDurationMilliseconds: transcription.enhancementDuration.flatMap(Self.milliseconds)
        )
    }

    private static func milliseconds(_ seconds: TimeInterval) -> Int? {
        let value = (seconds * 1000).rounded()
        guard value.isFinite, value >= 0, value < Double(Int.max) else { return nil }
        return Int(value)
    }
}
