import Foundation

/// Fixes the size fields of a WAV whose writer never closed it, as after a crash or forced quit: everything
/// after the `data` chunk header is the audio that reached the disk.
enum MeetingWAVRepair {
    enum Failure: Error { case notWAV, noDataChunk }

    /// Returns whether the header changed.
    @discardableResult
    static func repair(_ url: URL) throws -> Bool {
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        let fileSize = try handle.seekToEnd()
        try handle.seek(toOffset: 0)
        guard fileSize >= 12, let header = try handle.read(upToCount: 12), header.count == 12,
            header.prefix(4) == Data("RIFF".utf8), header.suffix(4) == Data("WAVE".utf8)
        else { throw Failure.notWAV }

        var offset: UInt64 = 12
        while offset + 8 <= fileSize {
            try handle.seek(toOffset: offset)
            guard let chunk = try handle.read(upToCount: 8), chunk.count == 8 else { break }
            let identifier = chunk.prefix(4)
            let size = UInt64(chunk.suffix(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).littleEndian })
            if identifier == Data("data".utf8) {
                // PCM16 mono: whole two-byte frames only, within 32-bit WAV limits.
                let available = min((fileSize - offset - 8) & ~1, UInt64(UInt32.max - 36))
                let riff = UInt32(min(fileSize - 8, UInt64(UInt32.max)))
                guard size != available || riffSize(header) != riff else { return false }
                try write(UInt32(available), at: offset + 4, to: handle)
                try write(riff, at: 4, to: handle)
                return true
            }
            offset += 8 + size + (size & 1)
        }
        throw Failure.noDataChunk
    }

    private static func riffSize(_ header: Data) -> UInt32 {
        header.subdata(in: 4..<8).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).littleEndian }
    }

    private static func write(_ value: UInt32, at offset: UInt64, to handle: FileHandle) throws {
        try handle.seek(toOffset: offset)
        var littleEndian = value.littleEndian
        try handle.write(contentsOf: Data(bytes: &littleEndian, count: 4))
    }
}

/// How long recorded meeting audio is kept once its transcript exists.
enum MeetingAudioRetention: Int, CaseIterable, Sendable {
    case week = 7, month = 30, forever = 0

    static let key = "MeetingsAudioRetentionDays"
    static let `default` = MeetingAudioRetention.month

    var displayName: String {
        switch self {
        case .week: String(localized: "7 days")
        case .month: String(localized: "30 days")
        case .forever: String(localized: "Forever")
        }
    }

    static func current(in defaults: UserDefaults = .standard) -> MeetingAudioRetention {
        (defaults.object(forKey: key) as? Int).flatMap(MeetingAudioRetention.init(rawValue:)) ?? .default
    }

    /// Transcribed meetings older than the period; meetings still recording, failed, interrupted or untranscribed
    /// keep their audio so they can still be transcribed.
    func expired(_ meetings: [MeetingManifest], now: Date) -> [MeetingManifest] {
        guard self != .forever else { return [] }
        let cutoff = now.addingTimeInterval(-Double(rawValue) * 86_400)
        return meetings.filter { $0.status == .transcribed && $0.createdAt < cutoff }
    }
}
