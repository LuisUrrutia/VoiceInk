import SwiftUI

enum ModelCatalogCategory: String, CaseIterable, Identifiable {
    case speech
    case enhancement

    var id: Self { self }

    var title: LocalizedStringKey {
        switch self {
        case .speech: "Speech Models"
        case .enhancement: "Enhancement Models"
        }
    }

    func includes(_ provider: ProviderDescriptor) -> Bool {
        switch self {
        case .speech: provider.hasTranscription
        case .enhancement: provider.hasEnhancement
        }
    }
}

enum ModelCatalogSource: String, CaseIterable, Identifiable {
    case local
    case cloud
    case custom

    var id: Self { self }

    var title: LocalizedStringKey {
        switch self {
        case .local: "Local"
        case .cloud: "Cloud"
        case .custom: "Custom"
        }
    }
}

enum ModelInstallationFilter: String, CaseIterable, Identifiable {
    case all
    case installed
    case notInstalled

    var id: Self { self }

    var title: LocalizedStringKey {
        switch self {
        case .all: "All Models"
        case .installed: "Installed"
        case .notInstalled: "Not Installed"
        }
    }

    func includes(isInstalled: Bool) -> Bool {
        switch self {
        case .all: true
        case .installed: isInstalled
        case .notInstalled: !isInstalled
        }
    }
}

enum ModelCatalogSortOrder: String, CaseIterable, Identifiable {
    case catalog
    case speed
    case accuracy
    case name

    var id: Self { self }

    var title: LocalizedStringKey {
        switch self {
        case .catalog: "Default Order"
        case .speed: "Speed (Fastest First)"
        case .accuracy: "Accuracy (Highest First)"
        case .name: "Name (A–Z)"
        }
    }

    fileprivate func score(for model: any TranscriptionModel) -> Double? {
        let performance: (speed: Double, accuracy: Double)
        switch model {
        case let model as WhisperModel:
            performance = (model.speed, model.accuracy)
        case let model as FluidAudioModel:
            performance = (model.speed, model.accuracy)
        case let model as TranscribeCppModel:
            performance = (model.speed, model.accuracy)
        default:
            return nil
        }
        return self == .speed ? performance.speed : performance.accuracy
    }
}

enum ModelCatalog {
    static func localSpeechModels(
        from models: [any TranscriptionModel],
        installation: ModelInstallationFilter,
        sortOrder: ModelCatalogSortOrder,
        isInstalled: (any TranscriptionModel) -> Bool
    ) -> [any TranscriptionModel] {
        let filtered = models.filter { model in
            switch model.provider {
            case .nativeApple:
                return installation.includes(isInstalled: true)
            case .whisper, .fluidAudio, .transcribeCpp:
                return installation.includes(isInstalled: isInstalled(model))
            default:
                return false
            }
        }

        guard sortOrder != .catalog else { return filtered }

        return filtered.enumerated().sorted { first, second in
            if sortOrder == .name {
                let comparison = first.element.displayName.localizedStandardCompare(second.element.displayName)
                if comparison != .orderedSame { return comparison == .orderedAscending }
            } else {
                let firstScore = sortOrder.score(for: first.element)
                let secondScore = sortOrder.score(for: second.element)
                switch (firstScore, secondScore) {
                case (.some(let lhs), .some(let rhs)) where lhs != rhs:
                    return lhs > rhs
                case (.some, .none):
                    return true
                case (.none, .some):
                    return false
                default:
                    break
                }
            }
            return first.offset < second.offset
        }.map(\.element)
    }
}
