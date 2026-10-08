import Foundation

// Protocol for objects that provide live recorder state to the UI.
@MainActor
protocol RecorderStateProvider: AnyObject {
    var recordingState: RecordingState { get }
    var partialTranscript: String { get }
    var recordingStatusText: String { get }
}

extension RecorderStateProvider {
    var recordingStatusText: String {
        CaptureFeedback.resolve(state: recordingState, hasSetupIssues: false, hasError: false).title
    }
}
