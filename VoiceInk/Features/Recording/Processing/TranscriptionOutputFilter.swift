import Foundation

struct TranscriptionOutputFilter {
    static func filter(_ text: String) -> String {
        TranscriptionTextFilter.filter(text, fillerWords: FillerWordManager.shared.fillerWords)
    }
}
