import SwiftData
import XCTest

@testable import VoiceInk

@MainActor
final class HistoryPaginationTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!
    private var storeDirectory: URL!
    private let timestamp = Date(timeIntervalSince1970: 1_700_000_000)

    override func setUpWithError() throws {
        storeDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: storeDirectory, withIntermediateDirectories: true)
        let configuration = ModelConfiguration(
            url: storeDirectory.appendingPathComponent("history.store"), cloudKitDatabase: .none
        )
        container = try ModelContainer(for: Transcription.self, configurations: configuration)
        context = ModelContext(container)
        context.autosaveEnabled = false
    }

    override func tearDownWithError() throws {
        context = nil
        container = nil
        if let storeDirectory {
            try FileManager.default.removeItem(at: storeDirectory)
        }
    }

    func testIdenticalTimestampsSpanMoreThanTwoPagesExactlyOnce() throws {
        let records = (0..<65).map { record($0) }
        try save(records.reversed())
        var pagination = HistoryPagination()

        try pagination.reload(in: context, searchText: "")
        let pageCounts = try exhaust(&pagination)

        XCTAssertEqual(pageCounts, [20, 40, 60, 65])
        XCTAssertEqual(pagination.transcriptions.map(\.id), sortedIDs(records))
        XCTAssertEqual(Set(pagination.transcriptions.map(\.id)).count, records.count)
        XCTAssertFalse(pagination.hasMoreContent)
        try pagination.loadMore(in: context)
        XCTAssertEqual(pagination.transcriptions.count, 65)
    }

    func testMixedTimestampsKeepTiesAtMultipleBoundaries() throws {
        let records = (0..<67).map { index in
            record(index, timestamp: timestamp.addingTimeInterval(-Double(index / 23)))
        }
        try save(records.reversed())
        var pagination = HistoryPagination()

        try pagination.reload(in: context, searchText: "")
        _ = try exhaust(&pagination)

        XCTAssertEqual(pagination.transcriptions.map(\.id), sortedIDs(records))
        XCTAssertFalse(pagination.hasMoreContent)
    }

    func testEmptyFullPageAndOneExtraRowExhaustWithoutAnExtraEmptyPage() throws {
        var pagination = HistoryPagination()

        try pagination.reload(in: context, searchText: "")
        XCTAssertTrue(pagination.transcriptions.isEmpty)
        XCTAssertFalse(pagination.hasMoreContent)

        let records = (0..<20).map { record($0) }
        try save(records)
        try pagination.reload(in: context, searchText: "")
        XCTAssertEqual(pagination.transcriptions.map(\.id), sortedIDs(records))
        XCTAssertFalse(pagination.hasMoreContent)

        let extra = record(20)
        try save([extra])
        try pagination.reload(in: context, searchText: "")
        XCTAssertEqual(pagination.transcriptions.count, 20)
        XCTAssertTrue(pagination.hasMoreContent)
        try pagination.loadMore(in: context)
        XCTAssertEqual(pagination.transcriptions.map(\.id), sortedIDs(records + [extra]))
        XCTAssertFalse(pagination.hasMoreContent)
    }

    func testOriginalAndEnhancedSearchKeepEveryMatchingTie() throws {
        let original = (0..<45).map { record($0, text: "Original needle") }
        let enhanced = (45..<90).map { record($0, text: "Other text", enhancedText: "Enhanced needle") }
        let both = record(90, text: "Original needle", enhancedText: "Enhanced needle")
        let nonmatching = (91..<116).map { record($0, text: "Unrelated") }
        try save(original + enhanced + [both] + nonmatching)
        var pagination = HistoryPagination()

        try pagination.reload(in: context, searchText: "NEEDLE")
        _ = try exhaust(&pagination)

        XCTAssertEqual(pagination.transcriptions.map(\.id), sortedIDs(original + enhanced + [both]))
        XCTAssertEqual(pagination.transcriptions.count, 91)
    }

    func testChangingSearchAndReloadingResetAnAdvancedOrExhaustedCursor() throws {
        let first = (0..<45).map { record($0, text: "First query") }
        let second = (45..<70).map { record($0, text: "Second query") }
        try save(first + second)
        var pagination = HistoryPagination()
        try pagination.reload(in: context, searchText: "First")
        try pagination.loadMore(in: context)
        XCTAssertEqual(pagination.transcriptions.count, 40)

        try pagination.reload(in: context, searchText: "Second")
        _ = try exhaust(&pagination)

        XCTAssertEqual(pagination.transcriptions.map(\.id), sortedIDs(second))
        try pagination.reload(in: context, searchText: "Absent")
        XCTAssertTrue(pagination.transcriptions.isEmpty)
        XCTAssertFalse(pagination.hasMoreContent)
        try pagination.reload(in: context, searchText: "")
        XCTAssertEqual(pagination.transcriptions.map(\.id), Array(sortedIDs(first + second).prefix(20)))
        XCTAssertTrue(pagination.hasMoreContent)
    }

    func testDeletingTheBoundaryRecordDoesNotSkipRemainingTies() throws {
        let records = (0..<65).map { record($0) }
        try save(records)
        var pagination = HistoryPagination()
        try pagination.reload(in: context, searchText: "")
        let boundary = try XCTUnwrap(pagination.transcriptions.last)
        let displayedIDs = Set(pagination.transcriptions.map(\.id))

        context.delete(boundary)
        try context.save()
        _ = try exhaust(&pagination)

        XCTAssertEqual(pagination.transcriptions.map(\.id), sortedIDs(records))
        XCTAssertEqual(Set(pagination.transcriptions.dropFirst(20).map(\.id)), Set(records.map(\.id)).subtracting(displayedIDs))
        try pagination.reload(in: context, searchText: "")
        _ = try exhaust(&pagination)
        XCTAssertEqual(pagination.transcriptions.map(\.id), sortedIDs(records.filter { $0.id != boundary.id }))
    }

    func testReloadDropsDeletedResultsAndIncludesANewlyArrivingRecord() throws {
        let records = (0..<45).map { record($0) }
        try save(records)
        var pagination = HistoryPagination()
        try pagination.reload(in: context, searchText: "")
        try pagination.loadMore(in: context)
        let deleted = try XCTUnwrap(pagination.transcriptions.first)
        let arriving = record(100, timestamp: timestamp.addingTimeInterval(1))

        context.delete(deleted)
        try save([arriving])
        try pagination.reload(in: context, searchText: "")
        _ = try exhaust(&pagination)

        XCTAssertEqual(pagination.transcriptions.map(\.id), sortedIDs(records.filter { $0.id != deleted.id } + [arriving]))
        XCTAssertEqual(pagination.transcriptions.first?.id, arriving.id)
        XCTAssertFalse(pagination.transcriptions.contains { $0.id == deleted.id })
        XCTAssertEqual(Set(pagination.transcriptions.map(\.id)).count, 45)
    }

    func testQuickHistoryKeepsRecentLimitSearchAndPasteSelection() throws {
        let records = (0..<65).map { index in
            record(index, timestamp: timestamp.addingTimeInterval(Double(index)), text: "Original",
                   enhancedText: index % 2 == 0 ? "Enhanced match" : nil)
        }
        try save(records)
        let history = QuickHistoryViewModel(modelContext: context)
        XCTAssertEqual(history.transcriptions.map(\.id), Array(sortedIDs(records).prefix(30)))

        history.moveSelection(by: 1)
        let selected = try XCTUnwrap(history.selectedID)
        XCTAssertEqual(history.transcriptionForPaste()?.id, selected)
        XCTAssertEqual(history.keyboardSelectionID, selected)
        history.searchText = "match"
        let result = history.transcriptionForPaste()

        XCTAssertEqual(history.transcriptions.map(\.id), Array(sortedIDs(records.filter { $0.enhancedText != nil }).prefix(30)))
        XCTAssertEqual(result?.id, history.transcriptions.first?.id)
        XCTAssertEqual(history.transcriptionForPaste(preferredID: history.transcriptions[2].id)?.id, history.transcriptions[2].id)
        XCTAssertNil(history.transcriptionForPaste(preferredID: records[1].id))
    }

    func testReloadIncludesATimestampTieThatDoesNotReplaceTheNewestRow() throws {
        let records = (1...45).map { record($0) }
        try save(records)
        var pagination = HistoryPagination()
        try pagination.reload(in: context, searchText: "")
        _ = try exhaust(&pagination)
        let newestID = try XCTUnwrap(pagination.transcriptions.first?.id)
        let arriving = record(0)

        try save([arriving])
        try pagination.reload(in: context, searchText: "")
        _ = try exhaust(&pagination)

        XCTAssertEqual(pagination.transcriptions.first?.id, newestID)
        XCTAssertEqual(pagination.transcriptions.last?.id, arriving.id)
        XCTAssertEqual(pagination.transcriptions.map(\.id), sortedIDs(records + [arriving]))
    }

    private func record(_ index: Int, timestamp: Date? = nil, text: String = "History", enhancedText: String? = nil) -> Transcription {
        let transcription = Transcription(text: text, duration: 1, enhancedText: enhancedText)
        transcription.id = UUID(uuidString: String(format: "%08X-ABCD-4DEF-8123-%012X", UInt32(index) &* 2_654_435_761, index))!
        transcription.timestamp = timestamp ?? self.timestamp
        return transcription
    }

    private func save(_ records: some Sequence<Transcription>) throws {
        for transcription in records {
            context.insert(transcription)
        }
        try context.save()
    }

    private func sortedIDs(_ records: [Transcription]) -> [UUID] {
        records.sorted {
            $0.timestamp == $1.timestamp ? $0.id > $1.id : $0.timestamp > $1.timestamp
        }.map(\.id)
    }

    private func exhaust(_ pagination: inout HistoryPagination) throws -> [Int] {
        var pageCounts = [pagination.transcriptions.count]
        for _ in 0..<10 where pagination.hasMoreContent {
            let previousCount = pagination.transcriptions.count
            try pagination.loadMore(in: context)
            XCTAssertGreaterThan(pagination.transcriptions.count, previousCount)
            pageCounts.append(pagination.transcriptions.count)
        }
        XCTAssertFalse(pagination.hasMoreContent, "Pagination must eventually exhaust")
        return pageCounts
    }
}
