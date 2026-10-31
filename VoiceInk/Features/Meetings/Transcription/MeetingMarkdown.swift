import Foundation

/// The Markdown transcript of a meeting, in Hex's layout, and its file in the user's folder.
enum MeetingMarkdown {
    static let maximumTitleLength = 80

    static func render(
        _ manifest: MeetingManifest, turns: [MeetingTranscriptEntry], summary: String? = nil,
        locale: Locale = .current, timeZone: TimeZone = .current
    ) -> String {
        var lines = ["# \(manifest.title)", ""]
        var date = Date.FormatStyle(date: .complete, time: .shortened, locale: locale)
        date.timeZone = timeZone
        lines.append("- **\(String(localized: "Date")):** \(manifest.createdAt.formatted(date))")
        lines.append("- **\(String(localized: "Duration")):** \(timestamp(manifest.duration))")
        if let provider = manifest.provider.flatMap(MeetingProviderName.displayName(for:)) {
            lines.append("- **\(String(localized: "App")):** \(provider)")
        }
        if let summary, !summary.isEmpty {
            lines += ["", "## \(String(localized: "Summary"))", "", summary]
        }
        lines += ["", "## \(String(localized: "Transcript"))", ""]
        if turns.isEmpty {
            lines.append("_\(String(localized: "No speech was transcribed."))_")
        } else {
            for turn in turns {
                lines += ["**\(turn.speaker.label)** · \(timestamp(turn.start))", turn.text, ""]
            }
            lines.removeLast()
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// `mm:ss`, or `h:mm:ss` from an hour.
    static func timestamp(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let (hours, minutes, secs) = (total / 3600, total / 60 % 60, total % 60)
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%02d:%02d", minutes, secs)
    }

    /// `YYYY-MM-DD HHMM <title>.md` with path characters replaced and the title shortened.
    static func fileName(for manifest: MeetingManifest, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: manifest.createdAt)
        let stamp = String(
            format: "%04d-%02d-%02d %02d%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0, parts.hour ?? 0,
            parts.minute ?? 0
        )
        var title = manifest.title.unicodeScalars.map { "/\\:*?\"<>|".unicodeScalars.contains($0) || $0.properties.generalCategory == .control ? "-" : String($0) }
            .joined().trimmingCharacters(in: .whitespacesAndNewlines)
        title = String(title.prefix(maximumTitleLength)).trimmingCharacters(in: .whitespaces)
        if title.isEmpty || title.hasPrefix(".") { title = String(localized: "Meeting") + title }
        return "\(stamp) \(title).md"
    }

    /// Writes atomically next to existing files without replacing one: ` (2)` through ` (100)` are tried.
    static func write(_ markdown: String, named fileName: String, in folder: URL) throws -> URL {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let base = (fileName as NSString).deletingPathExtension
        for attempt in 1...100 {
            let name = attempt == 1 ? fileName : "\(base) (\(attempt)).md"
            let url = folder.appendingPathComponent(name)
            guard !fileManager.fileExists(atPath: url.path) else { continue }
            let temporary = folder.appendingPathComponent(".\(UUID().uuidString).md.tmp")
            try Data(markdown.utf8).write(to: temporary, options: [.atomic])
            do {
                // Linking fails if a file appeared meanwhile, so an existing transcript is never replaced.
                try fileManager.linkItem(at: temporary, to: url)
                try? fileManager.removeItem(at: temporary)
                return url
            } catch CocoaError.fileWriteFileExists {
                try? fileManager.removeItem(at: temporary)
            } catch {
                try? fileManager.removeItem(at: temporary)
                throw error
            }
        }
        throw CocoaError(.fileWriteFileExists)
    }
}

/// Display names of meeting apps by their `MeetingManifest.provider` identifier.
enum MeetingProviderName {
    static func displayName(for id: String) -> String? {
        switch id {
        case "zoom": "Zoom"
        case "meet": "Google Meet"
        case "slack": "Slack"
        case "teams": "Microsoft Teams"
        case "facetime": "FaceTime"
        default: nil
        }
    }
}
