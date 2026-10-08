import Foundation

// MARK: - RecorderStateProvider

extension VoiceInkEngine: RecorderStateProvider {
    var recordingStatusText: String {
        if recordingState == .idle, let recordingError { return recordingError }
        return CaptureFeedback.resolve(
            state: recordingState,
            hasSetupIssues: !captureReadiness.snapshot.issues(for: .onScreenDictation).isEmpty,
            hasError: false
        ).title
    }
}
