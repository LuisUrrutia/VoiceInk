import Combine
import Foundation

/// An unfinished feature that people opt into from Labs. Each one is off by default and has its own switch.
///
/// To add one, define it below, append it to `all` and gate its work where that work starts (worker, capture,
/// observer) with `Labs.isEnabled(_:)` or `Labs.enabledPublisher(_:)`, not only where its interface appears.
/// The Labs page appears in the sidebar while `all` lists a feature. When a feature graduates, remove it from
/// `all`; older configuration files and backups keep loading.
struct LabsFeature: Identifiable, Sendable {
    /// Stable identifier, part of the persisted `labs.<id>` preference name. Never reuse one.
    let id: String
    let title: LocalizedStringResource
    let summary: LocalizedStringResource

    var defaultsKey: String { Labs.keyPrefix + id }
}

extension LabsFeature: Hashable {
    static func == (lhs: LabsFeature, rhs: LabsFeature) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

extension LabsFeature {
    /// Every Labs feature, in page order.
    static let all: [LabsFeature] = [.meetings]
}

enum Labs {
    static let keyPrefix = "labs."

    static func isEnabled(_ feature: LabsFeature, in defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: feature.defaultsKey)
    }

    static func setEnabled(_ isEnabled: Bool, for feature: LabsFeature, in defaults: UserDefaults = .standard) {
        defaults.set(isEnabled, forKey: feature.defaultsKey)
    }

    /// The state when subscribed, then every change made through `defaults`, for work that runs between
    /// dictations and must stop or start at once.
    static func enabledPublisher(
        _ feature: LabsFeature, in defaults: UserDefaults = .standard
    ) -> AnyPublisher<Bool, Never> {
        Deferred {
            NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification, object: defaults)
                .map { _ in isEnabled(feature, in: defaults) }
                .prepend(isEnabled(feature, in: defaults))
                .removeDuplicates()
        }
        .eraseToAnyPublisher()
    }

    static func registeredDefaults(for features: [LabsFeature] = LabsFeature.all) -> [String: Any] {
        Dictionary(uniqueKeysWithValues: features.map { ($0.defaultsKey, false) })
    }

    static func feature(forKey key: String, in features: [LabsFeature] = LabsFeature.all) -> LabsFeature? {
        features.first { $0.defaultsKey == key }
    }

    /// A `labs.` preference with no current feature: it graduated, was removed or comes from a newer build.
    static func isRetiredKey(_ key: String, features: [LabsFeature] = LabsFeature.all) -> Bool {
        key.hasPrefix(keyPrefix) && feature(forKey: key, in: features) == nil
    }

    /// Keyed by feature identifier.
    static func backup(
        of features: [LabsFeature] = LabsFeature.all, in defaults: UserDefaults = .standard
    ) -> [String: Bool] {
        Dictionary(uniqueKeysWithValues: features.map { ($0.id, isEnabled($0, in: defaults)) })
    }

    /// A feature missing from the backup keeps its current state; identifiers of features no longer in Labs are ignored.
    static func restore(
        _ backup: [String: Bool]?, features: [LabsFeature] = LabsFeature.all, in defaults: UserDefaults = .standard
    ) {
        guard let backup else { return }
        for feature in features {
            if let isEnabled = backup[feature.id] { setEnabled(isEnabled, for: feature, in: defaults) }
        }
    }
}
