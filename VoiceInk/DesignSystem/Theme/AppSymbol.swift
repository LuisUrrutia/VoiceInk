import AppKit
import SwiftUI

extension Image {
    init(appSymbol systemName: String) {
        let mappedAsset = AppSymbolCatalog.symbols[systemName] ?? AppSymbolCatalog.fallback
        let asset = NSImage(named: mappedAsset) != nil ? mappedAsset : AppSymbolCatalog.fallback
        // Preserve the system symbol's spoken label when replacing its artwork.
        let description = NSImage(systemSymbolName: systemName, accessibilityDescription: nil)?.accessibilityDescription
            ?? asset.dropFirst(3)
                .replacingOccurrences(of: ".fill", with: "")
                .replacingOccurrences(of: "-", with: " ")
                .capitalized
        self.init(asset, label: Text(description))
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
