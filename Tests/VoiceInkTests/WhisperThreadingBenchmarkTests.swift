import Darwin
import FluidAudio
import Foundation
import XCTest
@testable import VoiceInk

/// Opt-in whisper.cpp thread-count and QoS benchmark; run `scripts/benchmark-whisper-threads.sh`.
@MainActor
final class WhisperThreadingBenchmarkTests: XCTestCase {
    private struct Configuration: Hashable {
        let threads: Int32?
        let qos: DispatchQoS.QoSClass

        var label: String {
            "threads=\(threads.map(String.init) ?? "default") qos=\(InferenceBenchmark.label(qos.rawValue))"
        }
    }

    private struct Clip {
        let seconds: Int
        let offset: Int
        let samples: [Float]

        var label: String { "\(seconds)s@\(offset)" }
    }

    private struct Run {
        let milliseconds: Double
        let text: String
    }

    func testDefaultThreadCountLeavesTwoCoresAndCapsAtEight() {
        XCTAssertEqual([1, 2, 3, 4, 10, 16, 32].map { WhisperContext.defaultThreadCount(processorCount: $0) },
                       [1, 1, 1, 2, 8, 8, 8])
    }

    func testThreadCountOverrideReachesTheNativeParameterAndResets() async {
        let context = WhisperContext()
        let defaultCount = await context.nativeThreadCount
        await context.setThreadCount(1)
        let overridden = await context.nativeThreadCount
        await context.setThreadCount(nil)
        let reset = await context.nativeThreadCount

        XCTAssertEqual(defaultCount, WhisperContext.defaultThreadCount())
        XCTAssertEqual(overridden, 1)
        XCTAssertEqual(reset, WhisperContext.defaultThreadCount())
    }

    func testMeasureInferenceThreadsAndQoS() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let reportPath = environment["VOICEINK_WHISPER_BENCH_RESULT"],
              let audioPath = environment["VOICEINK_WHISPER_BENCH_AUDIO"],
              let modelPaths = environment["VOICEINK_WHISPER_BENCH_MODELS"] else {
            throw XCTSkip("Set VOICEINK_WHISPER_BENCH_RESULT, VOICEINK_WHISPER_BENCH_AUDIO and VOICEINK_WHISPER_BENCH_MODELS")
        }
        let runs = Int(environment["VOICEINK_WHISPER_BENCH_RUNS"] ?? "") ?? 6
        let loadProcessCount = Int(environment["VOICEINK_WHISPER_BENCH_LOAD_PROCESSES"] ?? "")
            ?? ProcessInfo.processInfo.activeProcessorCount * 2
        // 0 is the app's default (`WhisperContext.defaultThreadCount`).
        let threadCounts: [Int32?] = (environment["VOICEINK_WHISPER_BENCH_THREADS"] ?? "0,1,2,4")
            .split(separator: ",").compactMap { Int32($0) }.map { $0 == 0 ? nil : $0 }
        let qosClasses: [DispatchQoS.QoSClass] = (environment["VOICEINK_WHISPER_BENCH_QOS"] ?? "userInitiated,userInteractive")
            .split(separator: ",").map { $0 == "userInteractive" ? .userInteractive : .userInitiated }
        let loads = (environment["VOICEINK_WHISPER_BENCH_LOADS"] ?? "idle,loaded").split(separator: ",").map(String.init)
        let vadEnabled = (environment["VOICEINK_WHISPER_BENCH_VAD"] ?? "on") == "on"
        let configurations = threadCounts.flatMap { threads in
            qosClasses.map { Configuration(threads: threads, qos: $0) }
        }

