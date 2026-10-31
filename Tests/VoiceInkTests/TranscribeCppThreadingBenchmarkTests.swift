import Darwin
import FluidAudio
import Foundation
import TranscribeCpp
import XCTest
@testable import VoiceInk

/// Opt-in transcribe.cpp thread-count and QoS benchmark; run `scripts/benchmark-transcribe-cpp-threads.sh`.
@MainActor
final class TranscribeCppThreadingBenchmarkTests: XCTestCase {
    private struct Configuration: Hashable {
        let threads: Int32
        let qos: DispatchQoS.QoSClass

        var label: String {
            let threadLabel = threads == 0 ? "default" : String(threads)
            return "threads=\(threadLabel) qos=\(qos == .userInteractive ? "userInteractive" : "userInitiated")"
        }
    }

    private struct Clip {
        let seconds: Int
        let samples: [Float]
    }

    private struct Run {
        let milliseconds: Double
        let decodeMilliseconds: Double
        let text: String
    }

    func testMeasureDecoderThreadsAndQoS() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let reportPath = environment["VOICEINK_TCPP_BENCH_RESULT"],
              let audioPath = environment["VOICEINK_TCPP_BENCH_AUDIO"],
              let modelPaths = environment["VOICEINK_TCPP_BENCH_MODELS"] else {
            throw XCTSkip("Set VOICEINK_TCPP_BENCH_RESULT, VOICEINK_TCPP_BENCH_AUDIO and VOICEINK_TCPP_BENCH_MODELS")
        }
        let runs = Int(environment["VOICEINK_TCPP_BENCH_RUNS"] ?? "") ?? 5
        let loadProcessCount = Int(environment["VOICEINK_TCPP_BENCH_LOAD_PROCESSES"] ?? "")
            ?? ProcessInfo.processInfo.activeProcessorCount * 2
        let threadCounts = (environment["VOICEINK_TCPP_BENCH_THREADS"] ?? "0,1,2,4")
            .split(separator: ",").compactMap { Int32($0) }
        let qosClasses: [DispatchQoS.QoSClass] = (environment["VOICEINK_TCPP_BENCH_QOS"] ?? "userInitiated,userInteractive")
            .split(separator: ",").map { $0 == "userInteractive" ? .userInteractive : .userInitiated }
        let loads = (environment["VOICEINK_TCPP_BENCH_LOADS"] ?? "idle,loaded").split(separator: ",").map(String.init)
        let configurations = threadCounts.flatMap { threads in
            qosClasses.map { Configuration(threads: threads, qos: $0) }
        }

        let audio = try AudioConverter().resampleAudioFile(URL(fileURLWithPath: audioPath))
        let clips = try clipSpecifications(environment["VOICEINK_TCPP_BENCH_CLIPS"] ?? "3@14,30@0,90@30").map {
            let start = $0.offset * 16_000
            let end = start + $0.seconds * 16_000
            guard end <= audio.count else { throw CocoaError(.fileReadTooLarge) }
            return Clip(seconds: $0.seconds, samples: Array(audio[start..<end]))
        }

        try Transcribe.initBackends()
        var report = [
            "# transcribe.cpp threading benchmark",
            "host=\(hostDescription()) runtime=\(Transcribe.version()) runs=\(runs) loadProcesses=\(loadProcessCount)",
            "productionPathQoS=\(await productionPathQoS())",
        ]
        var rows = ["model,load,clip_s,threads,qos,run,wall_ms,decode_ms,transcript_matches"]

        for modelPath in modelPaths.split(separator: ",").map(String.init) {
            let fileName = URL(fileURLWithPath: modelPath).lastPathComponent
            let artifact = try XCTUnwrap(
                [TranscribeCppModelCatalog.cohereTranscribe, TranscribeCppModelCatalog.senseVoiceSmall]
                    .first { $0.fileName == fileName },
                "Unknown model file \(fileName)"
            )
            let model = try Model(path: modelPath, options: ModelOptions(backend: .metal))
            let options = RunOptions(
                timestamps: .none,
                itn: artifact.enablesInverseTextNormalization ? .on : .default,
                language: "en",
                keepSpecialTags: false
            )
            let capabilitiesMaximum = model.capabilities.maxAudioMs
            let maximumChunkSeconds = capabilitiesMaximum > 0
                ? min(artifact.maximumChunkSeconds, max(1, Int(capabilitiesMaximum / 1_000)))
                : artifact.maximumChunkSeconds
            let chunkedClips = clips.map { clip in
                (clip.seconds, clip.samples.energyAwareChunks(
                    maximumCount: maximumChunkSeconds * 16_000,
                    boundarySearchCount: artifact.boundarySearchSeconds * 16_000,
                    energyWindowCount: artifact.boundaryEnergyWindowSamples
                ))
            }
            report.append("model=\(artifact.modelName) backend=\(model.backend) device=\(try model.device.description)")

            var references: [Int: String] = [:]
            for (seconds, chunks) in chunkedClips {
                let warmup = try await transcribe(chunks, model: model, options: options, configuration: .init(threads: 0, qos: .userInitiated))
                references[seconds] = warmup.text
                report.append("reference model=\(artifact.modelName) clip=\(seconds)s chunks=\(chunks.count): \(warmup.text)")
            }

            for load in loads {
                let cpuLoad = load == "loaded" ? try CPULoad(processCount: loadProcessCount) : nil
                defer { cpuLoad?.stop() }
                try await Task.sleep(for: .seconds(2))

                var results: [String: [Run]] = [:]
                var generator = SeededGenerator(seed: 0x5EED)
                for round in 0..<runs {
                    let trials = configurations.flatMap { configuration in chunkedClips.map { (configuration, $0) } }
                        .shuffled(using: &generator)
                    for (configuration, (seconds, chunks)) in trials {
                        let run = try await transcribe(chunks, model: model, options: options, configuration: configuration)
                        let matches = run.text == references[seconds]
                        results["\(seconds)|\(configuration.label)", default: []].append(run)
                        rows.append(
                            "\(artifact.modelName),\(load),\(seconds),\(configuration.threads),\(configuration.qos),\(round),"
                                + String(format: "%.1f,%.1f,", run.milliseconds, run.decodeMilliseconds) + "\(matches)"
                        )
                        if !matches {
                            report.append("mismatch model=\(artifact.modelName) load=\(load) clip=\(seconds)s \(configuration.label): \(run.text)")
                        }
                    }
                }

                for (seconds, _) in chunkedClips {
                    for configuration in configurations {
                        let samples = results["\(seconds)|\(configuration.label)"] ?? []
                        let mismatches = samples.filter { $0.text != references[seconds] }.count
                        report.append(
                            "model=\(artifact.modelName) load=\(load) clip=\(seconds)s \(configuration.label) "
                                + "wallMs=\(summary(samples.map(\.milliseconds))) "
                                + "decodeMs=\(summary(samples.map(\.decodeMilliseconds))) mismatches=\(mismatches)"
                        )
                    }
                }
            }
        }

