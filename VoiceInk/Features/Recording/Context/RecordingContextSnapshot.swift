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
    let vocabularyPreparation: RecordingVocabularyPreparation
    private var recognitionLanguage: String?
    private var isRecognitionLanguageResolved = false

    init(savedVocabulary: RecordingVocabulary = RecordingVocabulary()) {
        vocabularyPreparation = RecordingVocabularyPreparation(savedVocabulary: savedVocabulary)
    }

    func updateSelectedText(_ text: String?) {
        snapshot.selectedText = Self.normalized(text)
    }

    func updateClipboardText(_ text: String?) {
        snapshot.clipboardText = Self.normalized(text)
    }

    func updateScreenText(_ text: String?) {
        snapshot.screenText = Self.normalized(text)
        prepareScreenNamesIfReady()
    }

    /// Capture starts before mode resolution, so screen names wait for the recording's language.
    func resolveRecognitionLanguage(_ language: String?) {
        guard !isRecognitionLanguageResolved else { return }
        isRecognitionLanguageResolved = true
        recognitionLanguage = language
        prepareScreenNamesIfReady()
    }

    private func prepareScreenNamesIfReady() {
        guard isRecognitionLanguageResolved, let text = snapshot.screenText else { return }
        vocabularyPreparation.prepareScreenNames(in: text, language: recognitionLanguage)
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
        // Snapshot the clipboard before a selected-text Copy fallback can replace it.
        store.updateClipboardText(SelectedTextService.captureClipboardText())
        return [
            Task { @MainActor in
                guard !Task.isCancelled else { return }
                let selectedText = await SelectedTextService.fetchSelectedText(isEnabled: true)
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
        let store: RecordingContextSnapshotStore
        private let tasks: [Task<Void, Never>]

        init(
            recordingID: UUID, store: RecordingContextSnapshotStore,
            capture: @MainActor (RecordingContextSnapshotStore) -> [Task<Void, Never>]
        ) {
            self.recordingID = recordingID
            self.store = store
            tasks = capture(store)
        }

        /// Stops unfinished capture while keeping already prepared vocabulary usable.
        func cancelCapture() {
            tasks.forEach { $0.cancel() }
        }

        func cancel() {
            cancelCapture()
            store.vocabularyPreparation.finish()
        }
    }

    private var session: Session?
    private let capture: @MainActor (RecordingContextSnapshotStore) -> [Task<Void, Never>]

    init(
        capture: @escaping @MainActor (RecordingContextSnapshotStore) -> [Task<Void, Never>] = RecordingContextCaptureService.startCapture
    ) {
        self.capture = capture
    }

    @discardableResult
    func start(
        recordingID: UUID, savedVocabulary: RecordingVocabulary = RecordingVocabulary()
    ) -> RecordingContextSnapshotStore {
        clear()
        let session = Session(
            recordingID: recordingID,
            store: RecordingContextSnapshotStore(savedVocabulary: savedVocabulary),
            capture: capture
        )
        self.session = session
        return session.store
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
