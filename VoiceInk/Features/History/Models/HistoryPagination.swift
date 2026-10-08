import Foundation
import SwiftData

@MainActor
struct HistoryPagination {
    private struct Cursor {
        let timestamp: Date
        let id: UUID
    }

    private(set) var transcriptions: [Transcription] = []
    private(set) var hasMoreContent = true
    private var cursor: Cursor?
    private var searchText = ""
    private let pageSize = 20

    mutating func reload(in context: ModelContext, searchText: String) throws {
        transcriptions = []
        cursor = nil
        hasMoreContent = true
        self.searchText = searchText
        try loadNextPage(in: context)
    }

    mutating func loadMore(in context: ModelContext) throws {
        guard hasMoreContent, cursor != nil else { return }
        try loadNextPage(in: context)
    }

    private mutating func loadNextPage(in context: ModelContext) throws {
        let items = try context.fetch(cursorQueryDescriptor(after: cursor))
        let page = Array(items.prefix(pageSize))
        transcriptions.append(contentsOf: page)
        cursor = page.last.map { Cursor(timestamp: $0.timestamp, id: $0.id) }
        hasMoreContent = items.count > pageSize
    }

    private func cursorQueryDescriptor(after cursor: Cursor? = nil) -> FetchDescriptor<Transcription> {
        var descriptor = FetchDescriptor<Transcription>(
            sortBy: [
                SortDescriptor(\Transcription.timestamp, order: .reverse),
                SortDescriptor(\Transcription.id, order: .reverse)
            ]
        )

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

        // Fetch one extra row so the UI can determine whether another page exists.
        descriptor.fetchLimit = pageSize + 1

        return descriptor
    }
}
