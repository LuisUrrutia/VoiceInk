import AppKit
import Foundation
import os

enum BrowserType {
    case safari
    case arc
    case dia
    case chrome
    case comet
    case edge
    case brave
    case opera
    case vivaldi
    case orion
    case yandex

    var scriptName: String {
        switch self {
        case .safari: return "safariURL"
        case .arc: return "arcURL"
        case .dia: return "diaURL"
        case .chrome: return "chromeURL"
        case .comet: return "cometURL"
        case .edge: return "edgeURL"
        case .brave: return "braveURL"
        case .opera: return "operaURL"
        case .vivaldi: return "vivaldiURL"
        case .orion: return "orionURL"
        case .yandex: return "yandexURL"
        }
    }

    var bundleIdentifier: String {
        switch self {
        case .safari: return "com.apple.Safari"
        case .arc: return "company.thebrowser.Browser"
        case .dia: return "company.thebrowser.dia"
        case .chrome: return "com.google.Chrome"
        case .comet: return "ai.perplexity.comet"
        case .edge: return "com.microsoft.edgemac"
        case .brave: return "com.brave.Browser"
        case .opera: return "com.operasoftware.Opera"
        case .vivaldi: return "com.vivaldi.Vivaldi"
        case .orion: return "com.kagi.kagimacOS"
        case .yandex: return "ru.yandex.desktop.yandex-browser"
        }
    }

    var displayName: String {
        switch self {
        case .safari: return "Safari"
        case .arc: return "Arc"
        case .dia: return "Dia"
        case .chrome: return "Google Chrome"
        case .comet: return "Comet"
        case .edge: return "Microsoft Edge"
        case .brave: return "Brave"
        case .opera: return "Opera"
        case .vivaldi: return "Vivaldi"
        case .orion: return "Orion"
        case .yandex: return "Yandex Browser"
        }
    }

    static var allCases: [BrowserType] {
        [.safari, .arc, .dia, .chrome, .comet, .edge, .brave, .opera, .vivaldi, .orion, .yandex]
    }

    static var installedBrowsers: [BrowserType] {
        allCases.filter { browser in
            let workspace = NSWorkspace.shared
            return workspace.urlForApplication(withBundleIdentifier: browser.bundleIdentifier) != nil
        }
    }
}

enum BrowserURLError: Error {
    case scriptNotFound
    case executionFailed
    case executionTimedOut
    case browserNotRunning
    case noActiveWindow
    case noActiveTab
}

class BrowserURLService {
    static let shared = BrowserURLService()

    private let logger = Logger(
        subsystem: "com.prakashjoshipax.voiceink",
        category: "browser.applescript"
    )
    private let scriptTimeout: TimeInterval = 1.5

    private init() {}

    func getCurrentURL(from browser: BrowserType) async throws -> String {
        guard let scriptURL = Bundle.main.url(forResource: browser.scriptName, withExtension: "scpt") else {
            logger.error("❌ AppleScript file not found: \(browser.scriptName, privacy: .public).scpt")
            throw BrowserURLError.scriptNotFound
        }

        logger.debug("🔍 Attempting to execute AppleScript for \(browser.displayName, privacy: .public)")

        // Check if browser is running
        if !isRunning(browser) {
            logger.error("❌ Browser not running: \(browser.displayName, privacy: .public)")
            throw BrowserURLError.browserNotRunning
        }

        do {
            let data = try await BrowserScriptProcess(arguments: [scriptURL.path]).run(timeout: scriptTimeout)
            return try Self.url(from: data)
        } catch let error as BrowserURLError {
            logger.error("Browser URL lookup failed for \(browser.displayName, privacy: .public)")
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            logger.error("Browser URL process failed for \(browser.displayName, privacy: .public)")
            throw BrowserURLError.executionFailed
        }
    }

    static func url(from data: Data) throws -> String {
        guard let output = String(data: data, encoding: .utf8) else {
            throw BrowserURLError.executionFailed
        }
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw BrowserURLError.noActiveTab }
        guard !trimmed.lowercased().contains("error") else { throw BrowserURLError.executionFailed }
        return trimmed
    }

    func isRunning(_ browser: BrowserType) -> Bool {
        let workspace = NSWorkspace.shared
        let runningApps = workspace.runningApplications
        let isRunning = runningApps.contains { $0.bundleIdentifier == browser.bundleIdentifier }
        logger.debug("\(browser.displayName, privacy: .public) running status: \(isRunning, privacy: .public)")
        return isRunning
    }
}