        try (report + ["", "# raw"] + rows).joined(separator: "\n").appending("\n")
            .write(toFile: reportPath, atomically: true, encoding: .utf8)
    }

    /// Mirrors the offline service: one session per chunk, run synchronously at the given QoS.
    private func transcribe(
        _ chunks: [[Float]],
        model: Model,
        options: RunOptions,
        configuration: Configuration
    ) async throws -> Run {
        try await withCheckedThrowingContinuation { continuation in
            let submittedAt = ContinuousClock.now
            DispatchQueue.global(qos: configuration.qos).async {
                continuation.resume(with: Result {
                    var texts: [String] = []
                    var decodeMilliseconds = 0.0
                    for chunk in chunks {
                        let session = try model.session(SessionOptions(nThreads: configuration.threads))
                        let transcript = try session.run(chunk, options: options)
                        decodeMilliseconds += Double(transcript.timings.decodeMs)
                        let text = transcript.text.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !text.isEmpty { texts.append(text) }
                    }
                    let elapsed = submittedAt.duration(to: .now)
                    let milliseconds = Double(elapsed.components.seconds) * 1_000
                        + Double(elapsed.components.attoseconds) / 1e15
                    return Run(milliseconds: milliseconds, decodeMilliseconds: decodeMilliseconds, text: texts.joined(separator: " "))
                })
            }
        }
    }

    /// Reports the QoS that the wrapper's async `Session.run` hop receives from a main-actor pipeline task.
    private func productionPathQoS() async -> String {
        await Task { @MainActor in
            await Self.wrapperHopQoS()
        }.value
    }

    nonisolated private static func wrapperHopQoS() async -> String {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                let qos: String = switch qos_class_self() {
                case QOS_CLASS_USER_INTERACTIVE: "userInteractive"
                case QOS_CLASS_USER_INITIATED: "userInitiated"
                case QOS_CLASS_DEFAULT: "default"
                case QOS_CLASS_UTILITY: "utility"
                case QOS_CLASS_BACKGROUND: "background"
                default: "unspecified"
                }
                continuation.resume(returning: qos)
            }
        }
    }

    private func clipSpecifications(_ value: String) throws -> [(seconds: Int, offset: Int)] {
        try value.split(separator: ",").map { entry in
            let parts = entry.split(separator: "@").compactMap { Int($0) }
            guard parts.count == 2 else { throw CocoaError(.formatting) }
            return (parts[0], parts[1])
        }
    }

    private func summary(_ values: [Double]) -> String {
        guard !values.isEmpty else { return "none" }
        let sorted = values.sorted()
        func quantile(_ q: Double) -> Double {
            let position = q * Double(sorted.count - 1)
            let lower = Int(position.rounded(.down))
            let upper = min(lower + 1, sorted.count - 1)
            return sorted[lower] + (sorted[upper] - sorted[lower]) * (position - Double(lower))
        }
        return String(
            format: "n=%d,median=%.0f,p25=%.0f,p75=%.0f,min=%.0f,max=%.0f",
            sorted.count, quantile(0.5), quantile(0.25), quantile(0.75), sorted.first!, sorted.last!
        )
    }

    private func hostDescription() -> String {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        var brand = [CChar](repeating: 0, count: size)
        sysctlbyname("machdep.cpu.brand_string", &brand, &size, nil, 0)
        let cpu = String(decoding: brand.prefix { $0 != 0 }.map(UInt8.init), as: UTF8.self)
        return "\(cpu) cpus=\(ProcessInfo.processInfo.activeProcessorCount) macOS=\(ProcessInfo.processInfo.operatingSystemVersionString)"
    }
}

/// Busy-loop `yes` processes that exit on stop or when the test process exits.
private final class CPULoad {
    private let process = Process()

    init(processCount: Int) throws {
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c",
            """
            trap 'kill $(jobs -p) 2>/dev/null; exit 0' TERM
            i=0; while [ $i -lt \(processCount) ]; do yes > /dev/null & i=$((i + 1)); done
            while kill -0 \(getpid()) 2>/dev/null; do sleep 1 & wait $!; done
            kill $(jobs -p) 2>/dev/null
            """,
        ]
        process.standardOutput = FileHandle.nullDevice
        try process.run()
    }

    func stop() {
        process.terminate()
        process.waitUntilExit()
    }
}

private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}
