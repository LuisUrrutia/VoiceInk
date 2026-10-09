import CoreML
import FluidAudio
import Foundation

protocol FluidAudioVADManaging: Sendable {
    func segmentSpeech(_ samples: [Float]) async throws -> [VadSegment]
    func segmentSpeechAudio(_ samples: [Float]) async throws -> [[Float]]
}

struct LocalFluidAudioVAD: FluidAudioVADManaging {
    let manager: VadManager

    static func load() async throws -> any FluidAudioVADManaging {
        let url = MLModelConfigurationUtils.defaultModelsDirectory(for: .vad)
            .appendingPathComponent(ModelNames.VAD.sileroVadFile)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw VadError.modelLoadingFailed
        }
        try Task.checkCancellation()
        let configuration = MLModelConfiguration()
        configuration.computeUnits = VadConfig.default.computeUnits
        let model = try await MLModel.load(contentsOf: url, configuration: configuration)
        try Task.checkCancellation()
        return LocalFluidAudioVAD(manager: VadManager(config: VadConfig(defaultThreshold: 0.7), vadModel: model))
    }

    func segmentSpeech(_ samples: [Float]) async throws -> [VadSegment] {
        try await manager.segmentSpeech(samples)
    }

    func segmentSpeechAudio(_ samples: [Float]) async throws -> [[Float]] {
        try await manager.segmentSpeechAudio(samples)
    }
}

actor FluidAudioVADCache {
    typealias Loader = @Sendable () async throws -> any FluidAudioVADManaging

    private struct Lease: Equatable {
        let recordingID: UUID
        let modelName: String
    }

    private struct Load {
        let id: UUID
        let generation: UUID
        let task: Task<any FluidAudioVADManaging, Error>
    }

    private let loader: Loader
    private let isEnabled: @Sendable () -> Bool
    private var lease: Lease?
    private var generation = UUID()
    private var result: Result<any FluidAudioVADManaging, Error>?
    private var loading: Load?

    init(loader: @escaping Loader = { try await LocalFluidAudioVAD.load() },
         isEnabled: @escaping @Sendable () -> Bool = { UserDefaults.standard.bool(forKey: "IsVADEnabled") }) {
        self.loader = loader
        self.isEnabled = isEnabled
    }

    deinit {
        loading?.task.cancel()
    }

    func prepare(recordingID: UUID, modelName: String) async throws -> Bool {
        try Task.checkCancellation()
        let requestedLease = Lease(recordingID: recordingID, modelName: modelName)
        if lease != requestedLease {
            invalidate()
            lease = requestedLease
        }
        do {
            return try await manager() != nil
        } catch is CancellationError {
            if Task.isCancelled, lease == requestedLease {
                await release(recordingID: recordingID)
            }
            throw CancellationError()
        }
    }

    func release(recordingID: UUID) async {
        guard lease?.recordingID == recordingID else { return }
        await cleanup()
    }

    func cleanup() async {
        invalidate()
        if let load = loading {
            _ = await load.task.result
            if loading?.id == load.id {
                loading = nil
            }
        }
    }

    private func invalidate() {
        generation = UUID()
        lease = nil
        result = nil
        loading?.task.cancel()
    }

    func manager() async throws -> (any FluidAudioVADManaging)? {
        try Task.checkCancellation()
        guard isEnabled() else {
            await cleanup()
            return nil
        }
        let requestedGeneration = generation

        // Keep a canceled load in the slot until it exits, even if Core ML ignores cancellation.
        if let load = loading, load.generation != requestedGeneration {
            _ = await load.task.result
            if loading?.id == load.id {
                loading = nil
            }
        }
        try Task.checkCancellation()
        guard generation == requestedGeneration else { throw CancellationError() }
        if let result {
            return try result.get()
        }

        let load: Load
        if let existing = loading {
            load = existing
        } else {
            let loader = self.loader
            load = Load(id: UUID(), generation: requestedGeneration, task: Task { try await loader() })
            loading = load
        }
        let loaded = await load.task.result
        try Task.checkCancellation()
        guard generation == requestedGeneration else { throw CancellationError() }
        guard isEnabled() else {
            await cleanup()
            return nil
        }
        if loading?.id == load.id {
            loading = nil
            result = loaded
        }
        return try loaded.get()
    }
}
