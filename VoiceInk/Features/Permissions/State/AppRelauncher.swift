import AppKit
import os

/// Relaunches VoiceInk so macOS applies a permission it grants only to a fresh process.
@MainActor
struct AppRelauncher {
    /// Waits up to 30 s for the process to exit, so a cancelled termination never relaunches later.
    nonisolated static let waitScript = """
        pid="$1"; shift; n=0
        while kill -0 "$pid" 2>/dev/null; do
          n=$((n + 1)); [ "$n" -ge 300 ] && exit 0; sleep 0.1
        done
        exec "$@"
        """

    var isBusy: () -> Bool
    var bundleURL: URL = Bundle.main.bundleURL
    var processIdentifier: Int32 = ProcessInfo.processInfo.processIdentifier
    var launchHelper: (_ processIdentifier: Int32, _ command: [String]) throws -> Void = AppRelauncher.launchWaitingHelper
    var terminate: () -> Void = { NSApplication.shared.terminate(nil) }
    var gate: AppRelaunchGate = .shared

    private static let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "AppRelauncher")

    /// A recording, its pipeline or a microphone test must finish first so its audio and History are kept.
    var canRelaunch: Bool { !gate.isPending && !isBusy() }

    static func blocksRelaunch(recordingState: RecordingState, microphoneTestBusy: Bool) -> Bool {
        recordingState != .idle || microphoneTestBusy
    }

    @discardableResult
    func relaunch() -> Bool {
        guard canRelaunch else { return false }
        do {
            // -n opens this exact bundle even when another copy with the same identifier is running.
            try launchHelper(processIdentifier, ["/usr/bin/open", "-n", bundleURL.path])
        } catch {
            Self.logger.error("Could not start the relaunch helper: \(error.localizedDescription, privacy: .public)")
            return false
        }
        gate.isPending = true
        terminate()
        return true
    }

    nonisolated static func launchWaitingHelper(processIdentifier: Int32, command: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", waitScript, "voiceink-relaunch", String(processIdentifier)] + command
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }
}

@MainActor
final class AppRelaunchGate {
    static let shared = AppRelaunchGate()
    var isPending = false
}

extension VoiceInkEngine {
    var relauncher: AppRelauncher {
        AppRelauncher(isBusy: { [weak self] in
            guard let self else { return true }
            return AppRelauncher.blocksRelaunch(
                recordingState: self.recordingState, microphoneTestBusy: self.microphoneDiagnostic.isBusy
            )
        })
    }
}
