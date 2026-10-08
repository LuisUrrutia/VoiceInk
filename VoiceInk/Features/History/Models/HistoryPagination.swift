import Foundation
import Observation
import SwiftData

@MainActor
@Observable
final class HistoryPagination {
    typealias Loader = @Sendable (HistoryPageQuery) async throws -> HistoryPage

    private(set) var transcriptions: [Transcription] = []
    private(set) var hasMoreContent = true
    private(set) var isLoading = false
    private(set) var loadingError: Error?
    @ObservationIgnored private let context: ModelContext
    @ObservationIgnored private let load: Loader
    @ObservationIgnored private var cursor: HistoryCursor?
    @ObservationIgnored private var searchText = ""
    @ObservationIgnored private var revision = 0
    @ObservationIgnored private var isActive = false
    @ObservationIgnored private var pending: (query: HistoryPageQuery, revision: Int)?
    @ObservationIgnored private var task: Task<Void, Never>?

    init(context: ModelContext, load: Loader? = nil) {
        self.context = context
        let container = context.container
        self.load = load ?? { try await $0.load(from: container) }
    }

    deinit { task?.cancel() }

    func activate(searchText: String) {
        isActive = true
        reload(searchText: searchText)
    }

    func suspend() {
        isActive = false
        revision += 1
        pending = nil
        task?.cancel()
        isLoading = false
    }

    func reload(searchText: String) {
        guard isActive else { return }
        revision += 1
        loadingError = nil
        self.searchText = searchText
        transcriptions = []
        cursor = nil
        hasMoreContent = true
        pending = (HistoryPageQuery(searchText: searchText, cursor: nil), revision)
        isLoading = true
        task?.cancel()
        startPendingQuery()
    }

    func loadMore() {
        guard isActive, !isLoading, hasMoreContent, let cursor else { return }
        revision += 1
        loadingError = nil
        pending = (HistoryPageQuery(searchText: searchText, cursor: cursor), revision)
        isLoading = true
        startPendingQuery()
    }

    private func startPendingQuery() {
        // A synchronous store fetch cannot be interrupted; retain only the latest pending request.
        guard task == nil, let request = pending else { return }
        pending = nil
        let load = load
        task = Task { [weak self] in
            let result: Result<HistoryPage, Error>
            do { result = .success(try await load(request.query)) }
            catch { result = .failure(error) }
            self?.complete(result, revision: request.revision)
        }
    }

    private func complete(_ result: Result<HistoryPage, Error>, revision: Int) {
        task = nil
        if isActive, revision == self.revision {
            do {
                let page = try result.get()
                let identifiers = page.identifiers
                let records: [Transcription]
                if identifiers.isEmpty {
                    records = []
                } else {
                    let descriptor = FetchDescriptor<Transcription>(predicate: #Predicate {
                        identifiers.contains($0.persistentModelID)
                    })
                    records = try context.fetch(descriptor)
                }
                let byID = Dictionary(uniqueKeysWithValues: records.map { ($0.persistentModelID, $0) })
                transcriptions.append(contentsOf: identifiers.compactMap { byID[$0] })
                cursor = page.cursor
                hasMoreContent = page.hasMoreContent
            } catch {
                loadingError = error
                if cursor == nil { hasMoreContent = false }
                print("Error loading history: \(error)")
            }
            isLoading = false
        }
        startPendingQuery()
    }
}