        let audio = try AudioConverter().resampleAudioFile(URL(fileURLWithPath: audioPath))
        let clips = try InferenceBenchmark.clipSpecifications(environment["VOICEINK_WHISPER_BENCH_CLIPS"] ?? "3@14,30@0,90@30").map {
            let start = $0.offset * 16_000
            let end = start + $0.seconds * 16_000
            guard end <= audio.count else { throw CocoaError(.fileReadTooLarge) }
            return Clip(seconds: $0.seconds, offset: $0.offset, samples: Array(audio[start..<end]))
        }
        let modelPathList = modelPaths.split(separator: ",").map(String.init)
        guard !modelPathList.isEmpty, runs > 0, !configurations.isEmpty, !clips.isEmpty, !loads.isEmpty,
              Set(clips.map(\.label)).count == clips.count else {
            return XCTFail("Need a model, positive runs, distinct clips and at least one thread count, QoS class and load")
        }

        let previousVAD = UserDefaults.standard.object(forKey: "IsVADEnabled")
        UserDefaults.standard.set(vadEnabled, forKey: "IsVADEnabled")
        defer { UserDefaults.standard.set(previousVAD, forKey: "IsVADEnabled") }

        var report = [
            "# whisper.cpp threading benchmark",
            "host=\(InferenceBenchmark.hostDescription()) runs=\(runs) loadProcesses=\(loadProcessCount) vad=\(vadEnabled)",
            "defaultThreads=\(WhisperContext.defaultThreadCount()) productionPathQoS=\(await Self.productionPathQoS())",
        ]
        // unix_s matches rows to samples of other system load.
        var rows = ["model,load,clip_s,clip_offset_s,threads,qos,run,wall_ms,transcript_matches,unix_s"]

        for modelPath in modelPathList {
            let modelURL = URL(fileURLWithPath: modelPath)
            let name = modelURL.deletingPathExtension().lastPathComponent
            let model = try XCTUnwrap(
                TranscriptionModelRegistry.models.first { $0.provider == .whisper && $0.name == name },
                "\(name) is not a Whisper model the app ships"
            )
            // whisper.cpp's rule: strip the extension and a "-qN_N" suffix, then add "-encoder.mlmodelc".
            let encoderName = name.replacingOccurrences(of: #"-q\d_\d$"#, with: "", options: .regularExpression)
                + "-encoder.mlmodelc"
            let hasCoreMLEncoder = FileManager.default.fileExists(
                atPath: modelURL.deletingLastPathComponent().appendingPathComponent(encoderName).path
            )
            let request = TranscriptionRequestContext(languages: ["en"], model: model)
            let context = try await WhisperContext.createContext(path: modelPath)
            report.append(
                "model=\(name) sha256=\(try InferenceBenchmark.sha256(ofFileAt: modelPath)) coreMLEncoder=\(hasCoreMLEncoder)"
            )

            var references: [String: String] = [:]
            for clip in clips {
                let warmup = try await Self.transcribe(clip.samples, context: context, request: request,
                                                       configuration: .init(threads: nil, qos: .userInitiated))
                references[clip.label] = warmup.text
                report.append("reference model=\(name) clip=\(clip.label): \(warmup.text)")
            }

            for load in loads {
                let cpuLoad = load == "loaded" ? try CPULoad(processCount: loadProcessCount) : nil
                defer { cpuLoad?.stop() }
                try await Task.sleep(for: .seconds(2))

                var results: [String: [Run]] = [:]
                var generator = SeededGenerator(seed: 0x5EED)
                for round in 0..<runs {
                    let trials = configurations.flatMap { configuration in clips.map { (configuration, $0) } }
                        .shuffled(using: &generator)
                    for (configuration, clip) in trials {
                        let run = try await Self.transcribe(clip.samples, context: context, request: request,
                                                            configuration: configuration)
                        let matches = run.text == references[clip.label]
                        results["\(clip.label)|\(configuration.label)", default: []].append(run)
                        rows.append(
                            "\(name),\(load),\(clip.seconds),\(clip.offset),\(configuration.threads.map(String.init) ?? "default"),"
                                + "\(InferenceBenchmark.label(configuration.qos.rawValue)),\(round),"
                                + String(format: "%.1f,", run.milliseconds) + "\(matches),"
                                + String(format: "%.0f", Date().timeIntervalSince1970)
                        )
                        if !matches {
                            report.append("mismatch model=\(name) load=\(load) clip=\(clip.label) \(configuration.label): \(run.text)")
                        }
                    }
                }

                for clip in clips {
                    for configuration in configurations {
                        let samples = results["\(clip.label)|\(configuration.label)"] ?? []
                        let mismatches = samples.filter { $0.text != references[clip.label] }.count
                        report.append(
                            "model=\(name) load=\(load) clip=\(clip.label) \(configuration.label) "
                                + "wallMs=\(InferenceBenchmark.summary(samples.map(\.milliseconds))) mismatches=\(mismatches)"
                        )
                    }
                }
            }
            await context.releaseResources()
        }

        XCTAssertEqual(rows.count - 1, modelPathList.count * loads.count * runs * configurations.count * clips.count)
        try (report + ["", "# raw"] + rows).joined(separator: "\n").appending("\n")
            .write(toFile: reportPath, atomically: true, encoding: .utf8)
    }

