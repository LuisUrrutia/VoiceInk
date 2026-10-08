import Foundation
import SwiftData
import XCTest
@testable import VoiceInk

@MainActor
final class SharedTranscriptionTextTests: XCTestCase {
    func testAppFilterUsesSharedImplementation() {
        let input = "um, Café [music] <context>private</context> 東京."

        let app = TranscriptionOutputFilter.filter(input)
        let shared = TranscriptionTextFilter.filter(input, fillerWords: FillerWordManager.shared.fillerWords)

        XCTAssertEqual(app, shared)
    }

    func testAppReplacementPolicyAndLiteralReplacementRemainCompatible() throws {
        let schema = Schema([WordReplacement.self])
        let configuration = ModelConfiguration("dictionary", schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: configuration)
        let context = ModelContext(container)
        let rule = WordReplacement(originalText: "web socket, websock", replacementText: "$1\\WebSocket")
        rule.isEnabled = false
        context.insert(rule)
        try context.save()

        let result = WordReplacementService.shared.applyReplacements(to: "web socket and websock; websocking", using: context)
        let count = try context.fetchCount(FetchDescriptor<WordReplacement>())

        XCTAssertEqual(result, "$1\\WebSocket and $1\\WebSocket; websocking")
        XCTAssertEqual(count, 1)
        XCTAssertFalse(rule.isEnabled)
    }

    func testRegisteredDefaultsAndFillerDefaultsShareTheirAuthority() {
        XCTAssertEqual(TranscriptionTextDefaults.preferences["IsVADEnabled"] as? Bool, true)
        XCTAssertEqual(TranscriptionTextDefaults.preferences["IsTextFormattingEnabled"] as? Bool, true)
        XCTAssertEqual(TranscriptionTextDefaults.preferences["SelectedLanguage"] as? String, "en")
        XCTAssertEqual(FillerWordManager.defaultFillerWords, TranscriptionTextDefaults.fillerWords)
    }
}
