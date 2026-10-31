import Foundation

/// Selects one VoiceInk build's isolated preferences and persistence without opening its stores.
public enum AppNamespace: String, CaseIterable, Sendable {
    case production, development, local

    public var domain: String {
        switch self {
        case .production, .local: return VoiceInkPersistence.productionDirectoryName
        case .development: return VoiceInkPersistence.productionDirectoryName + ".dev"
        }
    }

    public var storeDirectoryName: String {
        VoiceInkPersistence.directoryName(bundleIdentifier: domain, isLocalBuild: self == .local)
    }
}
