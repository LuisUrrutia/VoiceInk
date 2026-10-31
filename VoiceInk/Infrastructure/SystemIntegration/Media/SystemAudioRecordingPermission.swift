import Foundation

/// The "System Audio Recording" consent that process taps need (TCC `kTCCServiceAudioCapture`).
/// Screen Recording consent does not imply it.
enum SystemAudioRecordingAuthorization: Equatable, Sendable {
    case granted, denied, notDetermined
    /// macOS offers no public query; when the private one is missing the state is unknown.
    case unknown
}

protocol SystemAudioRecordingPermissionChecking: Sendable {
    func authorization() -> SystemAudioRecordingAuthorization
    /// Shows the macOS prompt when consent is undecided; returns whether it asked.
    func request(completion: @escaping @Sendable (Bool) -> Void) -> Bool
}

/// Reads and requests the consent through TCC, loaded at runtime so a missing
/// symbol leaves the state unknown instead of failing to launch.
struct TCCSystemAudioRecordingPermission: SystemAudioRecordingPermissionChecking {
    private typealias Preflight = @convention(c) (CFString, CFDictionary?) -> Int32
    private typealias Request = @convention(c) (CFString, CFDictionary?, @escaping @convention(block) (Bool) -> Void) -> Void

    private struct Functions: @unchecked Sendable {
        let preflight: Preflight
        let request: Request
    }

    private static let service = "kTCCServiceAudioCapture" as CFString

    private static let functions: Functions? = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW),
            let preflight = dlsym(handle, "TCCAccessPreflight"),
            let request = dlsym(handle, "TCCAccessRequest")
        else { return nil }
        return Functions(
            preflight: unsafeBitCast(preflight, to: Preflight.self),
            request: unsafeBitCast(request, to: Request.self)
        )
    }()

    func authorization() -> SystemAudioRecordingAuthorization {
        guard let functions = Self.functions else { return .unknown }
        switch functions.preflight(Self.service, nil) {
        case 0: return .granted
        case 1: return .denied
        default: return .notDetermined
        }
    }

    func request(completion: @escaping @Sendable (Bool) -> Void) -> Bool {
        guard authorization() == .notDetermined, let functions = Self.functions else { return false }
        functions.request(Self.service, nil) { granted in completion(granted) }
        return true
    }
}
