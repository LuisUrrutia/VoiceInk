import Foundation

/// The part of `WhisperContext` a meeting job uses.
protocol TimedWhisperContext: AnyObject {
    func transcribeTimed(samples: [Float], request: TranscriptionRequestContext) async throws -> [TimedTranscriptSegment]
    func releaseResources() async
}

extension WhisperContext: TimedWhisperContext {}

/// Whisper for one meeting job: it loads its own context once from the installed model file, reuses it for every
/// chunk and releases it at the end, so dictation's loaded context is neither borrowed nor reloaded per chunk.
final class MeetingWhisperTranscriber: TimedSpeechTranscribing {
    private let modelURL: @MainActor (String) -> URL?
    private let loadContext: (String) async throws -> any TimedWhisperContext
    private var context: (name: String, context: any TimedWhisperContext)?

    init(
        modelURL: @escaping @MainActor (String) -> URL?,
        loadContext: @escaping (String) async throws -> any TimedWhisperContext = { try await WhisperContext.createContext(path: $0) }
    ) {
        self.modelURL = modelURL
        self.loadContext = loadContext
    }

    func transcribeTimed(
        samples: [Float], model: any TranscriptionModel, context request: TranscriptionRequestContext
    ) async throws -> [TimedTranscriptSegment] {
        guard model.provider == .whisper else { throw TimedTranscriptionError.unsupportedModel }
        guard !samples.isEmpty else { return [] }
        return try await context(for: model.name).transcribeTimed(samples: samples, request: request)
    }

    /// No regions: meeting chunks then come from the level detector, and whisper.cpp's own voice detection stays off.
    func speechRegions(in samples: [Float]) async throws -> [Range<Int>]? { nil }

    func releaseResources() async {
        guard let context else { return }
        self.context = nil
        await context.context.releaseResources()
    }

    private func context(for name: String) async throws -> any TimedWhisperContext {
        if let context, context.name == name { return context.context }
        await releaseResources()
        guard let url = await modelURL(name), FileManager.default.fileExists(atPath: url.path) else {
            throw VoiceInkEngineError.modelLoadFailed
        }
        let loaded = try await loadContext(url.path)
        context = (name, loaded)
        return loaded
    }
}
