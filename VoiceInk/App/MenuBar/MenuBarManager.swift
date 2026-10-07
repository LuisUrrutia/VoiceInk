import AppKit
import SwiftUI

class MenuBarManager: ObservableObject {
    @Published private(set) var iconVisibility: AppIconVisibility

    var isMenuBarOnly: Bool { iconVisibility.isDockIconHidden }
    var showMenuBarIcon: Bool { iconVisibility.isMenuBarIconVisible }

    private let defaults: UserDefaults
    private let applyVisibility: ((AppIconVisibility) -> Void)?
    private var engine: VoiceInkEngine?
    private var configuredActivationPolicy: NSApplication.ActivationPolicy {
        isMenuBarOnly ? .accessory : .regular
    }

    init(defaults: UserDefaults = .standard, applyVisibility: ((AppIconVisibility) -> Void)? = nil) {
        self.defaults = defaults
        self.applyVisibility = applyVisibility
        self.iconVisibility = AppIconVisibility(defaults: defaults)
        applyActivationPolicy()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(userFacingWindowWillClose),
            name: NSWindow.willCloseNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func userFacingWindowWillClose(_ notification: Notification) {
        guard isMenuBarOnly,
            let window = notification.object as? NSWindow,
            window.level == .normal,
            window.styleMask.contains(.titled)
        else {
            return
        }

        AppPresentationPolicy.restoreAccessoryIfNeededAfterUserFacingWindowClosed()
    }

    func configure(engine: VoiceInkEngine) {
        self.engine = engine
    }

    func toggleMenuBarOnly() {
        setDockIconHidden(!isMenuBarOnly)
    }

    func setDockIconHidden(_ hidden: Bool) {
        requestIconVisibility(AppIconVisibility(isDockIconHidden: hidden, isMenuBarIconVisible: showMenuBarIcon))
    }

    func setMenuBarIconVisible(_ visible: Bool) {
        requestIconVisibility(AppIconVisibility(isDockIconHidden: isMenuBarOnly, isMenuBarIconVisible: visible))
    }

    @discardableResult
    func requestIconVisibility(
        _ requested: AppIconVisibility,
        confirm: () -> Bool = MenuBarManager.confirmHidingBothIcons
    ) -> Bool {
        if requested.areBothIconsHidden && !iconVisibility.areBothIconsHidden && !confirm() {
            return false
        }
        restoreIconVisibility(requested)
        return true
    }

    func restoreIconVisibility(_ visibility: AppIconVisibility) {
        guard visibility != iconVisibility else { return }
        let dockChanged = isMenuBarOnly != visibility.isDockIconHidden
        defaults.set(visibility.isDockIconHidden, forKey: AppIconVisibility.dockHiddenKey)
        defaults.set(visibility.isMenuBarIconVisible, forKey: AppIconVisibility.menuBarVisibleKey)
        iconVisibility = visibility
        if dockChanged {
            applyActivationPolicy()
        }
    }

    static func confirmHidingBothIcons() -> Bool {
        AppPresentationPolicy.activateForUserFacingWindow()
        defer { AppPresentationPolicy.restoreAccessoryIfNeededAfterUserFacingWindowClosed() }
        let alert = NSAlert()
        alert.messageText = String(localized: "Hide Both App Icons?")
        alert.informativeText = String(
            localized: "VoiceInk keeps running. Reopen it from Applications or Spotlight to show its window.")
        alert.alertStyle = .warning
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.addButton(withTitle: String(localized: "Hide Both"))
        return alert.runModal() == .alertSecondButtonReturn
    }

    func applyActivationPolicy() {
        if let applyVisibility {
            applyVisibility(iconVisibility)
            return
        }
        let applyPolicy = { [weak self] in
            guard let self else { return }

            NSApplication.shared.setActivationPolicy(self.configuredActivationPolicy)

            if self.isMenuBarOnly {
                WindowManager.shared.hideMainWindow()
            }
        }

        if Thread.isMainThread {
            applyPolicy()
        } else {
            DispatchQueue.main.async(execute: applyPolicy)
        }
    }

    func activateForPresentedWindow() {
        let activate = {
            AppPresentationPolicy.activateForUserFacingWindow()
        }

        if Thread.isMainThread {
            activate()
        } else {
            DispatchQueue.main.async(execute: activate)
        }
    }

    func openQuickHistory() {
        guard let engine else { return }

        // Let the MenuBarExtra close before making the nonactivating panel key.
        DispatchQueue.main.async {
            QuickHistoryController.shared.show(modelContext: engine.modelContext, engine: engine)
        }
    }
}
