import AppKit
import Combine
import Foundation
import os

/// Watches which call apps use the microphone while Meetings and call detection are on, and applies each
/// provider's policy: offer to record, record automatically, or stay quiet. A recording never stops by itself;
/// when its app leaves the call, VoiceInk asks.
@MainActor
final class MeetingCallMonitor {
    static let shared = MeetingCallMonitor()

    struct Dependencies {
        var processes: any AudioInputProcessListing = CoreAudioInputProcessListing()
        /// The front tab's URL, read only when Automation is already allowed for that browser.
        var browserURL: @MainActor (BrowserType) async -> String? = { browser in
            guard MeetingCallMonitor.canAutomate(browser) else { return nil }
            return try? await BrowserURLService.shared.getCurrentURL(from: browser)
        }
        var prompt: any MeetingCallPrompting = MeetingCallPromptPanel.shared
        var recorder: MeetingRecorder = .shared
        var defaults: UserDefaults = .standard
        var now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
        var pollInterval: Duration = .seconds(1)
        var offerTimeout: Duration = .seconds(20)
        /// A browser's URL is read at most this often while it uses the microphone.
        var browserQueryInterval: TimeInterval = 2
    }

    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "MeetingCallMonitor")
    private let dependencies: Dependencies
    private var detector = CallDetector()
    private var pollTask: Task<Void, Never>?
    private var settingsCancellable: AnyCancellable?
    private var recordingCancellable: AnyCancellable?
    private var browserMeet: [BrowserType: (checkedAt: TimeInterval, isMeet: Bool)] = [:]
    private var pendingStopProvider: MeetingProvider?
    private var pendingOfferProvider: MeetingProvider?

    init(dependencies: Dependencies = Dependencies()) {
        self.dependencies = dependencies
    }

    /// Polls only while Meetings and call detection are both on.
    func start() {
        guard settingsCancellable == nil else { return }
        let defaults = dependencies.defaults
        settingsCancellable = Labs.enabledPublisher(.meetings, in: defaults)
            .combineLatest(
                NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification, object: defaults)
                    .map { _ in MeetingSettings.detectsCalls(in: defaults) }
                    .prepend(MeetingSettings.detectsCalls(in: defaults))
            )
            .map { $0 && $1 }
            .removeDuplicates()
            .sink { [weak self] isOn in
                MainActor.assumeIsolated { self?.setPolling(isOn) }
            }
        recordingCancellable = dependencies.recorder.$activeMeeting.map { $0 == nil }.removeDuplicates()
            .sink { [weak self] isIdle in
                MainActor.assumeIsolated {
                    guard let self, isIdle, self.pendingStopProvider != nil else { return }
                    self.pendingStopProvider = nil
                    self.dependencies.prompt.dismiss()
                }
            }
    }

    private func setPolling(_ isOn: Bool) {
        pollTask?.cancel()
        pollTask = nil
        guard isOn else {
            detector = CallDetector()
            browserMeet = [:]
            pendingOfferProvider = nil
            pendingStopProvider = nil
            dependencies.prompt.dismiss()
            return
        }
        let interval = dependencies.pollInterval
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.poll()
                try? await Task.sleep(for: interval)
            }
        }
    }

    /// One observation of the microphone's users.
    func poll() async {
        let now = dependencies.now()
        var providers = Set<MeetingProvider>()
        var browsers = Set<BrowserType>()
        for process in dependencies.processes.processesUsingInput() {
            if let provider = MeetingProvider.nativeProvider(forBundleIDs: process.bundleIDs) {
                providers.insert(provider)
            } else if let browser = MeetingProvider.browser(forBundleIDs: process.bundleIDs) {
                browsers.insert(browser)
            }
        }
        for browser in browsers where await isOnMeet(browser, at: now) {
            providers.insert(.meet)
        }
        browserMeet = browserMeet.filter { browsers.contains($0.key) }
        for event in detector.observe(providers, at: now) {
            handle(event)
        }
    }

    private func isOnMeet(_ browser: BrowserType, at now: TimeInterval) async -> Bool {
        if let cached = browserMeet[browser], now - cached.checkedAt < dependencies.browserQueryInterval {
            return cached.isMeet
        }
        let isMeet = await dependencies.browserURL(browser).map(MeetingProvider.isMeetCall) ?? false
        browserMeet[browser] = (now, isMeet)
        return isMeet
    }

    private func handle(_ event: CallDetector.Event) {
        let recorder = dependencies.recorder
        switch event {
        case .started(let provider):
            guard !recorder.isRecording, !recorder.isStarting, !detector.isSnoozed(provider) else { return }
            switch MeetingSettings.policy(for: provider, in: dependencies.defaults) {
            case .neverOffer:
                return
            case .alwaysRecord:
                logger.notice("Recording detected call provider=\(provider.rawValue, privacy: .public) policy=always")
                Task { await self.record(provider, automatically: true) }
            case .ask:
                pendingOfferProvider = provider
                dependencies.prompt.offerRecording(provider, timeout: dependencies.offerTimeout) { [weak self] answer in
                    self?.pendingOfferProvider = nil
                    self?.answerOffer(answer, for: provider)
                }
            }
        case .ended(let provider):
            if pendingStopProvider == nil, recorder.activeMeeting?.provider == provider.rawValue {
                pendingStopProvider = provider
                dependencies.prompt.offerStop(provider) { [weak self] answer in
                    guard let self else { return }
                    self.pendingStopProvider = nil
                    if answer == .stop { Task { _ = await self.dependencies.recorder.stop() } }
                }
            } else if pendingOfferProvider == provider {
                // An unanswered offer for a call that already ended is withdrawn.
                pendingOfferProvider = nil
                dependencies.prompt.dismiss()
            }
        }
    }

    private func answerOffer(_ answer: MeetingCallPromptAnswer, for provider: MeetingProvider) {
        switch answer {
        case .record:
            Task { await record(provider, automatically: false) }
        case .neverOffer:
            MeetingSettings.setPolicy(.neverOffer, for: provider, in: dependencies.defaults)
        default:
            detector.snooze(provider)
        }
    }

    private func record(_ provider: MeetingProvider, automatically: Bool) async {
        let title = provider.callName + " " + Date().formatted(date: .abbreviated, time: .shortened)
        do {
            try await dependencies.recorder.start(title: title, provider: provider.rawValue)
            if automatically { dependencies.prompt.showStartedAutomatically(provider) }
        } catch {
            logger.error("Detected call recording failed: \(error, privacy: .public)")
            NotificationManager.shared.showNotification(title: error.localizedDescription, type: .error, duration: 7)
        }
    }

    /// Whether VoiceInk may already send Apple Events to the browser, without asking.
    nonisolated static func canAutomate(_ browser: BrowserType) -> Bool {
        let target = NSAppleEventDescriptor(bundleIdentifier: browser.bundleIdentifier)
        guard let descriptor = target.aeDesc else { return false }
        return AEDeterminePermissionToAutomateTarget(descriptor, typeWildCard, typeWildCard, false) == noErr
    }
}
