import SwiftData
import XCTest

@testable import VoiceInk

@MainActor
final class HistorySearchLifecycleTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        container = try ModelContainer(for: Transcription.self, configurations:
            ModelConfiguration(url: directory.appendingPathComponent("history.store"), cloudKitDatabase: .none))
        context = ModelContext(container)
        context.autosaveEnabled = false
    }

    override func tearDownWithError() throws {
        context = nil
        container = nil
        try FileManager.default.removeItem(at: directory)
    }

    func testRapidReplacementKeepsOnlyLatestPendingQueryAndRejectsOldCompletion() async throws {
        let old = try save("Old")
        let latest = try save("Latest")
        let loader = ControlledHistoryLoader()
        let history = HistoryPagination(context: context, load: loader.load)
        history.activate(searchText: "Old")
        try await waitForRequests(1, loader: loader)

        history.reload(searchText: "Intermediate")
        history.reload(searchText: "Latest")
        XCTAssertTrue(history.transcriptions.isEmpty)
        XCTAssertTrue(history.isLoading)
        let initialRequests = await loader.queries
        XCTAssertEqual(initialRequests.map(\.searchText), ["Old"])
        await loader.finish(with: page([old]))
        try await waitForRequests(2, loader: loader)

        XCTAssertTrue(history.transcriptions.isEmpty)
        let requests = await loader.queries
        XCTAssertEqual(requests.map(\.searchText), ["Old", "Latest"])
        await loader.finish(with: page([latest]))
        try await waitForIdle(history)
        XCTAssertEqual(history.transcriptions.map(\.id), [latest.id])
    }

    func testQueryChangeRejectsAnInFlightLoadMoreAndResetsItsCursor() async throws {
        let first = try save("First")
        let next = try save("Next")
        let replacement = try save("Replacement")
        let loader = ControlledHistoryLoader()
        let history = HistoryPagination(context: context, load: loader.load)
        history.activate(searchText: "")
        try await waitForRequests(1, loader: loader)
        await loader.finish(with: page([first], hasMore: true))
        try await waitForIdle(history)
        history.loadMore()
        history.loadMore()
        try await waitForRequests(2, loader: loader)

        history.reload(searchText: "Replacement")
        await loader.finish(with: page([next]))
        try await waitForRequests(3, loader: loader)
        XCTAssertTrue(history.transcriptions.isEmpty)
        let requests = await loader.queries
        XCTAssertEqual(requests[1].cursor?.id, first.id)
        XCTAssertNil(requests[2].cursor)
        await loader.finish(with: page([replacement]))
        try await waitForIdle(history)
        XCTAssertEqual(history.transcriptions.map(\.id), [replacement.id])
        XCTAssertFalse(history.hasMoreContent)
    }

    func testReloadOfSameQueryRejectsResultsFromBeforeStoreChange() async throws {
        let deleted = try save("Needle")
        let loader = ControlledHistoryLoader()
        let history = HistoryPagination(context: context, load: loader.load)
        history.activate(searchText: "Needle")
        try await waitForRequests(1, loader: loader)
        let obsoletePage = page([deleted])

        context.delete(deleted)
        let arriving = try save("Needle arriving")
        history.reload(searchText: "Needle")
        await loader.finish(with: obsoletePage)
        try await waitForRequests(2, loader: loader)
        XCTAssertTrue(history.transcriptions.isEmpty)
        await loader.finish(with: page([arriving]))
        try await waitForIdle(history)
        XCTAssertEqual(history.transcriptions.map(\.id), [arriving.id])
    }

    func testSuspendDiscardsPendingWorkAndReactivationRejectsEarlierResults() async throws {
        let old = try save("Old")
        let latest = try save("Latest")
        let loader = ControlledHistoryLoader()
        let history = HistoryPagination(context: context, load: loader.load)
        history.activate(searchText: "Old")
        try await waitForRequests(1, loader: loader)
        history.reload(searchText: "Discarded")

        history.suspend()
        history.reload(searchText: "Invisible")
        XCTAssertFalse(history.isLoading)
        history.activate(searchText: "Latest")
        await loader.finish(with: page([old]))
        try await waitForRequests(2, loader: loader)
        XCTAssertTrue(history.transcriptions.isEmpty)
        let requests = await loader.queries
        XCTAssertEqual(requests.map(\.searchText), ["Old", "Latest"])
        await loader.finish(with: page([latest]))
        try await waitForIdle(history)
        XCTAssertEqual(history.transcriptions.map(\.id), [latest.id])
    }

    func testOwnerIsReleasedDuringLoadAndCancelsItsTask() async throws {
        let loader = ControlledHistoryLoader()
        var history: HistoryPagination? = HistoryPagination(context: context, load: loader.load)
        weak var owner = history
        history?.activate(searchText: "")
        try await waitForRequests(1, loader: loader)

        history = nil
        XCTAssertNil(owner)
        await loader.finish(with: page([]))
        let deadline = ContinuousClock.now + .seconds(5)
        while await loader.completedCancellation == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        let canceled = await loader.completedCancellation
        XCTAssertEqual(canceled, true)
    }

    func testDeletedIdentifierIsNotRehydratedAsAFaultAndPageOrderIsPreserved() async throws {
        let first = try save("First")
        let removed = try save("Removed")
        let last = try save("Last")
        let loader = ControlledHistoryLoader()
        let history = HistoryPagination(context: context, load: loader.load)
        history.activate(searchText: "")
        try await waitForRequests(1, loader: loader)
        let fetchedPage = page([first, removed, last])

        context.delete(removed)
        try context.save()
        await loader.finish(with: fetchedPage)
        try await waitForIdle(history)

        XCTAssertEqual(history.transcriptions.map(\.id), [first.id, last.id])
        XCTAssertEqual(history.transcriptions.map(\.text), ["First", "Last"])
        XCTAssertTrue(history.transcriptions.allSatisfy { $0.modelContext === context })
    }

    func testFailureFinishesLoadingAndAllowsRetry() async throws {
        let record = try save("Recovered")
        let loader = ControlledHistoryLoader()
        let history = HistoryPagination(context: context, load: loader.load)
        history.activate(searchText: "")
        try await waitForRequests(1, loader: loader)

        await loader.fail()
        try await waitForIdle(history)
        XCTAssertNotNil(history.loadingError)
        XCTAssertFalse(history.hasMoreContent)
        history.reload(searchText: "")
        try await waitForRequests(2, loader: loader)
        await loader.finish(with: page([record]))
        try await waitForIdle(history)
        XCTAssertNil(history.loadingError)
        XCTAssertEqual(history.transcriptions.map(\.id), [record.id])
    }

    func testBackgroundSearchPreservesLocalizedOriginalAndEnhancedSubstringMatching() async throws {
        let original = try save("A Café visit")
        let enhanced = try save("Other", enhancedText: "A CAFÉ visit")
        _ = try save("Unrelated")
        let history = HistoryPagination(context: context)

        history.activate(searchText: "cafe")
        try await waitForIdle(history)

        XCTAssertEqual(Set(history.transcriptions.map(\.id)), [original.id, enhanced.id])
        XCTAssertNil(history.loadingError)
        history.reload(searchText: "no-match")
        try await waitForIdle(history)
        XCTAssertTrue(history.transcriptions.isEmpty)
        XCTAssertFalse(history.hasMoreContent)
        history.reload(searchText: "")
        try await waitForIdle(history)
        XCTAssertEqual(history.transcriptions.count, 3)
    }

    func testReloadFindsCompletedTextWithoutChangingTheNewestRecordIdentity() async throws {
        let record = try save("Pending")
        let history = HistoryPagination(context: context)
        history.activate(searchText: "Completed")
        try await waitForIdle(history)
        XCTAssertTrue(history.transcriptions.isEmpty)

        record.text = "Completed text"
        try context.save()
        history.reload(searchText: "Completed")
        try await waitForIdle(history)

        XCTAssertEqual(history.transcriptions.map(\.id), [record.id])
        XCTAssertEqual(history.transcriptions.first?.text, "Completed text")
    }

    func testSuspendedOwnerDoesNotPublishOrStartPendingQueries() async throws {
        let record = try save("Hidden")
        let loader = ControlledHistoryLoader()
        let history = HistoryPagination(context: context, load: loader.load)
        history.activate(searchText: "Hidden")
        try await waitForRequests(1, loader: loader)

        history.reload(searchText: "Discarded")
        history.suspend()
        await loader.finish(with: page([record]))
        try await Task.sleep(for: .milliseconds(10))

        let requests = await loader.queries
        XCTAssertEqual(requests.count, 1)
        XCTAssertTrue(history.transcriptions.isEmpty)
        XCTAssertFalse(history.isLoading)
    }

    private func save(_ text: String, enhancedText: String? = nil) throws -> Transcription {
        let record = Transcription(text: text, duration: 1, enhancedText: enhancedText)
        context.insert(record)
        try context.save()
        return record
    }

    private func page(_ records: [Transcription], hasMore: Bool = false) -> HistoryPage {
        HistoryPage(identifiers: records.map(\.persistentModelID),
                    cursor: records.last.map { HistoryCursor(timestamp: $0.timestamp, id: $0.id) },
                    hasMoreContent: hasMore)
    }

    private func waitForRequests(_ count: Int, loader: ControlledHistoryLoader) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while await loader.queries.count < count, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        let actual = await loader.queries.count
        XCTAssertEqual(actual, count)
    }

    private func waitForIdle(_ history: HistoryPagination) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while history.isLoading, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertFalse(history.isLoading)
    }
}

private actor ControlledHistoryLoader {
    private(set) var queries: [HistoryPageQuery] = []
    private(set) var completedCancellation: Bool?
    private var continuation: CheckedContinuation<HistoryPage, Error>?

    func load(_ query: HistoryPageQuery) async throws -> HistoryPage {
        queries.append(query)
        let page = try await withCheckedThrowingContinuation { continuation = $0 }
        completedCancellation = Task.isCancelled
        return page
    }

    func finish(with page: HistoryPage) {
        let pending = continuation
        continuation = nil
        pending?.resume(returning: page)
    }

    func fail() {
        let pending = continuation
        continuation = nil
        pending?.resume(throwing: CocoaError(.fileReadUnknown))
    }
}
