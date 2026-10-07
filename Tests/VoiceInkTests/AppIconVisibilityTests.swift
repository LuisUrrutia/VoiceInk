import AppKit
import Carbon.HIToolbox
import Combine
import XCTest

@testable import VoiceInk

@MainActor final class AppIconVisibilityTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "AppIconVisibilityTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func testNewInstallShowsBothIconsAndExistingDockPreferenceSurvives() {
        let fresh = makeManager()
        defaults.set(true, forKey: AppIconVisibility.dockHiddenKey)
        let existing = makeManager()

        XCTAssertFalse(fresh.isMenuBarOnly)
        XCTAssertTrue(fresh.showMenuBarIcon)
        XCTAssertTrue(existing.isMenuBarOnly)
        XCTAssertTrue(existing.showMenuBarIcon)
    }

    func testCancelLeavesVisibilityPersistenceAndActivationUnchanged() {
        let manager = makeManager()
        manager.setDockIconHidden(true)
        var applied: [AppIconVisibility] = []
        let resumed = MenuBarManager(defaults: defaults, applyVisibility: { applied.append($0) })
        let initialApplications = applied.count
        var confirmations = 0

        let accepted = resumed.requestIconVisibility(
            AppIconVisibility(isDockIconHidden: true, isMenuBarIconVisible: false)
        ) {
            confirmations += 1
            return false
        }

        XCTAssertFalse(accepted)
        XCTAssertEqual(confirmations, 1)
        XCTAssertTrue(resumed.showMenuBarIcon)
        XCTAssertTrue(resumed.isMenuBarOnly)
        XCTAssertTrue(AppIconVisibility(defaults: defaults).isMenuBarIconVisible)
        XCTAssertEqual(applied.count, initialApplications)
    }

    func testEitherLastIconRequiresConfirmationAndConfirmedStateSurvivesRestart() {
        for current in [
            AppIconVisibility(isDockIconHidden: true, isMenuBarIconVisible: true),
            AppIconVisibility(isDockIconHidden: false, isMenuBarIconVisible: false),
        ] {
            let manager = makeManager()
            manager.restoreIconVisibility(current)
            var confirmations = 0

            let accepted = manager.requestIconVisibility(
                AppIconVisibility(isDockIconHidden: true, isMenuBarIconVisible: false)
            ) {
                confirmations += 1
                return true
            }
            let resumed = makeManager()

            XCTAssertTrue(accepted)
            XCTAssertEqual(confirmations, 1)
            XCTAssertTrue(resumed.iconVisibility.areBothIconsHidden)
        }
    }

    func testShowingEitherIconNeverRequiresConfirmation() {
        let manager = makeManager()
        let bothHidden = AppIconVisibility(isDockIconHidden: true, isMenuBarIconVisible: false)
        for target in [
            AppIconVisibility(isDockIconHidden: false, isMenuBarIconVisible: false),
            AppIconVisibility(isDockIconHidden: true, isMenuBarIconVisible: true),
            AppIconVisibility(isDockIconHidden: false, isMenuBarIconVisible: true),
        ] {
            manager.restoreIconVisibility(bothHidden)

            let accepted = manager.requestIconVisibility(target) {
                XCTFail("Showing an icon must not prompt")
                return false
            }

            XCTAssertTrue(accepted)
            XCTAssertEqual(manager.iconVisibility, target)
        }
    }

    func testMenuOnlyChangesDoNotReapplyDockPolicyOrHideTheWindow() {
        var applications = 0
        let manager = MenuBarManager(defaults: defaults, applyVisibility: { _ in applications += 1 })
        let initialApplications = applications

        manager.setMenuBarIconVisible(false)
        manager.setMenuBarIconVisible(true)

        XCTAssertEqual(applications, initialApplications)
    }

    func testSwiftUIEchoOfMenuInsertionDoesNotPublishAnotherUpdate() {
        let manager = makeManager()
        var updates = 0
        let subscription = manager.objectWillChange.sink { updates += 1 }

        manager.setMenuBarIconVisible(manager.showMenuBarIcon)
        manager.setDockIconHidden(manager.isMenuBarOnly)

        XCTAssertEqual(updates, 0)
        withExtendedLifetime(subscription) {}
    }

    func testBackupRoundTripsEveryVisibilityCombination() throws {
        for dockHidden in [false, true] {
            for menuVisible in [false, true] {
                let backup = try decodeBackup("""
                    {"version":"1.0.0","generalSettings":{
                        "isMenuBarOnly":\(dockHidden),"showMenuBarIcon":\(menuVisible)
                    }}
                    """)

                let restored = try JSONDecoder().decode(BackupFile.self, from: JSONEncoder().encode(backup))

                XCTAssertEqual(restored.generalSettings?.isMenuBarOnly, dockHidden)
                XCTAssertEqual(restored.generalSettings?.showMenuBarIcon, menuVisible)
            }
        }
    }

    func testLegacyAndPartialBackupsPreserveOmittedPreferences() throws {
        let current = AppIconVisibility(isDockIconHidden: false, isMenuBarIconVisible: false)
        let legacy = try decodeBackup("""
            {"version":"1.0.0","generalSettings":{"isMenuBarOnly":true}}
            """)
        let partial = try decodeBackup("""
            {"version":"1.0.0","generalSettings":{"showMenuBarIcon":true}}
            """)

        let legacyVisibility = try XCTUnwrap(legacy.generalSettings).iconVisibility(restoring: current)
        let partialVisibility = try XCTUnwrap(partial.generalSettings).iconVisibility(restoring: current)

        XCTAssertNil(legacy.generalSettings?.showMenuBarIcon)
        XCTAssertTrue(legacyVisibility.areBothIconsHidden)
        XCTAssertFalse(partialVisibility.isDockIconHidden)
        XCTAssertTrue(partialVisibility.isMenuBarIconVisible)
    }

    func testImportConfirmationUsesOnlySelectedGeneralSettingsAndResultingVisibility() throws {
        let legacy = try decodeBackup("""
            {"version":"1.0.0","generalSettings":{"isMenuBarOnly":true}}
            """)
        let current = AppIconVisibility(isDockIconHidden: false, isMenuBarIconVisible: false)
        let visible = AppIconVisibility(isDockIconHidden: false, isMenuBarIconVisible: true)

        let imported = BackupImporter.importedIconVisibility(legacy, categories: [.general], current: current)
        let dictionaryOnly = BackupImporter.importedIconVisibility(legacy, categories: [.dictionary], current: current)
        let menuVisible = BackupImporter.importedIconVisibility(legacy, categories: [.general], current: visible)
        let alreadyHidden = BackupImporter.importedIconVisibility(
            legacy, categories: [.general],
            current: AppIconVisibility(isDockIconHidden: true, isMenuBarIconVisible: false)
        )

        XCTAssertEqual(imported, AppIconVisibility(isDockIconHidden: true, isMenuBarIconVisible: false))
        XCTAssertNil(dictionaryOnly)
        XCTAssertEqual(menuVisible, AppIconVisibility(isDockIconHidden: true, isMenuBarIconVisible: true))
        XCTAssertEqual(alreadyHidden, imported)
    }

    func testLoginLaunchDetectionDistinguishesNormalLaunch() {
        let event = NSAppleEventDescriptor(
            eventClass: kCoreEventClass, eventID: kAEOpenApplication,
            targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
        XCTAssertFalse(AppDelegate.isLoginItemLaunch(nil))
        XCTAssertFalse(AppDelegate.isLoginItemLaunch(event))

        event.setParam(NSAppleEventDescriptor(enumCode: keyAELaunchedAsLogInItem), forKeyword: keyAEPropData)

        XCTAssertTrue(AppDelegate.isLoginItemLaunch(event))
    }

    private func makeManager() -> MenuBarManager {
        MenuBarManager(defaults: defaults, applyVisibility: { _ in })
    }

    private func decodeBackup(_ json: String) throws -> BackupFile {
        try JSONDecoder().decode(BackupFile.self, from: Data(json.utf8))
    }
}
