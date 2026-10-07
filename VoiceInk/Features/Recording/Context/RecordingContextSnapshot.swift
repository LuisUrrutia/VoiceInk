import AppKit
import Foundation

struct RecordingContextSnapshot {
    var capturedAt = Date()
    var selectedText: String?
    var clipboardText: String?
    var screenText: String?
}

@MainActor
final class RecordingContextSnapshotStore {
    private(set) var snapshot = RecordingContextSnapshot()

    func updateSelectedText(_ text: String?) {
        snapshot.selectedText = Self.normalized(text)
    }

    func updateClipboardText(_ text: String?) {
        snapshot.clipboardText = Self.normalized(text)
    }

    func updateScreenText(_ text: String?) {
        snapshot.screenText = Self.normalized(text)
    }

    private static func normalized(_ text: String?) -> String? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

@MainActor
enum RecordingContextCaptureService {
    static func startCapture(into store: RecordingContextSnapshotStore) -> [Task<Void, Never>] {
        store.updateClipboardText(NSPasteboard.general.string(forType: .string))
        return [
            Task { @MainActor in
                guard !Task.isCancelled else { return }
                let selectedText = await SelectedTextService.fetchSelectedText()
                guard !Task.isCancelled else { return }
                store.updateSelectedText(selectedText)
            },
            Task { @MainActor in
                guard CGPreflightScreenCaptureAccess(), !Task.isCancelled else { return }
                let screenCaptureService = ScreenCaptureService()
                let screenText = await screenCaptureService.captureAndExtractText()
                guard !Task.isCancelled else { return }
                store.updateScreenText(screenText)
            },
        ]
    }
}

@MainActor
final class RecordingContextCapture {
    @MainActor
    final class Session {
        let recordingID: UUID
        let store = RecordingContextSnapshotStore()
        private let tasks: [Task<Void, Never>]

        init(recordingID: UUID, capture: @MainActor (RecordingContextSnapshotStore) -> [Task<Void, Never>]) {
            self.recordingID = recordingID
            tasks = capture(store)
        }

        func cancel() {
            tasks.forEach { $0.cancel() }
        }
    }

    private var session: Session?
    private let capture: @MainActor (RecordingContextSnapshotStore) -> [Task<Void, Never>]

    init(
        capture: @escaping @MainActor (RecordingContextSnapshotStore) -> [Task<Void, Never>] = RecordingContextCaptureService.startCapture
    ) {
        self.capture = capture
    }

    func start(recordingID: UUID) {
        clear()
        session = Session(recordingID: recordingID, capture: capture)
    }

    func clear(recordingID: UUID? = nil) {
        if let recordingID, session?.recordingID != recordingID { return }
        session?.cancel()
        session = nil
    }

    func take() -> Session? {
        defer { session = nil }
        return session
    }
}
