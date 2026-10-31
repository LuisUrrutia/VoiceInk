import Darwin
import SwiftData
import XCTest

@testable import VoiceInk

@MainActor
final class HistoryAccessTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!
    private var storeDirectory: URL!
    private var socketDirectory: URL!
    private let timestamp = Date(timeIntervalSince1970: 1_790_000_000)

    override func setUpWithError() throws {
        storeDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: storeDirectory, withIntermediateDirectories: true)
        let configuration = ModelConfiguration(
            url: storeDirectory.appendingPathComponent("history.store"), cloudKitDatabase: .none)
        container = try ModelContainer(for: Transcription.self, configurations: configuration)
        context = ModelContext(container)
        context.autosaveEnabled = false
        // sun_path allows 104 bytes, so sockets live in a short private directory.
        socketDirectory = URL(fileURLWithPath: "/tmp/viha-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(
            at: socketDirectory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }

    override func tearDownWithError() throws {
        context = nil
        container = nil
        try? FileManager.default.removeItem(at: storeDirectory)
        try? FileManager.default.removeItem(at: socketDirectory)
    }

    // MARK: - Queries

    func testPagesFollowHistoryOrderAcrossTiesExactlyOnce() async throws {
        let records = (0..<47).map { record($0, timestamp: timestamp.addingTimeInterval(-Double($0 / 15))) }
        try save(records.shuffled())
        let expected = try context.fetch(FetchDescriptor<Transcription>(sortBy: [
            SortDescriptor(\Transcription.timestamp, order: .reverse),
            SortDescriptor(\Transcription.id, order: .reverse),
        ])).map(\.id.uuidString)

        var pages: [[String]] = []
        var cursor: String?
        repeat {
            let response = await service.response(for: HistoryAccessRequest(command: .list, limit: 20, cursor: cursor))
            XCTAssertNil(response.error)
            pages.append(try XCTUnwrap(response.entries).map(\.id))
            XCTAssertEqual(response.truncated, response.nextCursor != nil)
            cursor = response.nextCursor
        } while cursor != nil

        XCTAssertEqual(pages.map(\.count), [20, 20, 7])
        XCTAssertEqual(pages.flatMap { $0 }, expected)
    }

    func testFullFinalPageReportsExhaustionWithoutAnotherCursor() async throws {
        try save((0..<20).map { record($0) })

        let response = await service.response(for: HistoryAccessRequest(command: .list, limit: 20))

        XCTAssertEqual(response.entries?.count, 20)
        XCTAssertEqual(response.truncated, false)
        XCTAssertNil(response.nextCursor)
    }

    func testSinceIsInclusiveAndUntilIsExclusive() async throws {
        let records = (0..<5).map { record($0, timestamp: timestamp.addingTimeInterval(Double($0) * 60)) }
        try save(records)

        let response = await service.response(for: HistoryAccessRequest(
            command: .list, sinceMilliseconds: milliseconds(records[1].timestamp),
            untilMilliseconds: milliseconds(records[3].timestamp)))

        XCTAssertEqual(response.entries?.map(\.id), [records[2], records[1]].map(\.id.uuidString))
    }

    func testSearchMatchesOriginalAndEnhancedTextAndOnlyCompletedEntries() async throws {
        let original = record(0, text: "Meet at the Café")
        let enhanced = record(1, text: "plain words", enhancedText: "Notes about the cafe menu")
        let legacy = record(2, text: "legacy cafe entry", status: nil)
        let pending = record(3, text: "cafe pending", status: .pending)
        let canceled = record(4, text: "cafe canceled", status: .canceled)
        let failed = record(5, text: "cafe failed", status: .failed)
        let unrelated = record(6, text: "nothing here")
        try save([original, enhanced, legacy, pending, canceled, failed, unrelated])

        let response = await service.response(for: HistoryAccessRequest(command: .search, query: "  CAFE "))

        XCTAssertEqual(
            Set(try XCTUnwrap(response.entries).map(\.id)),
            Set([original, enhanced, legacy].map(\.id.uuidString)))
    }

    func testShowReturnsEveryAgentFieldAndHidesEnhancementFailures() async throws {
        let entry = record(0, text: "raw words", enhancedText: "Polished words.")
        entry.duration = 4.2
        entry.modeName = "Email"
        entry.transcriptionModelName = "parakeet-tdt-0.6b-v3"
        entry.aiEnhancementModelName = "gpt-5"
        entry.promptName = "Default"
        entry.transcriptionDuration = 0.3104
        entry.enhancementDuration = 1.25
        entry.aiRequestUserMessage = "context that must not be exposed"
        let failedEnhancement = record(1, text: "kept text", enhancedText: "Enhancement failed: timeout")
        try save([entry, failedEnhancement])

        let shownResponse = await service.response(for: HistoryAccessRequest(command: .show, id: entry.id.uuidString))
        let failedResponse = await service.response(
            for: HistoryAccessRequest(command: .show, id: failedEnhancement.id.uuidString))
        let shown = try XCTUnwrap(shownResponse.entry)
        let failed = try XCTUnwrap(failedResponse.entry)
        let missing = await service.response(for: HistoryAccessRequest(command: .show, id: UUID().uuidString))

        XCTAssertEqual(shown, HistoryAccessEntry(
            id: entry.id.uuidString, timestamp: HistoryAccess.timestampString(entry.timestamp),
            originalText: "raw words", enhancedText: "Polished words.", mode: "Email",
            transcriptionModel: "parakeet-tdt-0.6b-v3", enhancementModel: "gpt-5", prompt: "Default",
            durationMilliseconds: 4_200, transcriptionDurationMilliseconds: 310, enhancementDurationMilliseconds: 1_250))
        XCTAssertNil(failed.enhancedText)
        XCTAssertEqual(failed.originalText, "kept text")
        XCTAssertEqual(missing.error?.code, .notFound)
        let encoded = String(decoding: HistoryAccessService.encode(.single(shown)), as: UTF8.self)
        XCTAssertFalse(encoded.contains("context that must not be exposed"))
    }

    func testInvalidRequestsAreRejectedWithoutReading() async throws {
        let cases: [(HistoryAccessRequest, HistoryAccessFailure.Code)] = [
            (HistoryAccessRequest(command: .list, version: 2), .unsupportedVersion),
            (HistoryAccessRequest(command: .list, limit: 0), .invalidRequest),
            (HistoryAccessRequest(command: .list, limit: 201), .invalidRequest),
            (HistoryAccessRequest(command: .list, cursor: "nope"), .invalidRequest),
            (HistoryAccessRequest(command: .list, sinceMilliseconds: 10, untilMilliseconds: 10), .invalidRequest),
            (HistoryAccessRequest(command: .search, query: " "), .invalidRequest),
            (HistoryAccessRequest(command: .search, query: String(repeating: "a", count: 1_001)), .invalidRequest),
            (HistoryAccessRequest(command: .show, id: "not-a-uuid"), .invalidRequest),
        ]
        for (request, code) in cases {
            let response = await service.response(for: request)
            XCTAssertEqual(response.error?.code, code, "\(request)")
            XCTAssertNil(response.entries)
        }
        let malformed = await service.respond(to: Data("{not json".utf8))
        XCTAssertEqual(try JSONDecoder().decode(HistoryAccessResponse.self, from: malformed).error?.code, .invalidRequest)
    }

    func testRequestsNeverModifyTheStore() async throws {
        let entry = record(0, text: "unchanged")
        try save([entry])
        let storeURL = storeDirectory.appendingPathComponent("history.store")
        let before = try FileManager.default.attributesOfItem(atPath: storeURL.path)[.modificationDate] as? Date

        _ = await service.response(for: HistoryAccessRequest(command: .list))
        _ = await service.response(for: HistoryAccessRequest(command: .search, query: "unchanged"))
        _ = await service.response(for: HistoryAccessRequest(command: .show, id: entry.id.uuidString))

        let after = try FileManager.default.attributesOfItem(atPath: storeURL.path)[.modificationDate] as? Date
        XCTAssertEqual(before, after)
    }

    // MARK: - Socket server

    func testSocketIsOwnerOnlyAndAnswersOneRequestPerConnection() async throws {
        let entry = record(0, text: "over the socket")
        try save([entry])
        let socketURL = socketDirectory.appendingPathComponent("h.sock")
        let server = HistoryAccessServer(socketURL: socketURL) { [service] in await service.respond(to: $0) }
        try server.start()

        var info = stat()
        XCTAssertEqual(lstat(socketURL.path, &info), 0)
        XCTAssertEqual(info.st_mode & S_IFMT, S_IFSOCK)
        XCTAssertEqual(info.st_mode & 0o777, 0o600)
        let request = try JSONEncoder().encode(HistoryAccessRequest(command: .show, id: entry.id.uuidString))
        let reply = try await exchange(socketURL.path, request + Data("\n".utf8))
        let response = try JSONDecoder().decode(HistoryAccessResponse.self, from: reply)
        XCTAssertEqual(response.entry?.originalText, "over the socket")

        let oversized = try await exchange(
            socketURL.path, Data(repeating: UInt8(ascii: "a"), count: HistoryAccess.maximumRequestBytes + 10))
        XCTAssertEqual(try JSONDecoder().decode(HistoryAccessResponse.self, from: oversized).error?.code, .invalidRequest)

        server.stop()
        XCTAssertNotEqual(lstat(socketURL.path, &info), 0)
    }

    func testServerRefusesUnsafeLocationsAndLiveSockets() throws {
        let socketURL = socketDirectory.appendingPathComponent("h.sock")
        let first = HistoryAccessServer(socketURL: socketURL) { $0 }
        try first.start()

        XCTAssertThrowsError(try HistoryAccessServer(socketURL: socketURL) { $0 }.start()) {
            XCTAssertEqual($0 as? HistoryAccessServer.StartError, .inUse)
        }
        first.stop()

        // A socket left by a crashed instance is replaced.
        let stale = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(socketURL.path.utf8)) }
        _ = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(stale, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        close(stale)
        let replacement = HistoryAccessServer(socketURL: socketURL) { $0 }
        XCTAssertNoThrow(try replacement.start())
        replacement.stop()

        try Data().write(to: socketURL)
        XCTAssertThrowsError(try HistoryAccessServer(socketURL: socketURL) { $0 }.start()) {
            XCTAssertEqual($0 as? HistoryAccessServer.StartError, .notASocket)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: socketURL.path))

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: socketDirectory.path)
        XCTAssertThrowsError(
            try HistoryAccessServer(socketURL: socketDirectory.appendingPathComponent("o.sock")) { $0 }.start()
        ) {
            XCTAssertEqual($0 as? HistoryAccessServer.StartError, .unsafeDirectory)
        }
    }

    func testStoppingRevokesAcceptedConnectionsAndPendingResults() async throws {
        let socketURL = socketDirectory.appendingPathComponent("r.sock")
        let (received, receivedContinuation) = AsyncStream<Void>.makeStream()
        let (released, releaseContinuation) = AsyncStream<Void>.makeStream()
        let server = HistoryAccessServer(socketURL: socketURL) { _ in
            receivedContinuation.yield()
            for await _ in released {}
            return Data("retained text".utf8)
        }
        try server.start()
        // accept() is FIFO, so a handled in-flight request proves the earlier partial connection was accepted.
        let partial = try Self.openConnection(socketURL.path)
        Self.write(Data("{\"version\":1,".utf8), to: partial)
        let inFlight = try Self.openConnection(socketURL.path)
        Self.write(Data("{\"version\":1,\"command\":\"list\"}\n".utf8), to: inFlight)
        for await _ in received { break }

        server.stop()
        releaseContinuation.finish()
        Self.write(Data("\"command\":\"list\"}\n".utf8), to: partial)

        let afterStop = await Self.readAll(partial)
        let pending = await Self.readAll(inFlight)
        XCTAssertEqual(afterStop, Data())
        XCTAssertEqual(pending, Data())
    }

    func testAConnectionAdmittedAfterStopIsClosedWithoutAnAnswer() async throws {
        let socketURL = socketDirectory.appendingPathComponent("a.sock")
        let gate = AcceptStageGate(pausing: .accepted)
        let server = HistoryAccessServer(socketURL: socketURL, acceptStage: gate.reach) { _ in Data("answered".utf8) }
        try server.start()
        let client = try Self.openConnection(socketURL.path)
        Self.write(Data("{\"version\":1,\"command\":\"list\"}\n".utf8), to: client)
        await gate.waitUntilPaused()

        server.stop()
        gate.resume()

        let reply = await Self.readAll(client)
        XCTAssertEqual(reply, Data())
    }

    func testAnOverCapacityConnectionGetsNoBusyAnswerAfterStop() async throws {
        let socketURL = socketDirectory.appendingPathComponent("b.sock")
        let gate = AcceptStageGate(pausing: .rejecting)
        let server = HistoryAccessServer(socketURL: socketURL, acceptStage: gate.reach) { _ in Data("answered".utf8) }
        try server.start()
        let admitted = try (0..<HistoryAccessServer.maximumConnections).map { _ in
            let connection = try Self.openConnection(socketURL.path)
            Self.write(Data("{".utf8), to: connection)
            return connection
        }
        let rejected = try Self.openConnection(socketURL.path)
        await gate.waitUntilPaused()

        server.stop()
        gate.resume()

        let reply = await Self.readAll(rejected)
        XCTAssertEqual(reply, Data())
        for connection in admitted {
            let partialReply = await Self.readAll(connection)
            XCTAssertEqual(partialReply, Data())
        }
    }

    func testIndeterminateProbeKeepsALiveSocketServing() async throws {
        let socketURL = socketDirectory.appendingPathComponent("p.sock")
        let live = HistoryAccessServer(socketURL: socketURL) { _ in Data("live".utf8) }
        try live.start()
        defer { live.stop() }

        XCTAssertEqual(HistoryAccessServer.probeSocket(socketURL.path), .live)
        XCTAssertThrowsError(
            try HistoryAccessServer(socketURL: socketURL, probe: { _ in .indeterminate(EMFILE) }) { $0 }.start()
        ) {
            XCTAssertEqual($0 as? HistoryAccessServer.StartError, .system(operation: "probe", code: EMFILE))
        }

        let reply = try await exchange(socketURL.path, Data("{}\n".utf8))
        XCTAssertEqual(reply, Data("live".utf8))
    }

    func testRequestsMustArriveBeforeTheDeadline() async throws {
        let socketURL = socketDirectory.appendingPathComponent("d.sock")
        let server = HistoryAccessServer(socketURL: socketURL, requestDeadline: 0.5) { _ in Data("answered".utf8) }
        try server.start()
        defer { server.stop() }
        let slow = try Self.openConnection(socketURL.path)

        for byte in Array("{\"version\":1}".utf8).prefix(4) {
            Self.write(Data([byte]), to: slow)
            try await Task.sleep(for: .milliseconds(200))
        }
        Self.write(Data("\n".utf8), to: slow)

        let reply = await Self.readAll(slow)
        XCTAssertEqual(reply, Data())
    }

    // MARK: - Opt-in

    func testAccessIsOffByDefaultAndFollowsTheMachineLocalPreference() throws {
        let suite = "HistoryAccessTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let socketURL = socketDirectory.appendingPathComponent("c.sock")
        let controller = HistoryAccessController(defaults: defaults, socketURL: socketURL)

        controller.configure(container: container)
        XCTAssertFalse(controller.isEnabled)
        XCTAssertEqual(controller.status, .off)
        XCTAssertFalse(FileManager.default.fileExists(atPath: socketURL.path))

        controller.setEnabled(true)
        XCTAssertEqual(controller.status, .serving(socketPath: socketURL.path))
        XCTAssertTrue(defaults.bool(forKey: HistoryAccessController.enabledKey))
        XCTAssertNil(try ConfigurationPreferences.capture(from: defaults)[HistoryAccessController.enabledKey])

        controller.setEnabled(false)
        XCTAssertEqual(controller.status, .off)
        XCTAssertFalse(FileManager.default.fileExists(atPath: socketURL.path))

        defaults.set(true, forKey: HistoryAccessController.enabledKey)
        let relaunched = HistoryAccessController(defaults: defaults, socketURL: socketURL)
        relaunched.configure(container: container)
        XCTAssertEqual(relaunched.status, .serving(socketPath: socketURL.path))
        relaunched.shutdown()
        XCTAssertFalse(FileManager.default.fileExists(atPath: socketURL.path))
    }

    // MARK: - Helpers

    private var service: HistoryAccessService { HistoryAccessService(container: container) }

    private func record(
        _ index: Int, timestamp: Date? = nil, text: String? = nil, enhancedText: String? = nil,
        status: TranscriptionStatus? = .completed
    ) -> Transcription {
        let transcription = Transcription(
            text: text ?? "Entry \(index)", duration: 1, enhancedText: enhancedText,
            transcriptionStatus: status ?? .completed)
        if status == nil { transcription.transcriptionStatus = nil }
        transcription.timestamp = timestamp ?? self.timestamp
        return transcription
    }

    private func save(_ records: [Transcription]) throws {
        for record in records { context.insert(record) }
        try context.save()
    }

    private func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }

    private nonisolated static func openConnection(_ path: String) throws -> Int32 {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(path.utf8)) }
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var enabled: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            close(descriptor)
            throw POSIXError(.ECONNREFUSED)
        }
        return descriptor
    }

    private nonisolated static func write(_ payload: Data, to descriptor: Int32) {
        payload.withUnsafeBytes { _ = Darwin.send(descriptor, $0.baseAddress!, $0.count, 0) }
    }

    /// Reads until the server closes the connection, then closes it.
    private nonisolated static func readAll(_ descriptor: Int32) async -> Data {
        await Task.detached {
            defer { close(descriptor) }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = recv(descriptor, &buffer, buffer.count, 0)
                guard count > 0 else { break }
                data.append(contentsOf: buffer[..<count])
            }
            return data
        }.value
    }

    private nonisolated func exchange(_ path: String, _ payload: Data) async throws -> Data {
        try await Task.detached {
            let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
            defer { close(descriptor) }
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(path.utf8)) }
            var timeout = timeval(tv_sec: 5, tv_usec: 0)
            setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            let connected = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard connected == 0 else { throw POSIXError(.ECONNREFUSED) }
            payload.withUnsafeBytes { _ = send(descriptor, $0.baseAddress!, $0.count, 0) }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = recv(descriptor, &buffer, buffer.count, 0)
                guard count > 0 else { break }
                data.append(contentsOf: buffer[..<count])
            }
            if data.last == UInt8(ascii: "\n") { data.removeLast() }
            return data
        }.value
    }
}

/// Holds the server's accept queue at one stage so a test can stop the server there.
private final class AcceptStageGate: @unchecked Sendable {
    private let stage: HistoryAccessServer.AcceptStage
    private let paused = DispatchSemaphore(value: 0)
    private let released = DispatchSemaphore(value: 0)

    init(pausing stage: HistoryAccessServer.AcceptStage) {
        self.stage = stage
    }

    func reach(_ reached: HistoryAccessServer.AcceptStage) {
        guard reached == stage else { return }
        paused.signal()
        released.wait()
    }

    func waitUntilPaused() async {
        await Task.detached { [paused] in paused.wait() }.value
    }

    func resume() {
        released.signal()
    }
}
