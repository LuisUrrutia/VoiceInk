import Foundation

public enum TranscriptionTextDefaults {
    public static let preferences: [String: Any] = [
        "IsTextFormattingEnabled": true,
        "IsVADEnabled": true,
        "SelectedLanguage": "en",
    ]
    public static let fillerWords = [
        "uh", "um", "uhm", "umm", "uhh", "uhhh",
        "hmm", "hm", "mmm", "mm", "mh", "ehh",
    ]
}
