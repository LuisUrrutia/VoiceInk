import Foundation
import os

/// Owns `Meetings/<id>/` folders inside the build's isolated persistence directory: owner-only folders and
/// files, and atomically replaced manifests.
struct MeetingStore: Sendable {
    let rootURL: URL

    static let `default` = MeetingStore(rootURL: VoiceInkPersistence.directoryURL.appendingPathComponent("Meetings", isDirectory: true))

    private static let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "MeetingStore")

    func directory(for id: UUID) -> URL {
        rootURL.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    func audioURL(for id: UUID, track: MeetingManifest.TrackKind) -> URL {
        directory(for: id).appendingPathComponent(track.fileName)
    }

    func createDirectory(for id: UUID) throws -> URL {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let directory = directory(for: id)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return directory
    }

    func save(_ manifest: MeetingManifest) throws {
        let url = directory(for: manifest.id).appendingPathComponent(MeetingManifest.fileName)
        try JSONEncoder.meetingManifest.encode(manifest).write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    func load(id: UUID) throws -> MeetingManifest {
        let url = directory(for: id).appendingPathComponent(MeetingManifest.fileName)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(MeetingManifest.self, from: Data(contentsOf: url))
    }

    /// Every readable meeting, newest first; unreadable folders are skipped and logged.
    func loadAll() -> [MeetingManifest] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: rootURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return [] }
        return entries.compactMap { entry -> MeetingManifest? in
            guard let id = UUID(uuidString: entry.lastPathComponent) else { return nil }
            do {
                return try load(id: id)
            } catch {
                Self.logger.warning("Skipping unreadable meeting \(id.uuidString, privacy: .public): \(error, privacy: .public)")
                return nil
            }
        }
        .sorted { $0.createdAt > $1.createdAt }
    }

    func delete(id: UUID) throws {
        let directory = directory(for: id)
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        try FileManager.default.trashItem(at: directory, resultingItemURL: nil)
    }

    /// Owner-only permissions for an audio file the capture created.
    func protect(_ url: URL) {
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

extension JSONEncoder {
    static var meetingManifest: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}
