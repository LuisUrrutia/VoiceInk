import Foundation
import LLMkit

/// A short summary of a transcribed meeting, adapted from Hex's notes (`src/meeting_notes.rs`, MIT): the same
/// instructions without the title, the same excerpt of long meetings and the same limits.
enum MeetingSummary {
    static let maximumExcerptCharacters = 12_000
    /// Long turns are split so a monologue can still be sampled.
    static let lineCharacters = 600
    static let gapMarker = "[…]"
    static let maximumSentences = 2
    static let maximumCharacters = 400
    static let timeout: TimeInterval = 60

    static let instructions = """
        You summarize meeting transcripts. Each line starts with a timestamp and a speaker label: You is the person \
        who recorded the meeting, and Them is one or more other participants. A long meeting is excerpted, and […] \
        marks skipped parts. Write a summary of at most two short sentences on the main topics and outcomes. Use \
        only what the transcript says; never invent names, dates, or numbers. Reply with the summary only.
        """

    /// Turns as `[mm:ss] You: text` lines, split at word boundaries so no line exceeds `lineCharacters`.
    static func lines(_ turns: [MeetingTranscriptEntry]) -> [String] {
        var lines: [String] = []
        for turn in turns {
            let prefix = "[\(MeetingMarkdown.timestamp(turn.start))] \(turn.speaker.label): "
            var line = prefix
            for word in turn.text.split(whereSeparator: \.isWhitespace) {
                if line.count > prefix.count, line.count + 1 + word.count > lineCharacters {
                    lines.append(line)
                    line = prefix
                }
                if line.count > prefix.count { line += " " }
                line += word
            }
            if line.count > prefix.count { lines.append(line) }
        }
        return lines
    }

    /// The whole transcript when it fits; otherwise the opening (30 %), up to six evenly spaced middle passages and
    /// the ending (20 %), with gap markers between them, as Hex does.
    static func excerpt(_ lines: [String], maximumCharacters: Int = maximumExcerptCharacters) -> String {
        func size(_ range: Range<Int>) -> Int { lines[range].reduce(0) { $0 + $1.count } + max(0, range.count - 1) }
        guard size(0..<lines.count) > maximumCharacters else { return lines.joined(separator: "\n") }
        let gap = gapMarker.count + 2
        let windows = min(max(maximumCharacters / 2_000, 1), 6)
        let usable = max(0, maximumCharacters - (windows + 1) * gap)
        func takeForward(_ start: Int, _ end: Int, _ budget: Int) -> Int {
            var stop = start
            var used = 0
            while stop < end, used + lines[stop].count < budget {
                used += lines[stop].count + 1
                stop += 1
            }
            return stop
        }
        let headEnd = takeForward(0, lines.count, usable * 3 / 10)
        var tailStart = lines.count
        var used = 0
        while tailStart > headEnd, used + lines[tailStart - 1].count < usable / 5 {
            used += lines[tailStart - 1].count + 1
            tailStart -= 1
        }
        var ranges = [0..<headEnd]
        let middle = max(0, tailStart - headEnd)
        let windowBudget = (usable - usable * 3 / 10 - usable / 5) / windows
        for index in 0..<windows {
            let center = headEnd + (2 * index + 1) * middle / (2 * windows)
            let start = max(center, ranges.last?.upperBound ?? 0)
            let end = takeForward(start, tailStart, windowBudget)
            if end > start { ranges.append(start..<end) }
        }
        ranges.append(tailStart..<lines.count)

        var text = ""
        var previousEnd = 0
        for range in ranges where !range.isEmpty {
            if !text.isEmpty { text += "\n" }
            if range.lowerBound > previousEnd { text += gapMarker + "\n" }
            text += lines[range].joined(separator: "\n")
            previousEnd = range.upperBound
        }
        if previousEnd < lines.count { text += "\n" + gapMarker }
        return text
    }

    /// At most two sentences and 400 characters of the model's reply, or nil when it says nothing.
    static func cleaned(_ reply: String) -> String? {
        var text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.lowercased().hasPrefix("summary:") { text = String(text.dropFirst(8)).trimmingCharacters(in: .whitespaces) }
        text = text.split(whereSeparator: \.isNewline).joined(separator: " ")
        var sentences: [String] = []
        text.enumerateSubstrings(in: text.startIndex..., options: .bySentences) { sentence, _, _, stop in
            if let sentence = sentence?.trimmingCharacters(in: .whitespaces), !sentence.isEmpty { sentences.append(sentence) }
            if sentences.count == maximumSentences { stop = true }
        }
        var summary = sentences.joined(separator: " ")
        if summary.count > maximumCharacters {
            summary = String(summary.prefix(maximumCharacters - 1)).trimmingCharacters(in: .whitespaces) + "…"
        }
        return summary.isEmpty ? nil : summary
    }
}

/// Sends a prompt to the user's AI provider and returns its reply.
protocol MeetingSummarizing {
    func reply(to transcript: String, instructions: String) async throws -> String
}

/// The provider and model currently selected for enhancement.
@MainActor
struct EnhancementProviderSummarizer: MeetingSummarizing {
    let aiService: AIService

    func reply(to transcript: String, instructions: String) async throws -> String {
        try await aiService.performChatCompletion(
            provider: aiService.selectedProvider, modelName: aiService.currentModel,
            messages: [ChatMessage.user(transcript)], systemPrompt: instructions, localUserPrompt: transcript,
            timeout: MeetingSummary.timeout
        ).text
    }
}
