import Foundation
import SwiftData

struct HistoryCursor: Sendable {
    let timestamp: Date
    let id: UUID
}

struct HistoryPage: Sendable {
    let identifiers: [PersistentIdentifier]
    let cursor: HistoryCursor?
    let hasMoreContent: Bool
}

struct HistoryPageQuery: Sendable {
    let searchText: String
    let cursor: HistoryCursor?
    static let pageSize = 20

    func load(from container: ModelContainer) async throws -> HistoryPage {
        let task = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let context = ModelContext(container)
            context.autosaveEnabled = false
            let items = try context.fetch(descriptor())
            try Task.checkCancellation()
            let page = Array(items.prefix(Self.pageSize))
            return HistoryPage(
                identifiers: page.map(\.persistentModelID),
                cursor: page.last.map { HistoryCursor(timestamp: $0.timestamp, id: $0.id) },
                hasMoreContent: items.count > Self.pageSize
            )
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    func descriptor() -> FetchDescriptor<Transcription> {
        var descriptor = FetchDescriptor<Transcription>(sortBy: [
            SortDescriptor(\Transcription.timestamp, order: .reverse),
            SortDescriptor(\Transcription.id, order: .reverse)
        ])
        if !searchText.isEmpty {
            let query = searchText
            if let cursor {
                let cursorTimestamp = cursor.timestamp
                let cursorID = cursor.id
                descriptor.predicate = #Predicate<Transcription> { transcription in
                    (transcription.text.localizedStandardContains(query)
                        || (transcription.enhancedText?.localizedStandardContains(query) ?? false))
                        && (transcription.timestamp < cursorTimestamp
                            || (transcription.timestamp == cursorTimestamp && transcription.id < cursorID))
                }
            } else {
                descriptor.predicate = #Predicate<Transcription> { transcription in
                    transcription.text.localizedStandardContains(query)
                        || (transcription.enhancedText?.localizedStandardContains(query) ?? false)
                }
            }
        } else if let cursor {
            let cursorTimestamp = cursor.timestamp
            let cursorID = cursor.id
            descriptor.predicate = #Predicate<Transcription> { transcription in
                transcription.timestamp < cursorTimestamp
                    || (transcription.timestamp == cursorTimestamp && transcription.id < cursorID)
            }
        }
        descriptor.fetchLimit = Self.pageSize + 1
        return descriptor
    }
}
