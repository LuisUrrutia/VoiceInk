import Foundation

/// Whether a dictation's transcript is processed (cleanup, corrections, replacements, enhancement) or pasted as heard.
enum DictationProcessing: Sendable {
    case standard
    case raw
}
