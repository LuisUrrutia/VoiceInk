import AppKit
import os

/// Chromium 155 and 156 on macOS can drop a synthetic Command-V that races
/// Chromium's own pasteboard change notification. The check arrived with
/// https://chromium-review.googlesource.com/c/chromium/src/+/8217390 and the
/// token mismatch is fixed by
/// https://chromium-review.googlesource.com/c/chromium/src/+/8503629 in 157.
/// Remove this path once Chromium 157 is the oldest engine in use.
@MainActor
final class ChromiumPasteRace {
    static let affectedMajorVersions = 155...156

    private static let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "ChromiumPasteRace")
    private static let cacheLimit = 32

    private let bundleURL: (PasteApplication) -> URL?
    private var cache: [PasteApplication: Bool] = [:]

    init(bundleURL: @escaping (PasteApplication) -> URL? = { $0.runningApplication?.bundleURL }) {
        self.bundleURL = bundleURL
    }

    /// Cached per process launch: a running process keeps its engine until relaunch.
    func losesSyntheticPaste(_ application: PasteApplication) -> Bool {
        if let cached = cache[application] { return cached }
        guard let bundle = bundleURL(application) else { return false }
        let startedAt = ProcessInfo.processInfo.systemUptime
        let majors = Self.chromiumMajorVersions(inBundleAt: bundle)
        let affected = majors.contains(where: Self.affectedMajorVersions.contains)
        if cache.count >= Self.cacheLimit { cache.removeAll() }
        cache[application] = affected
        if !majors.isEmpty {
            let elapsedMicroseconds = Int((ProcessInfo.processInfo.systemUptime - startedAt) * 1_000_000)
            Self.logger.notice(
                "Chromium engine app=\(application.bundleIdentifier ?? "unknown", privacy: .public) majors=\(majors.sorted().map(String.init).joined(separator: ","), privacy: .public) typesInsteadOfPasting=\(affected, privacy: .public) elapsedUs=\(elapsedMicroseconds, privacy: .public)"
            )
        }
        return affected
    }

    /// Chromium apps ship `Contents/Frameworks/<Name> Framework.framework/Versions/<a.b.c.d>/`.
    /// Every version folder counts, so a staged update is covered whichever version runs.
    /// Frameworks with an opaque folder such as `Versions/A` (Arc's ArcCore, CEF) are
    /// classified by a four-part `CFBundleShortVersionString`; Electron declares none.
    nonisolated static func chromiumMajorVersions(
        inBundleAt bundle: URL, fileManager: FileManager = .default
    ) -> Set<Int> {
        let frameworks = bundle.appending(path: "Contents/Frameworks", directoryHint: .isDirectory)
        var majors = Set<Int>()
        for framework in contents(of: frameworks, fileManager: fileManager) where framework.pathExtension == "framework" {
            let versions = framework.appending(path: "Versions", directoryHint: .isDirectory)
            for version in contents(of: versions, fileManager: fileManager) where version.lastPathComponent != "Current" {
                if framework.lastPathComponent.hasSuffix("Framework.framework"),
                    let major = majorVersion(version.lastPathComponent)
                {
                    majors.insert(major)
                } else if let major = declaredMajorVersion(of: version) {
                    majors.insert(major)
                }
            }
        }
        return majors
    }

    /// Chromium versions have four numeric components; Brave prefixes its own
    /// version with Chromium's major (`156.1.98.60`).
    nonisolated static func majorVersion(_ version: String) -> Int? {
        let components = version.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 4, components.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber } })
        else { return nil }
        return Int(components[0])
    }

    private nonisolated static func declaredMajorVersion(of version: URL) -> Int? {
        let plist = version.appending(path: "Resources/Info.plist", directoryHint: .notDirectory)
        guard let info = NSDictionary(contentsOf: plist),
            let shortVersion = info["CFBundleShortVersionString"] as? String
        else { return nil }
        return majorVersion(shortVersion)
    }

    private nonisolated static func contents(of directory: URL, fileManager: FileManager) -> [URL] {
        (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
    }
}
