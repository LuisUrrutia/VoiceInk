import Foundation

struct AppIconVisibility: Equatable {
    static let dockHiddenKey = "IsMenuBarOnly"
    static let menuBarVisibleKey = "ShowMenuBarIcon"

    let isDockIconHidden: Bool
    let isMenuBarIconVisible: Bool

    var areBothIconsHidden: Bool {
        isDockIconHidden && !isMenuBarIconVisible
    }

    init(isDockIconHidden: Bool, isMenuBarIconVisible: Bool) {
        self.isDockIconHidden = isDockIconHidden
        self.isMenuBarIconVisible = isMenuBarIconVisible
    }

    init(defaults: UserDefaults) {
        isDockIconHidden = defaults.bool(forKey: Self.dockHiddenKey)
        isMenuBarIconVisible = defaults.object(forKey: Self.menuBarVisibleKey) as? Bool ?? true
    }
}
