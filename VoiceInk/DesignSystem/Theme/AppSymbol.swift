import AppKit
import SwiftUI

extension Image {
    init(appSymbol systemName: String) {
        let mappedAsset = AppSymbolCatalog.symbols[systemName] ?? AppSymbolCatalog.fallback
        let asset = NSImage(named: mappedAsset) != nil ? mappedAsset : AppSymbolCatalog.fallback
        // Preserve the system symbol's spoken label when replacing its artwork.
        let description = NSImage(systemSymbolName: systemName, accessibilityDescription: nil)?.accessibilityDescription
            ?? asset.dropFirst(3)
                .replacingOccurrences(of: "-", with: " ")
                .capitalized
        self.init(asset, label: Text(description))
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
            for asset in Set(AppSymbolCatalog.symbols.values) {
                assert(NSImage(named: asset) != nil, "Missing custom symbol: \(asset)")
            }
        }
    }
#endif