    nonisolated private static func transcribe(
        _ samples: [Float],
        context: WhisperContext,
        request: TranscriptionRequestContext,
        configuration: Configuration
    ) async throws -> Run {
        // A default actor runs its jobs on the task's executor preference (SE-0417).
        try await withTaskExecutorPreference(QoSQueueExecutor(qos: configuration.qos)) {
            let (milliseconds, text) = try await context.benchmarkTranscribe(
                samples: samples, request: request, threads: configuration.threads, qos: configuration.qos
            )
            return Run(milliseconds: milliseconds, text: text)
        }
    }

    /// Mirrors a shortcut stop: a main-queue block starts a main-actor task that awaits the Whisper actor.
    private static func productionPathQoS() async -> String {
        let probe = ActorQoSProbe()
        return await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                Task { @MainActor in
                    let priority = Task.currentPriority
                    let qos = await probe.currentQoS()
                    continuation.resume(returning: "\(qos) (task priority \(priority.rawValue))")
                }
            }
        }
    }
}

/// A default actor runs on the same cooperative pool as `WhisperContext`.
private actor ActorQoSProbe {
    func currentQoS() -> String { InferenceBenchmark.label(qos_class_self()) }
}

/// Runs jobs on a serial queue at a fixed QoS, as Hex's `prioritize_inference_thread` sets its thread's class.
private final class QoSQueueExecutor: TaskExecutor, @unchecked Sendable {
    private let queue: DispatchQueue

    init(qos: DispatchQoS.QoSClass) {
        queue = DispatchQueue(label: "WhisperThreadingBenchmark", qos: DispatchQoS(qosClass: qos, relativePriority: 0))
    }

    func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job)
        queue.async { job.runSynchronously(on: self.asUnownedTaskExecutor()) }
    }
}

private extension WhisperContext {
    var nativeThreadCount: Int32 { decodingParameters().n_threads }

    /// Runs the production `transcribe`, then restores the default thread count.
    func benchmarkTranscribe(
        samples: [Float], request: TranscriptionRequestContext, threads: Int32?, qos: DispatchQoS.QoSClass
    ) throws -> (milliseconds: Double, text: String) {
        guard qos_class_self() == qos.rawValue else {
            throw CocoaError(.featureUnsupported, userInfo: [NSDebugDescriptionErrorKey: "inference thread is not at \(qos)"])
        }
        setThreadCount(threads)
        defer { setThreadCount(nil) }
        guard nativeThreadCount == threads ?? Self.defaultThreadCount() else {
            throw CocoaError(.featureUnsupported, userInfo: [NSDebugDescriptionErrorKey: "n_threads is \(nativeThreadCount)"])
        }
        let start = ContinuousClock.now
        let text = try transcribe(samples: samples, request: request)
        return (InferenceBenchmark.milliseconds(start.duration(to: .now)), text)
    }
}
