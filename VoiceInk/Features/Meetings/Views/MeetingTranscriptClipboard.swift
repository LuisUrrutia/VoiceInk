import AppKit

enum MeetingTranscriptClipboard {
    /// Copies the meeting's Markdown file as it is now, including the user's edits.
    @MainActor
    static func copy(_ meeting: MeetingManifest) {
        guard let path = meeting.transcriptPath, let markdown = try? String(contentsOfFile: path, encoding: .utf8) else {
            NotificationManager.shared.showNotification(title: String(localized: "The transcript file is missing."), type: .error)
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(markdown, forType: .string)
        NotificationManager.shared.showNotification(title: String(localized: "Meeting transcript copied"), type: .success)
    }
}
