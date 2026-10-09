import Foundation

@MainActor
final class RecordingTranscriptionPreparation {
    struct Setup {
        let configuration: TranscriptionRuntimeConfiguration
        let session: TranscriptionSession?
    }

    let recordingID: UUID
    let timing: RecordingTimingTrace
    private(set) var isCancelled = false
    private var modeTask: Task<Void, Never>?
    private var autoLearnTask: Task<Void, Never>?
    private var configurationTask: Task<TranscriptionRuntimeConfiguration?, Never>?
    private var modelTask: Task<Void, Never>?
    private var sessionTask: Task<TranscriptionSession?, Error>?
    private var preparedSession: TranscriptionSession?

    init(timing: RecordingTimingTrace) {
        self.recordingID = timing.recordingID
        self.timing = timing
    }

    func ownModeResolution(_ task: Task<Void, Never>) {
        modeTask = task
        if isCancelled { task.cancel() }
    }

    func start(
        resolveConfiguration: @escaping @MainActor () -> TranscriptionRuntimeConfiguration?,
        retireAutoLearn: @escaping @MainActor () async -> Void,
        prepareModel: @escaping @MainActor (TranscriptionRuntimeConfiguration) async throws -> Void,
        prepareSession: @escaping @MainActor (TranscriptionRuntimeConfiguration) async throws -> TranscriptionSession?
    ) {
        guard !isCancelled, configurationTask == nil else { return }
        let modeTask = modeTask
        let timing = timing
        let configurationTask = Task { @MainActor in
            await modeTask?.value
            guard !Task.isCancelled else { return nil as TranscriptionRuntimeConfiguration? }
            let configuration = resolveConfiguration()
            timing.mark(.modeResolved, outcome: configuration == nil ? .failed : .completed)
            return configuration
        }
        self.configurationTask = configurationTask

        modelTask = Task { @MainActor in
            guard let configuration = await configurationTask.value, !Task.isCancelled else { return }
            timing.mark(.preparationStarted)
            do {
                try await prepareModel(configuration)
                try Task.checkCancellation()
                timing.mark(.preparationFinished)
            } catch is CancellationError {
                timing.mark(.preparationFinished, outcome: .canceled)
            } catch {
                timing.mark(.preparationFinished, outcome: .failed)
            }
        }

        // Previous edits must finish retiring even when this recording is canceled.
        let autoLearnTask = Task { @MainActor in await retireAutoLearn() }
        self.autoLearnTask = autoLearnTask
        sessionTask = Task { @MainActor [weak self] in
            guard let configuration = await configurationTask.value else { return nil }
            try Task.checkCancellation()
            let session = try await prepareSession(configuration)
            self?.preparedSession = session
            await autoLearnTask.value
            guard !Task.isCancelled else {
                session?.cancel()
                await session?.finishPreparation()
                throw CancellationError()
            }
            return session
        }
    }

    func setup() async throws -> Setup? {
        guard let configuration = await configurationTask?.value else { return nil }
        let session = try await sessionTask?.value
        guard !isCancelled else { throw CancellationError() }
        return Setup(configuration: configuration, session: session)
    }

    func waitUntilPrepared() async {
        await modelTask?.value
    }

    func cancel() {
        guard !isCancelled else { return }
        isCancelled = true
        modeTask?.cancel()
        configurationTask?.cancel()
        modelTask?.cancel()
        sessionTask?.cancel()
        preparedSession?.cancel()
    }

    func finish() async {
        cancel()
        await modeTask?.value
        await configurationTask?.value
        await autoLearnTask?.value
        await modelTask?.value
        _ = try? await sessionTask?.value
        await preparedSession?.finishPreparation()
    }

    deinit {
        modeTask?.cancel()
        configurationTask?.cancel()
        modelTask?.cancel()
        sessionTask?.cancel()
    }
}
