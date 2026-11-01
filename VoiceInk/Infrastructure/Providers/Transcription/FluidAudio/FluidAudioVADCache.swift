import CoreML
import FluidAudio
import Foundation

protocol FluidAudioVADManaging: Sendable {
    func segmentSpeech(_ samples: [Float]) async throws -> [VadSegment]
    func segmentSpeech(_ samples: [Float], config: VadSegmentationConfig) async throws -> [VadSegment]
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

    func segmentSpeech(_ samples: [Float], config: VadSegmentationConfig) async throws -> [VadSegment] {
        try await manager.segmentSpeech(samples, config: config)
    }

    func segmentSpeechAudio(_ samples: [Float]) async throws -> [[Float]] {
        try await manager.segmentSpeechAudio(samples)
    }
}

/// Keeps the Silero manager loaded while any recording holds a lease; the last release frees it.
actor FluidAudioVADCache {
    typealias Loader = @Sendable () async throws -> any FluidAudioVADManaging

    private struct Load {
        let id: UUID
        let generation: UUID
        let task: Task<any FluidAudioVADManaging, Error>
    }

    private let loader: Loader
    private let isEnabled: @Sendable () -> Bool
    /// Recording ID to the model name its preparation was made for.
    private var leases: [UUID: String] = [:]
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

    var leaseCount: Int { leases.count }

    func prepare(recordingID: UUID, modelName: String) async throws -> Bool {
        try Task.checkCancellation()
        // The first lease starts a fresh generation, as does a model change, which drops every other lease.
        if leases.isEmpty || leases.values.contains(where: { $0 != modelName }) {
            invalidate()
        }
        leases[recordingID] = modelName
        do {
            return try await manager() != nil
        } catch is CancellationError {
            if Task.isCancelled, leases[recordingID] == modelName {
                await release(recordingID: recordingID)
            }
            throw CancellationError()
        }
    }

    func release(recordingID: UUID) async {
        guard leases.removeValue(forKey: recordingID) != nil, leases.isEmpty else { return }
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
        leases.removeAll()
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
