import AppKit
import SwiftUI

struct MeetingsView: View {
    @ObservedObject private var recorder = MeetingRecorder.shared
    @AppStorage(MeetingSettings.outputFolderKey) private var outputFolderPath = ""
    @AppStorage(MeetingSettings.showsRecordingIndicatorKey) private var showsRecordingIndicator = true
    @AppStorage(MeetingSettings.detectsCallsKey) private var detectsCalls = true
    @State private var policies: [MeetingProvider: MeetingProviderPolicy] = [:]

    var body: some View {
        Form {
            Section {
                recordingRow
                systemAudioRow
            } header: {
                Text("Recording")
            } footer: {
                Text("VoiceInk records your microphone as You and the other participants' audio as Them, as two separate tracks. Audio and transcripts stay on this Mac. Dictation keeps working during a meeting and leaves the call's volume alone.")
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Transcripts") {
                LabeledContent("Folder") {
                    HStack {
                        Text(MeetingSettings.outputFolder().path)
                            .lineLimit(1).truncationMode(.middle)
                            .foregroundStyle(.secondary)
                            .help(MeetingSettings.outputFolder().path)
                        Button("Choose…", action: chooseFolder)
                        if !outputFolderPath.isEmpty {
                            Button("Reset") { MeetingSettings.setOutputFolder(nil) }
                        }
                    }
                }
                Toggle("Show recording indicator", isOn: $showsRecordingIndicator)
            }

            Section {
                Toggle("Offer to record detected calls", isOn: $detectsCalls)
                if detectsCalls {
                    ForEach(MeetingProvider.allCases, id: \.self) { provider in
                        Picker(provider.displayName, selection: policyBinding(for: provider)) {
                            ForEach(MeetingProviderPolicy.allCases, id: \.self) { Text($0.displayName).tag($0) }
                        }
                    }
                }
            } header: {
                Text("Call detection")
            } footer: {
                Text("VoiceInk notices when one of these apps uses the microphone. Google Meet is recognized in the front tab of a supported browser that VoiceInk may already automate. A recording never stops by itself: when the app leaves the call, VoiceInk asks.")
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Meetings") {
                if recorder.meetings.isEmpty {
                    Text("No meetings yet.").foregroundStyle(.secondary)
                } else {
                    ForEach(recorder.meetings) { meeting in
                        MeetingRow(meeting: meeting, isActive: meeting.id == recorder.activeMeeting?.id)
                    }
                }
            }
        }
        .formStyle(AppSettingsFormStyle())
        .onAppear {
            // Never offer can be chosen from a call prompt while this page is closed.
            policies = Dictionary(uniqueKeysWithValues: MeetingProvider.allCases.map { ($0, MeetingSettings.policy(for: $0)) })
            recorder.refreshAuthorization()
            recorder.reloadMeetings()
        }
    }

    @ViewBuilder
    private var recordingRow: some View {
        if let meeting = recorder.activeMeeting {
            LabeledContent {
                Button("Stop & Transcribe") { Task { _ = await recorder.stop() } }
                    .disabled(recorder.isStopping)
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(meeting.title)
                    if let startedAt = recorder.recordingStartedAt {
                        Text(startedAt, style: .timer).monospacedDigit().settingsDescription()
                    }
                }
            }
        } else {
            LabeledContent("Record a meeting") {
                Button("Record Meeting") { Task { await recorder.toggle() } }
                    .disabled(recorder.isStarting || recorder.isStopping)
            }
        }
    }

    private var systemAudioRow: some View {
        LabeledContent {
            switch recorder.systemAudioAuthorization {
            case .granted:
                Text("Allowed").foregroundStyle(.secondary)
            case .notDetermined:
                Button("Allow") { Task { await recorder.requestSystemAudioAccess() } }
            case .denied, .unknown:
                Button("Open System Settings", action: openSystemAudioSettings)
            }
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text("System Audio Recording")
                Text(systemAudioDescription).settingsDescription()
            }
        }
    }

    private var systemAudioDescription: LocalizedStringKey {
        switch recorder.systemAudioAuthorization {
        case .granted: "Needed to record the other participants."
        case .notDetermined: "Needed to record the other participants. macOS asks once."
        case .denied: "Denied. Without it, the other participants are not recorded."
        case .unknown: "VoiceInk cannot read this permission. If Them stays silent, allow VoiceInk in System Settings."
        }
    }

    private func policyBinding(for provider: MeetingProvider) -> Binding<MeetingProviderPolicy> {
        Binding(
            get: { policies[provider] ?? MeetingSettings.policy(for: provider) },
            set: {
                MeetingSettings.setPolicy($0, for: provider)
                policies[provider] = $0
            }
        )
    }

    private func openSystemAudioSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = MeetingSettings.outputFolder()
        panel.prompt = String(localized: "Choose")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        MeetingSettings.setOutputFolder(url)
    }
}

private struct MeetingRow: View {
    let meeting: MeetingManifest
    let isActive: Bool
    @ObservedObject private var recorder = MeetingRecorder.shared
    @ObservedObject private var transcription = MeetingTranscriptionCoordinator.shared

    private var isTranscribing: Bool {
        meeting.status == .transcribing || transcription.transcribingID == meeting.id
    }

    var body: some View {
        LabeledContent {
            HStack {
                if let path = meeting.transcriptPath, FileManager.default.fileExists(atPath: path) {
                    Button("Open") { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
                    Button {
                        MeetingTranscriptClipboard.copy(meeting)
                    } label: {
                        Image(appSymbol: "doc.on.doc")
                    }
                    .help("Copy transcript")
                    .accessibilityLabel("Copy transcript")
                }
                if !isActive, !isTranscribing, meeting.status != .recording {
                    Button(meeting.status == .transcribed ? "Transcribe Again" : "Transcribe") {
                        transcription.enqueue(meeting.id)
                    }
                }
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([recorder.store.directory(for: meeting.id)])
                } label: {
                    Image(appSymbol: "folder")
                }
                .help("Show audio in Finder")
                .accessibilityLabel("Show audio in Finder")
                Button(role: .destructive) {
                    recorder.delete(meeting)
                } label: {
                    Image(appSymbol: "trash")
                }
                .disabled(isActive)
                .help("Move to Trash")
                .accessibilityLabel("Move to Trash")
            }
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(meeting.title)
                Text(detail).settingsDescription()
            }
        }
    }

    private var detail: String {
        let date = meeting.createdAt.formatted(date: .abbreviated, time: .shortened)
        let duration = Duration.seconds(meeting.duration).formatted(.time(pattern: .hourMinuteSecond))
        let status = isTranscribing ? MeetingManifest.Status.transcribing.displayName : meeting.status.displayName
        return [date, isActive ? nil : duration, status, meeting.status == .failed ? meeting.failure : nil]
            .compactMap { $0 }.joined(separator: " · ")
    }
}

extension MeetingManifest.Status {
    var displayName: String {
        switch self {
        case .recording: String(localized: "Recording")
        case .recorded: String(localized: "Recorded")
        case .transcribing: String(localized: "Transcribing")
        case .transcribed: String(localized: "Transcribed")
        case .interrupted: String(localized: "Interrupted")
        case .failed: String(localized: "Failed")
        }
    }
}
