import Foundation
import SwiftData
import XCTest

@testable import VoiceInk

@MainActor
final class DashboardStatsLoaderTests: XCTestCase {
    func testPeriodBoundariesKeepTotalsModelSummariesAndActivity() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let windows = windows(at: "2026-10-08T13:00:00Z")
        let timestamps = [
            "2025-12-31T22:59:59Z", "2025-12-31T23:00:00Z",
            "2026-09-08T22:00:00Z", "2026-09-08T21:59:59Z",
            "2026-09-24T22:00:00Z", "2026-10-01T22:00:00Z",
            "2026-10-01T21:59:59Z", "2026-10-07T22:00:00Z",
            "2026-10-08T13:00:00Z", "2026-10-08T14:00:00Z",
        ]
        for (index, timestamp) in timestamps.enumerated() {
            let words = 1 << index
            context.insert(metric(at: date(timestamp), words: words, audio: Double(words * 2)))
        }
        try context.save()

        let summary = try await DashboardStatsLoader.load(from: container, windows: windows)

        XCTAssertEqual(summary.total, DashboardMetricTotals(count: 10, words: 1_023, duration: 2_046))
        XCTAssertEqual(summary.previousSevenDays, DashboardMetricTotals(count: 2, words: 80, duration: 160))
        assertPeriod(summary, period: .today, count: 2, words: 384)
        assertPeriod(summary, period: .lastSevenDays, count: 3, words: 416)
        assertPeriod(summary, period: .lastThirtyDays, count: 6, words: 500)
        assertPeriod(summary, period: .thisYear, count: 8, words: 510)
        assertPeriod(summary, period: .allTime, count: 10, words: 1_023)
        XCTAssertEqual(summary.todayProductivity.count, 24)
        XCTAssertEqual(summary.lastSevenDayProductivity.count, 7)
        XCTAssertEqual(summary.lastThirtyDayProductivity.count, 30)
        XCTAssertEqual(summary.thisYearProductivity.count, 10)
        XCTAssertEqual(summary.allTimeProductivity.count, 11)
        XCTAssertEqual(summary.thisYearDailyActivity.count, 281)
        XCTAssertEqual(summary.allTimeDailyActivity.count, 282)
        // Existing charts include future records in their day/hour buckets; period totals stop at now.
        XCTAssertEqual(summary.todayProductivity.map(\.words).reduce(0, +), 896)
        XCTAssertEqual(summary.lastSevenDayProductivity.map(\.words).reduce(0, +), 928)
        XCTAssertEqual(summary.lastThirtyDayProductivity.map(\.words).reduce(0, +), 1_012)
        XCTAssertEqual(summary.thisYearProductivity.map(\.words).reduce(0, +), 510)
        XCTAssertEqual(summary.thisYearDailyActivity.map(\.words).reduce(0, +), 510)
        XCTAssertEqual(summary.allTimeProductivity.map(\.words).reduce(0, +), 1_023)
        XCTAssertEqual(summary.allTimeDailyActivity.map(\.words).reduce(0, +), 1_023)
        XCTAssertEqual(summary.allTimePeakHours.startHour, 15)
        XCTAssertEqual(summary.allTimePeakHours.endHour, 17)
        XCTAssertEqual(summary.allTimePeakHours.wordCount, 768)
        XCTAssertEqual(summary.allTimePeakHours.sessionCount, 2)
        XCTAssertEqual(summary.allTimePeakHours.hourlyActivity[0].activeDayCount, 5)
        XCTAssertEqual(summary.todayPeakHours.startHour, 14)
        XCTAssertEqual(summary.todayPeakHours.wordCount, 256)
        XCTAssertEqual(try JSONDecoder().decode(DashboardStatsSummary.self, from: JSONEncoder().encode(summary)), summary)
    }

    func testMissingNamesNonpositiveDurationsTokensAndModelOrdering() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let windows = windows(at: "2026-10-08T13:00:00Z")
        let records = [
            metric(at: windows.now, audio: 10, transcription: " \n", enhancement: " ", tokens: 200),
            metric(at: windows.now, audio: 5, transcription: " A ", processing: 0, enhancement: "X", enhancementTime: 0, tokens: nil),
            metric(at: windows.now, audio: -3, transcription: "A", processing: 2, enhancement: "X", enhancementTime: 3, tokens: -12),
            metric(at: windows.now, audio: 10, transcription: "B", processing: 1, enhancement: " Y ", enhancementTime: 1, tokens: 20),
            metric(at: windows.now, audio: 0, transcription: nil, processing: nil, enhancement: nil, enhancementTime: nil),
        ]
        for record in records { context.insert(record) }
        try context.save()

        let summary = try await DashboardStatsLoader.load(from: container, windows: windows)

        XCTAssertEqual(summary.totalDuration, 22)
        XCTAssertEqual(summary.allTimeModelPerformance, [
            ModelPerformanceSummary(kind: .transcription, name: "A", sessionCount: 1, averageProcessingDuration: 2),
            ModelPerformanceSummary(kind: .transcription, name: "B", sessionCount: 1, averageProcessingDuration: 1, averageSpeedFactor: 10),
            ModelPerformanceSummary(kind: .enhancement, name: "X", sessionCount: 1, averageProcessingDuration: 3),
            ModelPerformanceSummary(kind: .enhancement, name: "Y", sessionCount: 1, averageProcessingDuration: 1),
        ])
        XCTAssertEqual(summary.allTimeModelUsage, ModelUsageSummary(
            transcriptionModels: [
                TranscriptionModelUsage(name: "B", sessionCount: 1, totalAudioDuration: 10),
                TranscriptionModelUsage(name: "A", sessionCount: 1, totalAudioDuration: 5),
            ],
            enhancementModels: [
                EnhancementTokenUsage(name: "Y", sessionCount: 1, estimatedTokens: 20),
                EnhancementTokenUsage(name: "X", sessionCount: 2, estimatedTokens: 0),
            ]
        ))
    }

    func testReloadIncludesArrivalsBackfilledValuesAndDeletions() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let windows = windows(at: "2026-10-08T13:00:00Z")
        let first = metric(at: windows.now, words: 10, tokens: nil)
        context.insert(first)
        try context.save()
        let initial = try await DashboardStatsLoader.load(from: container, windows: windows)

        first.enhancementEstimatedTokenCount = 40
        first.wordCount = 20
        context.insert(metric(at: windows.now.addingTimeInterval(-86_400), words: 30, tokens: 50))
        try context.save()
        let updated = try await DashboardStatsLoader.load(from: container, windows: windows)
        context.delete(first)
        try context.save()
        let deleted = try await DashboardStatsLoader.load(from: container, windows: windows)
        try context.delete(model: SessionMetric.self)
        try context.save()
        let empty = try await DashboardStatsLoader.load(from: container, windows: windows)

        XCTAssertEqual(initial.totalWords, 10)
        XCTAssertEqual(initial.allTimeModelUsage.enhancementModels.first?.estimatedTokens, 0)
        XCTAssertEqual(updated.totalCount, 2)
        XCTAssertEqual(updated.totalWords, 50)
        XCTAssertEqual(updated.allTimeModelUsage.enhancementModels.first?.estimatedTokens, 90)
        XCTAssertEqual(deleted.totalCount, 1)
        XCTAssertEqual(deleted.totalWords, 30)
        XCTAssertEqual(deleted.todayCount, 0)
        XCTAssertEqual(deleted.allTimeModelUsage.enhancementModels.first?.estimatedTokens, 50)
        XCTAssertEqual(empty.totalCount, 0)
        XCTAssertTrue(empty.allTimeProductivity.isEmpty)
        XCTAssertTrue(empty.allTimeDailyActivity.isEmpty)
        XCTAssertTrue(empty.allTimeModelPerformance.isEmpty)
        XCTAssertEqual(empty.allTimeModelUsage, .empty)
        XCTAssertEqual(empty.allTimePeakHours, .empty)
        XCTAssertEqual(empty.todayProductivity.count, 24)
    }

    func testCalendarTimeZoneAndDayChangesRebucketWithoutReuse() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        context.insert(metric(at: date("2026-03-29T00:30:00Z"), words: 10))
        context.insert(metric(at: date("2026-03-29T01:30:00Z"), words: 20))
        try context.save()
        let madrid = windows(at: "2026-03-29T12:00:00Z")
        var losAngeles = madrid.calendar
        losAngeles.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        var hebrew = Calendar(identifier: .hebrew)
        hebrew.timeZone = madrid.calendar.timeZone

        let original = try await DashboardStatsLoader.load(from: container, windows: madrid)
        let shifted = try await DashboardStatsLoader.load(from: container, windows: DashboardPeriodWindows(now: madrid.now, calendar: losAngeles))
        let nextDay = try await DashboardStatsLoader.load(from: container, windows: windows(at: "2026-03-30T12:00:00Z"))
        let changedCalendar = try await DashboardStatsLoader.load(from: container, windows: DashboardPeriodWindows(now: madrid.now, calendar: hebrew))

        XCTAssertEqual(original.todayWords, 30)
        XCTAssertEqual(original.todayPeakHours.hourlyActivity[1].wordCount, 10)
        XCTAssertEqual(original.todayPeakHours.hourlyActivity[2].wordCount, 0)
        XCTAssertEqual(original.todayPeakHours.hourlyActivity[3].wordCount, 20)
        XCTAssertEqual(original.todayProductivity.map(\.words).reduce(0, +), 30)
        XCTAssertEqual(shifted.todayWords, 0)
        XCTAssertEqual(shifted.lastSevenDayProductivity.last?.words, 0)
        XCTAssertEqual(shifted.lastSevenDayProductivity.dropLast().last?.words, 30)
        XCTAssertEqual(nextDay.todayWords, 0)
        XCTAssertEqual(nextDay.recentSevenDayWords, 30)
        XCTAssertEqual(changedCalendar.total, original.total)
        XCTAssertEqual(changedCalendar.thisYearWords, 30)
        XCTAssertNotEqual(changedCalendar.thisYearDailyActivity.first?.date, original.thisYearDailyActivity.first?.date)
        XCTAssertEqual(changedCalendar.allTimeDailyActivity.map(\.words).reduce(0, +), 30)
    }

    func testTimestampTiesAcrossBatchesAndCancellation() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let windows = windows(at: "2026-10-08T13:00:00Z")
        for index in 0..<10_003 {
            context.insert(metric(at: windows.now, words: index % 5, audio: 1, tokens: 3))
            if index % 1_000 == 999 { try context.save() }
        }
        try context.save()

        let cancelled = Task { try await DashboardStatsLoader.load(from: container, windows: windows) }
        cancelled.cancel()
        do {
            _ = try await cancelled.value
            XCTFail("A cancelled reconstruction must not return a summary")
        } catch is CancellationError {
        }
        let summary = try await DashboardStatsLoader.load(from: container, windows: windows)

        XCTAssertEqual(summary.totalCount, 10_003)
        XCTAssertEqual(summary.totalWords, 20_003)
        XCTAssertEqual(summary.totalDuration, 10_003)
        XCTAssertEqual(summary.todayCount, 10_003)
        XCTAssertEqual(summary.todayModelUsage.transcriptionModels.first?.sessionCount, 10_003)
        XCTAssertEqual(summary.todayModelUsage.enhancementModels.first?.estimatedTokens, 30_009)
        XCTAssertEqual(summary.todayPeakHours.hourlyActivity[15].sessionCount, 10_003)
        XCTAssertEqual(summary.todayPeakHours.hourlyActivity[15].activeDayCount, 1)
    }

    func testSnapshotEnvironmentAndDashboardDayValidationRemainCompatible() {
        let now = date("2026-10-08T13:00:00Z")
        let calendar = windows(at: "2026-10-08T13:00:00Z").calendar
        let metadata = DashboardStatsSnapshotStore.Metadata(
            version: 2, generatedAt: now, metricCount: 10,
            localeIdentifier: Locale.current.identifier, timeZoneIdentifier: TimeZone.current.identifier
        )
        let otherLocale = DashboardStatsSnapshotStore.Metadata(
            version: 2, generatedAt: now, metricCount: 10,
            localeIdentifier: "other-locale", timeZoneIdentifier: TimeZone.current.identifier
        )
        let otherTimeZone = DashboardStatsSnapshotStore.Metadata(
            version: 2, generatedAt: now, metricCount: 10,
            localeIdentifier: Locale.current.identifier, timeZoneIdentifier: "other-time-zone"
        )

        XCTAssertTrue(metadata.matchesCurrentEnvironment)
        XCTAssertFalse(otherLocale.matchesCurrentEnvironment)
        XCTAssertFalse(otherTimeZone.matchesCurrentEnvironment)
        XCTAssertTrue(metadata.wasGeneratedInCurrentDashboardDay(now: now, calendar: calendar))
        XCTAssertFalse(metadata.wasGeneratedInCurrentDashboardDay(now: date("2026-10-08T22:00:00Z"), calendar: calendar))
    }

    private func assertPeriod(
        _ summary: DashboardStatsSummary,
        period: DashboardInsightPeriod,
        count: Int,
        words: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let duration = Double(words * 2)
        XCTAssertEqual(summary.totals(for: period), DashboardMetricTotals(count: count, words: words, duration: duration), file: file, line: line)
        XCTAssertEqual(summary.modelPerformance(for: period), [
            ModelPerformanceSummary(kind: .transcription, name: "Parakeet", sessionCount: count, averageProcessingDuration: 0.5, averageSpeedFactor: duration / (Double(count) * 0.5)),
            ModelPerformanceSummary(kind: .enhancement, name: "Refine", sessionCount: count, averageProcessingDuration: 0.25),
        ], file: file, line: line)
        XCTAssertEqual(summary.modelUsage(for: period), ModelUsageSummary(
            transcriptionModels: [TranscriptionModelUsage(name: "Parakeet", sessionCount: count, totalAudioDuration: duration)],
            enhancementModels: [EnhancementTokenUsage(name: "Refine", sessionCount: count, estimatedTokens: count * 10)]
        ), file: file, line: line)
        let activity = summary.peakHours(for: period).hourlyActivity
        XCTAssertEqual(activity.map(\.wordCount).reduce(0, +), words, file: file, line: line)
        XCTAssertEqual(activity.map(\.sessionCount).reduce(0, +), count, file: file, line: line)
        XCTAssertEqual(activity.map(\.audioDuration).reduce(0, +), duration, file: file, line: line)
    }

    private func makeContainer() throws -> ModelContainer {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        return try ModelContainer(for: SessionMetric.self, configurations: ModelConfiguration(url: directory.appendingPathComponent("metrics.store"), cloudKitDatabase: .none))
    }

    private func windows(at timestamp: String) -> DashboardPeriodWindows {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Madrid")!
        calendar.firstWeekday = 2
        return DashboardPeriodWindows(now: date(timestamp), calendar: calendar)
    }

    private func date(_ timestamp: String) -> Date {
        ISO8601DateFormatter().date(from: timestamp)!
    }

    private func metric(
        at timestamp: Date,
        words: Int = 10,
        audio: TimeInterval = 2,
        transcription: String? = " Parakeet\n",
        processing: TimeInterval? = 0.5,
        enhancement: String? = " Refine ",
        enhancementTime: TimeInterval? = 0.25,
        tokens: Int? = 10
    ) -> SessionMetric {
        SessionMetric(
            transcriptionId: UUID(), timestamp: timestamp, wordCount: words,
            audioDuration: audio, transcriptionModelName: transcription,
            transcriptionDuration: processing, speedFactor: 999, modeName: nil,
            aiEnhancementModelName: enhancement, enhancementDuration: enhancementTime,
            enhancementEstimatedTokenCount: tokens
        )
    }
}
