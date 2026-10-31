import XCTest
@testable import VoiceInk

@MainActor
final class DashboardSetupGuideTests: XCTestCase {
    func testFreshStarterSetupShowsEveryStep() {
        let steps = DashboardSetupGuide.steps(for: configuration())

        XCTAssertEqual(steps, [.chooseModel, .customizeModes, .setShortcuts, .addVocabulary])
    }

    func testWithoutEnabledModesSuggestsCreatingOne() {
        var disabledDictation = starterDictation()
        disabledDictation.isEnabled = false

        XCTAssertEqual(
            DashboardSetupGuide.steps(for: configuration(modes: [])),
            [.chooseModel, .createFirstMode, .setShortcuts, .addVocabulary])
        XCTAssertTrue(
            DashboardSetupGuide.steps(for: configuration(modes: [disabledDictation])).contains(.createFirstMode))
    }

    func testUserCreatedModeHidesModelAndModeSteps() {
        let slack = ModeConfig(name: "Slack", isAIEnhancementEnabled: true, selectedTranscriptionModelName: "parakeet-tdt-0.6b-v3")

        let steps = DashboardSetupGuide.steps(for: configuration(modes: [starterDictation(), slack]))

        XCTAssertEqual(steps, [.setShortcuts, .addVocabulary])
    }

    func testOnboardingStarterModesAloneKeepModeStep() {
        let enhancement = StarterModeCatalog.templates.first { $0.kind == .enhance }!
        let starter = ModeConfig(id: enhancement.id, name: enhancement.name, isAIEnhancementEnabled: true)

        let steps = DashboardSetupGuide.steps(for: configuration(modes: [starterDictation(), starter]))

        XCTAssertEqual(steps, [.chooseModel, .customizeModes, .setShortcuts, .addVocabulary])
    }

    func testCustomizedDefaultModeHidesModelAndModeSteps() {
        let customizations: [(inout ModeConfig) -> Void] = [
            { $0.name = "Notes" },
            { $0.icon = .symbol("star") },
            { $0.isAIEnhancementEnabled = true },
            { $0.selectedLanguages = ["es"] },
            { $0.triggerWords = ["note"] },
            { $0.useClipboardContext = true },
            { $0.isTextFormattingEnabled = false },
        ]

        for customize in customizations {
            var dictation = starterDictation()
            customize(&dictation)

            let steps = DashboardSetupGuide.steps(for: configuration(modes: [dictation]))

            XCTAssertEqual(steps, [.setShortcuts, .addVocabulary])
        }
    }

    func testUserModeMadeDefaultCountsAsCustomized() {
        var dictation = starterDictation()
        dictation.isDefault = false
        let notes = ModeConfig(name: "Notes", isAIEnhancementEnabled: false, isDefault: true)

        let steps = DashboardSetupGuide.steps(for: configuration(modes: [dictation, notes]))

        XCTAssertFalse(steps.contains(.customizeModes))
    }

    func testChangedDefaultModelHidesOnlyModelStep() {
        var dictation = starterDictation()
        dictation.selectedTranscriptionModelName = "ggml-large-v3-turbo"

        let steps = DashboardSetupGuide.steps(for: configuration(modes: [dictation]))

        XCTAssertEqual(steps, [.customizeModes, .setShortcuts, .addVocabulary])
    }

    func testDownloadedModelBeyondStarterDefaultHidesModelStep() {
        let initial = DashboardSetupGuide.steps(
            for: configuration(installed: ["apple-speech", "parakeet-tdt-0.6b-v3"]))
        let downloaded = DashboardSetupGuide.steps(
            for: configuration(installed: ["apple-speech", "parakeet-tdt-0.6b-v3", "ggml-base"]))

        XCTAssertTrue(initial.contains(.chooseModel))
        XCTAssertEqual(downloaded, [.customizeModes, .setShortcuts, .addVocabulary])
    }

    func testShortcutAndDictionaryEntriesHideTheirSteps() {
        let steps = DashboardSetupGuide.steps(
            for: configuration(hasRecordingShortcut: true, hasDictionaryEntries: true))

        XCTAssertEqual(steps, [.chooseModel, .customizeModes])
    }

    func testCaptureReadinessShowsUntilFirstCompletedDictation() {
        let ready = readiness()

        XCTAssertTrue(showsReadiness(hasCompletedDictation: false, readiness: ready))
        XCTAssertFalse(showsReadiness(hasCompletedDictation: true, readiness: ready))
    }

    func testCaptureReadinessReturnsForProblemsAfterFirstDictation() {
        var noMicrophone = readiness()
        noMicrophone.hasMicrophone = false
        var noAccessibility = readiness()
        noAccessibility.accessibilityGranted = false
        var missingModel = readiness()
        missingModel.model = .notInstalled

        XCTAssertTrue(showsReadiness(readiness: noMicrophone))
        XCTAssertTrue(showsReadiness(readiness: noAccessibility))
        XCTAssertTrue(showsReadiness(readiness: missingModel))
        XCTAssertTrue(showsReadiness(readiness: readiness(), hotkey: .unconfigured))
        XCTAssertTrue(showsReadiness(readiness: readiness(), hotkey: .needsAccessibility))
        XCTAssertTrue(showsReadiness(readiness: readiness(), hasRecordingError: true))
    }

    func testModelCheckInProgressDoesNotShowCaptureReadiness() {
        var checking = readiness()
        checking.model = .checking

        XCTAssertFalse(showsReadiness(readiness: checking))
    }

    private func starterDictation() -> ModeConfig {
        let template = StarterModeCatalog.templates.first(where: \.isDefault)!
        return ModeConfig(
            id: template.id, name: template.name, icon: template.icon,
            isAIEnhancementEnabled: template.usesAIEnhancement,
            selectedTranscriptionModelName: StarterModeFactory.defaultTranscriptionModelName,
            selectedLanguage: "auto", useSelectedTextContext: template.useSelectedTextContext,
            useScreenCapture: template.useScreenCapture, isTextFormattingEnabled: true,
            outputMode: template.outputMode, isDefault: true)
    }

    private func configuration(
        modes: [ModeConfig]? = nil, installed: Set<String> = ["apple-speech"],
        hasRecordingShortcut: Bool = false, hasDictionaryEntries: Bool = false
    ) -> DashboardSetupGuide.Configuration {
        DashboardSetupGuide.Configuration(
            modes: modes ?? [starterDictation()], installedLocalModelNames: installed,
            hasRecordingShortcut: hasRecordingShortcut, hasDictionaryEntries: hasDictionaryEntries)
    }

    private func readiness() -> CaptureReadiness {
        CaptureReadiness(
            microphonePermission: .granted, hasMicrophone: true, accessibilityGranted: true,
            model: .ready, usesPaste: true)
    }

    private func showsReadiness(
        hasCompletedDictation: Bool = true, readiness: CaptureReadiness,
        hotkey: RecordingHotkeyAvailability = .available, hasRecordingError: Bool = false
    ) -> Bool {
        DashboardSetupGuide.showsCaptureReadiness(
            hasCompletedDictation: hasCompletedDictation, readiness: readiness, hotkey: hotkey,
            hasRecordingError: hasRecordingError)
    }
}
