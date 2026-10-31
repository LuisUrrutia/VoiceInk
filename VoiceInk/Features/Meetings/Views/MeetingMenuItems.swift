import SwiftUI

/// Record and Stop in the menu bar while Meetings is on in Labs.
struct MeetingMenuItems: View {
    @ObservedObject private var recorder = MeetingRecorder.shared
    @AppStorage(LabsFeature.meetings.defaultsKey) private var isEnabled = false

    var body: some View {
        if isEnabled {
            Divider()
            if let meeting = recorder.activeMeeting {
                Text(String(format: String(localized: "Recording · %@"), meeting.title))
                Button("Stop & Transcribe Meeting") { Task { _ = await recorder.stop() } }
                    .disabled(recorder.isStopping)
            } else {
                Button("Record Meeting") { Task { await recorder.toggle() } }
                    .disabled(recorder.isStarting)
            }
            if let latest = recorder.meetings.first(where: { $0.transcriptPath != nil }) {
                Button("Copy Last Meeting Transcript") { MeetingTranscriptClipboard.copy(latest) }
            }
        }
    }
}
