import Foundation
import os

/// macOS "System Audio Recording" consent (TCC `kTCCServiceAudioCapture`), which process taps need.
/// Screen Recording consent does not imply it, and a denied tap delivers silence rather than an error.
enum SystemAudioAuthorization: Equatable, Sendable {
    case granted, denied, notDetermined
    /// The private TCC query is unavailable; the tap is tried and macOS asks.
    case unknown

    var allowsCapture: Bool { self == .granted || self == .unknown }
}

protocol SystemAudioAuthorizing: Sendable {
    func status() -> SystemAudioAuthorization
    /// Shows the macOS prompt when consent is undecided and returns the answer.
    func request() async -> SystemAudioAuthorization
}

/// Uses the private `TCCAccessPreflight` and `TCCAccessRequest`, the only way to read this consent: Apple
/// offers no public API. A missing symbol degrades to `.unknown`, never to a crash.
struct TCCSystemAudioAuthorization: SystemAudioAuthorizing {
    private typealias Preflight = @convention(c) (CFString, CFDictionary?) -> Int32
    private typealias Request = @convention(c) (CFString, CFDictionary?, @convention(block) (Bool) -> Void) -> Void

    private struct Symbols: @unchecked Sendable {
        let preflight: Preflight
        let request: Request
    }

    private static let service = "kTCCServiceAudioCapture" as CFString
    private static let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "SystemAudioPermission")

    private static let symbols: Symbols? = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW),
            let preflight = dlsym(handle, "TCCAccessPreflight"),
            let request = dlsym(handle, "TCCAccessRequest")
        else {
            logger.warning("TCC symbols unavailable; System Audio Recording consent cannot be read")
            return nil
        }
        return Symbols(
            preflight: unsafeBitCast(preflight, to: Preflight.self),
            request: unsafeBitCast(request, to: Request.self)
        )
    }()

    func status() -> SystemAudioAuthorization {
        guard let symbols = Self.symbols else { return .unknown }
        switch symbols.preflight(Self.service, nil) {
        case 0: return .granted
        case 1: return .denied
        default: return .notDetermined
        }
    }

    func request() async -> SystemAudioAuthorization {
        guard status() == .notDetermined, let symbols = Self.symbols else { return status() }
        let granted = await withCheckedContinuation { continuation in
            symbols.request(Self.service, nil) { granted in continuation.resume(returning: granted) }
        }
        Self.logger.notice("System Audio Recording consent answered granted=\(granted, privacy: .public)")
        return granted ? .granted : status()
    }
}
