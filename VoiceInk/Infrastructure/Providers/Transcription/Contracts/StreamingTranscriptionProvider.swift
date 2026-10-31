import Foundation

/// Events emitted by a streaming transcription provider
enum StreamingTranscriptionEvent {
    case sessionStarted
    case partial(text: String)
    case committed(text: String)
    case error(Error)
}

/// Tells the shared streaming layer how a provider wants to finish the recording.
enum StreamingStopDisposition {
    case finalizeStreaming
    case useBatchFallback
}

/// Errors specific to streaming transcription
enum StreamingTranscriptionError: LocalizedError {
    case missingAPIKey
    case connectionFailed(String)
    case timeout
    case serverError(String)
    case notConnected
    case audioConversionFailed

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return String(localized: "API key not configured for streaming transcription")
        case .connectionFailed(let message):
            return String(format: String(localized: "Streaming connection failed: %@"), message)
        case .timeout:
            return String(localized: "Streaming transcription timed out waiting for final result")
        case .serverError(let message):
            return String(format: String(localized: "Streaming server error: %@"), message)
        case .notConnected:
            return String(localized: "Not connected to streaming transcription service")
        case .audioConversionFailed:
            return String(localized: "Failed to convert audio chunk for streaming")
        }
    }
}

/// Protocol for streaming transcription providers.
protocol StreamingTranscriptionProvider: AnyObject {
    /// Provider-specific decision made when the user stops recording.
    var stopDisposition: StreamingStopDisposition { get }

    /// Longest time from Stop to the final transcript, covering the audio backlog, commit and final event.
    var finishDeadline: Duration { get }

    /// Connect to the streaming transcription endpoint
    func connect(model: any TranscriptionModel, language: String?) async throws

    /// Send a chunk of raw PCM audio data (16-bit, 16kHz, mono, little-endian)
    func sendAudioChunk(_ data: Data) async throws

    /// Commit the current audio buffer to finalize transcription
    func commit() async throws

    /// Disconnect from the streaming endpoint
    func disconnect() async

    /// Stream of transcription events from the provider
    var transcriptionEvents: AsyncStream<StreamingTranscriptionEvent> { get }

    /// Provider-confirmed full transcript emitted only after all submitted audio has been finalized.
    /// Providers without a distinct end-of-stream acknowledgement use the shared committed-event behavior.
    var finalizationEvents: AsyncStream<String>? { get }
}

extension StreamingTranscriptionProvider {
    var stopDisposition: StreamingStopDisposition { .finalizeStreaming }
    var finishDeadline: Duration { .seconds(10) }
    var finalizationEvents: AsyncStream<String>? { nil }
}
