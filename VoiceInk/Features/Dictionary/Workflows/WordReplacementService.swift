import Foundation
import SwiftData
import os

@MainActor
final class WordReplacementService {
    static let shared = WordReplacementService()
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "WordReplacementService")
    private var cachedRules: [ReplacementRule]?
    private var cachedPlan = WordReplacementPlan(rules: [])

    private init() {}

    func applyReplacements(to text: String, using context: ModelContext) -> String {
        do {
            // The persisted isEnabled field is compatibility data; app rules remain active.
            let rules = try context.fetch(FetchDescriptor<WordReplacement>()).map {
                ReplacementRule(id: $0.id.uuidString, sources: WordReplacementVariants.parse($0.originalText),
                                replacement: $0.replacementText, dateAdded: $0.dateAdded)
            }.sorted { $0.id < $1.id }
            if cachedRules != rules {
                cachedPlan = WordReplacementPlan(rules: rules)
                cachedRules = rules
            }
            return cachedPlan.apply(to: text)
        } catch {
            logger.error("Could not load word replacements: \(error, privacy: .public)")
            return text
        }
    }
}
