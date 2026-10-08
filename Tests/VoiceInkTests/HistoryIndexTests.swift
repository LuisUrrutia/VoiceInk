import SQLite3
import SwiftData
import XCTest

@testable import VoiceInk

@MainActor
final class HistoryIndexTests: XCTestCase {
    func testHistoryIndexMatchesTheCompositeCursorOrder() throws {
        let schema = Schema([Transcription.self])

        let entity = try XCTUnwrap(schema.entities.first { $0.name == "Transcription" })

        XCTAssertEqual(entity.indices, [["binary", "timestamp", "id"]])
        XCTAssertTrue(entity.uniquenessConstraints.isEmpty)
    }

    func testUnindexedStoreMigratesAndReopensWithoutLosingHistory() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("default.store")
        let expectedIDs = (0..<65).sorted {
            $0 / 23 == $1 / 23 ? $0 > $1 : $0 < $1
        }.map { UUID(uuidString: String(format: "%08X-ABCD-4DEF-8123-%012X", $0, $0))! }
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "unindexed", withExtension: "store"))
        try FileManager.default.copyItem(at: fixture, to: storeURL)
        XCTAssertFalse(try hasPhysicalHistoryIndex(at: storeURL, immutable: true))

        for _ in 0..<2 {
            try await assertMigratedHistory(at: storeURL, expectedIDs: expectedIDs)
        }
    }

    private func assertMigratedHistory(at storeURL: URL, expectedIDs: [UUID]) async throws {
        let schema = Schema([Transcription.self])
        let configuration = ModelConfiguration("default", schema: schema, url: storeURL, cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: configuration)
        let context = ModelContext(container)
        let migrated = try context.fetch(FetchDescriptor<Transcription>())

        XCTAssertTrue(try hasPhysicalHistoryIndex(at: storeURL))
        XCTAssertEqual(migrated.count, 65)
        for record in migrated {
            let index = try XCTUnwrap(Int(record.id.uuidString.suffix(12), radix: 16))
            let hasMetadata = index % 2 != 0
            XCTAssertEqual(record.text, hasMetadata ? "Other text \(index)" : "Café original \(index)")
            XCTAssertEqual(record.enhancedText, hasMetadata ? "Enhanced café \(index)" : nil)
            XCTAssertEqual(record.timestamp, Date(timeIntervalSince1970: 1_700_000_000 - Double(index / 23)))
            XCTAssertEqual(record.duration, Double(index) + 0.5)
            XCTAssertEqual(record.audioFileURL, hasMetadata ? "file:///synthetic/\(index).wav" : nil)
            XCTAssertEqual(record.transcriptionModelName, hasMetadata ? "Speech \(index)" : nil)
            XCTAssertEqual(record.aiEnhancementModelName, hasMetadata ? "Enhancement \(index)" : nil)
            XCTAssertEqual(record.promptName, hasMetadata ? "Prompt \(index)" : nil)
            XCTAssertEqual(record.transcriptionDuration, hasMetadata ? Double(index) + 0.25 : nil)
            XCTAssertEqual(record.enhancementDuration, hasMetadata ? Double(index) + 0.75 : nil)
            XCTAssertEqual(record.aiRequestSystemMessage, hasMetadata ? "System \(index)" : nil)
            XCTAssertEqual(record.aiRequestUserMessage, hasMetadata ? "User \(index)" : nil)
            XCTAssertEqual(record.modeName, hasMetadata ? "Mode \(index)" : nil)
            XCTAssertEqual(record.modeEmoji, hasMetadata ? "🎙️" : nil)
            XCTAssertEqual(record.transcriptionStatus, index % 5 == 0 ? nil : ["pending", "completed", "failed", "canceled"][index % 4])
        }
        for query in ["", "CAFE"] {
            let pagination = HistoryPagination(context: context)
            pagination.activate(searchText: query)
            try await waitForLoad(pagination)
            var pageCounts = [pagination.transcriptions.count]
            for _ in 0..<4 where pagination.hasMoreContent {
                pagination.loadMore()
                try await waitForLoad(pagination)
                pageCounts.append(pagination.transcriptions.count)
            }

            XCTAssertEqual(pageCounts, [20, 40, 60, 65])
            XCTAssertEqual(pagination.transcriptions.map(\.id), expectedIDs)
            XCTAssertFalse(pagination.hasMoreContent)
        }
    }

    private func waitForLoad(_ pagination: HistoryPagination) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while pagination.isLoading, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertFalse(pagination.isLoading, "History load must finish")
        XCTAssertNil(pagination.loadingError)
    }

    private func hasPhysicalHistoryIndex(at storeURL: URL, immutable: Bool = false) throws -> Bool {
        // Inspect only this test's synthetic store to detect a schema-only index change.
        var database: OpaquePointer?
        let location = immutable ? storeURL.absoluteString + "?immutable=1" : storeURL.path
        let openResult = sqlite3_open_v2(location, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil)
        defer { sqlite3_close(database) }
        guard openResult == SQLITE_OK else {
            throw NSError(domain: "HistoryIndexTests.SQLite", code: Int(openResult), userInfo: [
                NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(database))
            ])
        }
        let query = """
            SELECT COUNT(*) FROM pragma_index_list('ZTRANSCRIPTION') AS indexes
            WHERE indexes."unique" = 0
                AND (SELECT COUNT(*) FROM pragma_index_info(indexes.name)) = 2
                AND EXISTS (SELECT 1 FROM pragma_index_info(indexes.name)
                    WHERE seqno = 0 AND name = 'ZTIMESTAMP')
                AND EXISTS (SELECT 1 FROM pragma_index_info(indexes.name)
                    WHERE seqno = 1 AND name = 'ZID')
            """
        var statement: OpaquePointer?
        let prepareResult = sqlite3_prepare_v2(database, query, -1, &statement, nil)
        defer { sqlite3_finalize(statement) }
        guard prepareResult == SQLITE_OK else {
            throw NSError(domain: "HistoryIndexTests.SQLite", code: Int(prepareResult))
        }
        let stepResult = sqlite3_step(statement)
        guard stepResult == SQLITE_ROW else {
            throw NSError(domain: "HistoryIndexTests.SQLite", code: Int(stepResult))
        }
        return sqlite3_column_int(statement, 0) > 0
    }
}
