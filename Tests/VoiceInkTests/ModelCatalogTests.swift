import XCTest
@testable import VoiceInk

@MainActor
final class ModelCatalogTests: XCTestCase {
    private let apple = NativeAppleModel(
        name: "apple-speech", displayName: "Apple Speech", description: "Built in",
        isMultilingualModel: true, supportedLanguages: ["en": "English", "es": "Spanish"]
    )
    private let parakeet = FluidAudioModel(
        name: "parakeet", displayName: "Parakeet", description: "Speech",
        size: "474 MB", speed: 0.99, accuracy: 0.94, ramUsage: 0.8,
        supportedLanguages: ["en": "English"]
    )
    private let cohere = TranscribeCppModel(
        name: "cohere", displayName: "Cohere", description: "Speech",
        size: "1.56 GB", speed: 0.75, accuracy: 0.95, ramUsage: 2.5,
        publisher: "Cohere", supportedLanguages: ["en": "English"]
    )
    private let tiny = WhisperModel(
        name: "tiny", displayName: "Tiny", size: "75 MB", supportedLanguages: ["en": "English"],
        description: "Speech", speed: 0.95, accuracy: 0.6, ramUsage: 0.3
    )

    func testDefaultOrderExcludesCloudAndCustomModels() {
        let cloud = CloudModel(
            name: "cloud", displayName: "Cloud", description: "Speech", provider: .groq,
            isMultilingual: true, supportedLanguages: ["en": "English"]
        )
        let custom = CustomCloudModel(
            name: "custom", displayName: "Custom", description: "Speech",
            apiEndpoint: "https://example.com/transcriptions", modelName: "custom"
        )

        let result = models([apple, cloud, parakeet, custom, cohere, tiny])

        XCTAssertEqual(result.map(\.name), ["apple-speech", "parakeet", "cohere", "tiny"])
    }

    func testSpeedSortComparesAllLocalBackendsAndPlacesUnratedModelsLast() {
        let imported = ImportedWhisperModel(fileBaseName: "imported")

        let result = models([apple, tiny, cohere, imported, parakeet], sortOrder: .speed)

        XCTAssertEqual(result.map(\.name), ["parakeet", "tiny", "cohere", "apple-speech", "imported"])
    }

    func testAccuracySortUsesHighestScoreFirst() {
        let result = models([apple, tiny, parakeet, cohere], sortOrder: .accuracy)

        XCTAssertEqual(result.map(\.name), ["cohere", "parakeet", "tiny", "apple-speech"])
    }

    func testEqualRatingsPreserveCatalogOrder() {
        let equalRating = WhisperModel(
            name: "another-tiny", displayName: "Another Tiny", size: "75 MB",
            supportedLanguages: ["en": "English"], description: "Speech",
            speed: tiny.speed, accuracy: tiny.accuracy, ramUsage: 0.3
        )

        for order in [ModelCatalogSortOrder.speed, .accuracy] {
            let result = models([tiny, equalRating], sortOrder: order)

            XCTAssertEqual(result.map(\.name), ["tiny", "another-tiny"])
        }
    }

    func testInstallationFiltersIncludeBuiltInAndImportedModels() {
        let imported = ImportedWhisperModel(fileBaseName: "imported")
        let catalog: [any TranscriptionModel] = [apple, parakeet, cohere, tiny, imported]
        let installed: Set<String> = ["parakeet", "cohere", "imported"]

        let installedModels = models(catalog, installation: .installed, installedNames: installed)
        let missingModels = models(catalog, installation: .notInstalled, installedNames: installed)

        XCTAssertEqual(installedModels.map(\.name), ["apple-speech", "parakeet", "cohere", "imported"])
        XCTAssertEqual(missingModels.map(\.name), ["tiny"])
    }

    func testInstallationChangesAreReflectedWithoutChangingSortOrder() {
        let catalog: [any TranscriptionModel] = [tiny, cohere, parakeet]
        let beforeDownload = models(catalog, installation: .installed, sortOrder: .speed)

        let afterDownload = models(
            catalog, installation: .installed, sortOrder: .speed, installedNames: ["tiny", "parakeet"]
        )
        let afterDeletion = models(
            catalog, installation: .installed, sortOrder: .speed, installedNames: ["tiny"]
        )

        XCTAssertTrue(beforeDownload.isEmpty)
        XCTAssertEqual(afterDownload.map(\.name), ["parakeet", "tiny"])
        XCTAssertEqual(afterDeletion.map(\.name), ["tiny"])
    }

    func testNameSortUsesNaturalOrder() {
        let model10 = ImportedWhisperModel(fileBaseName: "Model 10")
        let model2 = ImportedWhisperModel(fileBaseName: "Model 2")

        let result = models([model10, tiny, model2, apple], sortOrder: .name)

        XCTAssertEqual(result.map(\.displayName), ["Apple Speech", "Model 2", "Model 10", "Tiny"])
    }

    func testCategoriesFilterProvidersByCapability() throws {
        let groq = try XCTUnwrap(CloudProviderRegistry.allProviders.first { $0.modelProvider == .groq })
        let speechOnly = ProviderDescriptor(
            displayName: "Speech", providerKey: "Speech", aiProvider: nil, cloudProvider: groq
        )
        let enhancementOnly = ProviderDescriptor(
            displayName: "Enhancement", providerKey: "Enhancement", aiProvider: .anthropic, cloudProvider: nil
        )
        let both = ProviderDescriptor(
            displayName: "Both", providerKey: "Both", aiProvider: .groq, cloudProvider: groq
        )
        let providers = [speechOnly, enhancementOnly, both]

        let speech = providers.filter { ModelCatalogCategory.speech.includes($0) }
        let enhancement = providers.filter { ModelCatalogCategory.enhancement.includes($0) }

        XCTAssertEqual(speech.map(\.id), ["Speech", "Both"])
        XCTAssertEqual(enhancement.map(\.id), ["Enhancement", "Both"])
    }

    private func models(
        _ models: [any TranscriptionModel],
        installation: ModelInstallationFilter = .all,
        sortOrder: ModelCatalogSortOrder = .catalog,
        installedNames: Set<String> = []
    ) -> [any TranscriptionModel] {
        ModelCatalog.localSpeechModels(
            from: models, installation: installation, sortOrder: sortOrder,
            isInstalled: { installedNames.contains($0.name) }
        )
    }
}
