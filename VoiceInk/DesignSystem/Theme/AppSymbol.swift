import AppKit
import SwiftUI

extension Image {
    init(appSymbol systemName: String) {
        if let asset = AppSymbolCatalog.symbols[systemName], NSImage(named: asset) != nil {
            // Preserve the system symbol's spoken label when replacing its artwork.
            if let description = NSImage(systemSymbolName: systemName, accessibilityDescription: nil)?.accessibilityDescription {
                self.init(asset, label: Text(description))
            } else {
                self.init(decorative: asset)
            }
        } else {
            self.init(systemName: systemName)
        }
    }

    static func appSymbolTint(_ systemName: String) -> Image? {
        guard let asset = AppSymbolCatalog.tints[systemName], NSImage(named: asset) != nil else {
            return nil
        }
        return Image(decorative: asset)
    }
}

extension Label where Title == Text, Icon == Image {
    init(_ title: LocalizedStringKey, appSymbol: String) {
        self.init { Text(title) } icon: { Image(appSymbol: appSymbol) }
    }

    @_disfavoredOverload
    init<S: StringProtocol>(_ title: S, appSymbol: String) {
        self.init { Text(title) } icon: { Image(appSymbol: appSymbol) }
    }
}

#if DEBUG
    enum AppSymbolCheck {
        static func assertAssetsExist() {
            for asset in Set(AppSymbolCatalog.symbols.values).union(AppSymbolCatalog.tints.values) {
                assert(NSImage(named: asset) != nil, "Missing custom symbol: \(asset)")
            }
        }
    }
#endif
