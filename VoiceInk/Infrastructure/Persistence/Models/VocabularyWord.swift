import Foundation
import SwiftData

struct VocabularyWordIdentity: Hashable, Sendable {
    let normalizedWord: String
    let sectionID: UUID?

    init(word: String, sectionID: UUID?) {
        let normalized = word
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCanonicalMapping
        normalizedWord = (normalized as NSString).folding(options: .caseInsensitive, locale: nil)
        self.sectionID = sectionID
    }
}

@Model
final class VocabularyWord {
    var word: String = ""
    var dateAdded: Date = Date()
    var sectionID: UUID?
    /// Comma-separated "sounds like" spellings; a defaulted string keeps lightweight migration and CloudKit sync simple.
    var soundsLikeText: String = ""

    init(word: String, dateAdded: Date = Date(), sectionID: UUID? = nil, soundsLike: [String] = []) {
        self.word = word
        self.dateAdded = dateAdded
        self.sectionID = sectionID
        self.soundsLikeText = VocabularySoundsLike.serialize(soundsLike)
    }

    /// Spellings a transcript may show instead of the term; used only by the enhancement prompt.
    var soundsLike: [String] {
        get { VocabularySoundsLike.parse(soundsLikeText) }
        set { soundsLikeText = VocabularySoundsLike.serialize(newValue) }
    }
}
