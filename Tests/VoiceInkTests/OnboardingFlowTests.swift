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

    private func makeCoordinator() -> OnboardingCoordinator {
        let coordinator = OnboardingCoordinator(defaults: defaults)
        coordinator.permissionStatuses = [
            .microphone: .granted, .accessibility: .granted, .screenRecording: .needsAccess
        ]
        return coordinator
    }
}
