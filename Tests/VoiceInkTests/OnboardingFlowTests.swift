import XCTest

@testable import VoiceInk

@MainActor final class OnboardingFlowTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "OnboardingFlowTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.audioInputModeRawValue = AudioInputMode.custom.rawValue
        defaults.selectedAudioDeviceUID = "test-microphone"
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func testModelCanBeSkippedWithoutDownloadOrProvider() {
        let coordinator = makeCoordinator()
        coordinator.storedStage = OnboardingStage.model.rawValue

        coordinator.flow.skipModelSetup()
        coordinator.flow.reconcileSetupStage(isTranscriptionSetupReady: false)

        XCTAssertEqual(coordinator.stage, .trust)
        XCTAssertTrue(coordinator.hasSkippedModelSetup)
        XCTAssertTrue(coordinator.canFinishSetup(isTranscriptionSetupReady: false))
        XCTAssertFalse(coordinator.isReadyForExperience(isTranscriptionSetupReady: false))
        XCTAssertFalse(coordinator.isSelectedAPIProviderVerified)
    }

    func testSkippedModelSurvivesRestartAndFinishesOnboarding() {
        let coordinator = makeCoordinator()
        coordinator.storedStage = OnboardingStage.model.rawValue
        coordinator.flow.skipModelSetup()
        let resumed = makeCoordinator()
        var didComplete = false

        resumed.flow.reconcileSetupStage(isTranscriptionSetupReady: false)
        resumed.flow.completeOnboarding(isTranscriptionSetupReady: false) { didComplete = true }

        XCTAssertTrue(didComplete)
        XCTAssertEqual(resumed.stage, .trust)
        for key in OnboardingStorageKeys.onboardingKeys {
            XCTAssertNil(defaults.object(forKey: key), "Completion must clear \(key)")
        }
    }

    func testModelSkipDoesNotBypassRequiredPermissionsOrMicrophone() {
        let coordinator = makeCoordinator()
        coordinator.storedStage = OnboardingStage.model.rawValue
        coordinator.permissionStatuses[.microphone] = .denied

        coordinator.flow.skipModelSetup()

        XCTAssertFalse(coordinator.hasSkippedModelSetup)
        XCTAssertFalse(coordinator.canFinishSetup(isTranscriptionSetupReady: false))

        coordinator.permissionStatuses[.microphone] = .granted
        defaults.selectedAudioDeviceUID = nil

        coordinator.flow.skipModelSetup()

        XCTAssertFalse(coordinator.hasSkippedModelSetup)
    }

    func testRevokedPermissionReturnsSkippedSetupToPermissions() {
        let coordinator = makeCoordinator()
        coordinator.flow.skipModelSetup()
        coordinator.permissionStatuses[.accessibility] = .denied
        var didComplete = false

        coordinator.flow.reconcileSetupStage(isTranscriptionSetupReady: false)
        coordinator.flow.completeOnboarding(isTranscriptionSetupReady: false) { didComplete = true }

        XCTAssertEqual(coordinator.stage, .permissions)
        XCTAssertFalse(didComplete)
    }

    func testOrdinarySetupStillRequiresModelAndEnhancementDecision() {
        let coordinator = makeCoordinator()
        coordinator.storedStage = OnboardingStage.trust.rawValue

        coordinator.flow.reconcileSetupStage(isTranscriptionSetupReady: false)

        XCTAssertEqual(coordinator.stage, .model)
        XCTAssertFalse(coordinator.canFinishSetup(isTranscriptionSetupReady: false))
        coordinator.hasSkippedAPISetup = true
        XCTAssertTrue(coordinator.canFinishSetup(isTranscriptionSetupReady: true))
    }

    func testPreviousLicenseStageResumesAtAccountFreeFinish() {
        defaults.set("license", forKey: OnboardingStorageKeys.stage)
        let coordinator = makeCoordinator()
        coordinator.hasSkippedAPISetup = true
        var didComplete = false

        coordinator.flow.completeOnboarding(isTranscriptionSetupReady: true) { didComplete = true }

        XCTAssertEqual(coordinator.stage, .trust)
        XCTAssertTrue(didComplete)
        XCTAssertFalse(OnboardingStage.allCases.map(\.rawValue).contains("license"))
    }

    func testRestoredModesSkipResumedDemonstrationsAfterRequiredSetup() {
        for stage in [OnboardingStage.experience, .contextAwareness] {
            let coordinator = makeCoordinator(preservesConfiguredModes: true)
            coordinator.storedStage = stage.rawValue
            coordinator.hasSkippedAPISetup = true
            var didComplete = false

            coordinator.flow.reconcileSetupStage(isTranscriptionSetupReady: true)
            coordinator.flow.completeOnboarding(isTranscriptionSetupReady: true) { didComplete = true }

            XCTAssertEqual(coordinator.stage, .trust)
            XCTAssertTrue(didComplete)
        }
    }

    func testRestoredModesDoNotBypassMachineSetup() {
        let coordinator = makeCoordinator(preservesConfiguredModes: true)
        coordinator.storedStage = OnboardingStage.experience.rawValue
        coordinator.hasSkippedAPISetup = true
        coordinator.permissionStatuses[.microphone] = .denied
        var didComplete = false

        coordinator.flow.reconcileSetupStage(isTranscriptionSetupReady: true)
        coordinator.flow.completeOnboarding(isTranscriptionSetupReady: true) { didComplete = true }

        XCTAssertEqual(coordinator.stage, .permissions)
        XCTAssertFalse(didComplete)
        coordinator.permissionStatuses[.microphone] = .granted
        defaults.selectedAudioDeviceUID = nil
        coordinator.storedStage = OnboardingStage.experience.rawValue
        coordinator.flow.reconcileSetupStage(isTranscriptionSetupReady: true)
        XCTAssertEqual(coordinator.stage, .microphone)
        defaults.selectedAudioDeviceUID = "test-microphone"
        coordinator.storedStage = OnboardingStage.experience.rawValue
        coordinator.flow.reconcileSetupStage(isTranscriptionSetupReady: false)
        XCTAssertEqual(coordinator.stage, .model)
    }

    func testRestoredModesKeepDefaultAndActiveSelectionWhenFinishingOrSkipping() throws {
        let manager = ModeManager.shared
        let savedModes = manager.configurations
        let savedActive = manager.activeConfiguration
        let savedPreferences = ["modeConfigurationsV2", "activeConfigurationId"].map {
            (key: $0, value: UserDefaults.standard.object(forKey: $0))
        }
        defer {
            manager.configurations = savedModes
            manager.activeConfiguration = savedActive
            for (key, value) in savedPreferences {
                if let value { UserDefaults.standard.set(value, forKey: key) }
                else { UserDefaults.standard.removeObject(forKey: key) }
            }
        }
        let cleanID = try XCTUnwrap(StarterModeCatalog.templates.first(where: { $0.kind == .clean })?.id)
        let clean = ModeConfig(id: cleanID, name: "Customized clean", isAIEnhancementEnabled: false)
        let preferred = ModeConfig(name: "Preferred", isAIEnhancementEnabled: false, isDefault: true)
        manager.configurations = [clean, preferred]
        manager.activeConfiguration = preferred
        let expected = try ConfigurationValue.encoded(manager.configurations)
        let coordinator = makeCoordinator(preservesConfiguredModes: true)
        coordinator.hasSkippedAPISetup = true
        coordinator.storedStage = OnboardingStage.experience.rawValue

        coordinator.flow.activateExperienceModeForDemo()
        coordinator.flow.skipOnboarding {}
        coordinator.storedStage = OnboardingStage.trust.rawValue
        coordinator.flow.completeOnboarding(isTranscriptionSetupReady: true) {}

        XCTAssertEqual(try ConfigurationValue.encoded(manager.configurations), expected)
        XCTAssertEqual(manager.activeConfiguration?.id, preferred.id)
        XCTAssertEqual(manager.getDefaultConfiguration()?.id, preferred.id)
    }

    private func makeCoordinator(preservesConfiguredModes: Bool = false) -> OnboardingCoordinator {
        let coordinator = OnboardingCoordinator(defaults: defaults, preservesConfiguredModes: preservesConfiguredModes)
        coordinator.permissionStatuses = [
            .microphone: .granted, .accessibility: .granted, .screenRecording: .needsAccess
        ]
        return coordinator
    }
}
