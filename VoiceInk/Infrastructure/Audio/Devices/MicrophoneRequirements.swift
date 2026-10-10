import Foundation

struct MicrophoneReference: Codable, Equatable {
    let uid: String
    let name: String
    let modelUID: String?
}

struct MicrophoneApplication: Codable, Equatable {
    let bundleID: String
    let name: String
}

struct MicrophoneRequirements: Codable, Equatable {
    var microphone: MicrophoneReference?
    var application: MicrophoneApplication?

    var isEmpty: Bool { microphone == nil && application == nil }
}
