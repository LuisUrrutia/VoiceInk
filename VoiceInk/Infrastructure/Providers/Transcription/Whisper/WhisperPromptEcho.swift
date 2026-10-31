import Foundation

/// The prompt sent to a Whisper decoder, and the echo check for its output.
///
/// Whisper reads the prompt as preceding text and, on silence or noise, can return it verbatim.
/// Adapted from Hex's `drop_prompt_echo` (MIT, https://github.com/anomalyco/hex): output equal to
/// the hints is dropped only when there are at least two, so dictating the one listed term is kept.
/// The language prompt alone is a sample sentence that users can dictate, so it never matches.
struct WhisperPromptEcho {
    let prompt: String
    private let echoes: Set<String>

    init(languagePrompt: String?, hints: [String]) {
        let hintList = hints.joined(separator: ", ")
        let languagePrompt = languagePrompt ?? ""
        prompt = [languagePrompt, hintList].filter { !$0.isEmpty }.joined(separator: "\n")
        var echoes: [String] = []
        if hints.count >= 2 { echoes.append(hintList) }
        if !languagePrompt.isEmpty, !hints.isEmpty { echoes.append(prompt) }
        self.echoes = Set(echoes.map(Self.normalized).filter { !$0.isEmpty })
    }

    /// Removes segments that only repeat the prompt, and every segment when together they repeat it.
    func removingEcho(from segments: [String]) -> [String] {
        guard !echoes.isEmpty else { return segments }
        if echoes.contains(Self.normalized(segments.joined(separator: " "))) { return [] }
        return segments.filter { !echoes.contains(Self.normalized($0)) }
    }

    private static let digitWords = [
        "zero": "0", "one": "1", "two": "2", "three": "3", "four": "4",
        "five": "5", "six": "6", "seven": "7", "eight": "8", "nine": "9",
    ]

    /// Case, width and punctuation are ignored; punctuation and spacing separate words.
    private static func normalized(_ text: String) -> String {
        text.precomposedStringWithCompatibilityMapping.lowercased()
            .components(separatedBy: CharacterSet.punctuationCharacters.union(.whitespacesAndNewlines))
            .filter { !$0.isEmpty }
            .map { digitWords[$0] ?? $0 }
            .joined(separator: " ")
    }
}
