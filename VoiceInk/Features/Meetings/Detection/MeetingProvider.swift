import Foundation

/// A call app VoiceInk recognizes, as Hex's `KNOWN_MEETING_PROVIDERS`. The raw value is the stable identifier in
/// `meeting.json`, policies and backups.
enum MeetingProvider: String, CaseIterable, Codable, Sendable {
    case zoom, meet, slack, teams, facetime

    var displayName: String {
        switch self {
        case .zoom: "Zoom"
        case .meet: "Google Meet"
        case .slack: String(localized: "Slack huddles")
        case .teams: "Microsoft Teams"
        case .facetime: "FaceTime"
        }
    }

    /// The name used in a detected meeting's title.
    var callName: String {
        switch self {
        case .zoom: String(localized: "Zoom meeting")
        case .meet: String(localized: "Google Meet")
        case .slack: String(localized: "Slack huddle")
        case .teams: String(localized: "Microsoft Teams meeting")
        case .facetime: String(localized: "FaceTime call")
        }
    }

    /// Native call apps by the bundle identifiers of a process using the microphone or its ancestors.
    static func nativeProvider(forBundleIDs bundleIDs: [String]) -> MeetingProvider? {
        for id in bundleIDs {
            if id.hasPrefix("us.zoom.") { return .zoom }
            if id.hasPrefix("com.microsoft.teams") { return .teams }
            if id.hasPrefix("com.tinyspeck.slackmacgap") { return .slack }
            if id == "com.apple.avconferenced" || id == "com.apple.FaceTime" { return .facetime }
        }
        return nil
    }

    /// A supported browser among the bundle identifiers, for Google Meet.
    static func browser(forBundleIDs bundleIDs: [String]) -> BrowserType? {
        for id in bundleIDs {
            if let browser = BrowserType.allCases.first(where: { id == $0.bundleIdentifier || id.hasPrefix($0.bundleIdentifier + ".") }) {
                return browser
            }
        }
        return nil
    }

    /// A Google Meet call page, not its landing or new-meeting pages.
    static func isMeetCall(_ urlString: String) -> Bool {
        guard let url = URL(string: urlString), url.host?.lowercased() == "meet.google.com" else { return false }
        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return !path.isEmpty && !["landing", "new"].contains(path.lowercased())
    }
}

/// What to do when a provider's call starts.
enum MeetingProviderPolicy: String, CaseIterable, Codable, Sendable {
    case ask, alwaysRecord = "always_record", neverOffer = "never_offer"

    var displayName: String {
        switch self {
        case .ask: String(localized: "Ask")
        case .alwaysRecord: String(localized: "Always record")
        case .neverOffer: String(localized: "Never offer")
        }
    }
}
