import CryptoKit
import Darwin
import Foundation

/// Shared helpers for the opt-in inference thread/QoS benchmarks.
enum InferenceBenchmark {
    static func clipSpecifications(_ value: String) throws -> [(seconds: Int, offset: Int)] {
        try value.split(separator: ",").map { entry in
            let parts = entry.split(separator: "@").compactMap { Int($0) }
            guard parts.count == 2 else { throw CocoaError(.formatting) }
            return (parts[0], parts[1])
        }
    }

    static func sha256(ofFileAt path: String) throws -> String {
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 16 << 20), !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func summary(_ values: [Double]) -> String {
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

    static func hostDescription() -> String {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        var brand = [CChar](repeating: 0, count: size)
        sysctlbyname("machdep.cpu.brand_string", &brand, &size, nil, 0)
        let cpu = String(decoding: brand.prefix { $0 != 0 }.map(UInt8.init), as: UTF8.self)
        return "\(cpu) cpus=\(ProcessInfo.processInfo.activeProcessorCount) macOS=\(ProcessInfo.processInfo.operatingSystemVersionString)"
    }

    static func label(_ qos: qos_class_t) -> String {
        switch qos {
        case QOS_CLASS_USER_INTERACTIVE: "userInteractive"
        case QOS_CLASS_USER_INITIATED: "userInitiated"
        case QOS_CLASS_DEFAULT: "default"
        case QOS_CLASS_UTILITY: "utility"
        case QOS_CLASS_BACKGROUND: "background"
        default: "unspecified"
        }
    }

    static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15
    }
}

/// Busy-loop `yes` processes that exit on stop or when the test process exits.
final class CPULoad {
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

struct SeededGenerator: RandomNumberGenerator {
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
