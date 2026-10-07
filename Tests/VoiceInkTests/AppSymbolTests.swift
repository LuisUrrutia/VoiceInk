import AppKit
import SwiftUI
import Testing
@testable import VoiceInk

@MainActor
struct AppSymbolTests {
    @Test func modePickerUsesBundledPhosphorSymbols() throws {
        let options = ModeIcon.defaultSymbols

        let assets = try options.map { name in
            try #require(AppSymbolCatalog.symbols[name], "Unmapped mode icon: \(name)")
        }

        #expect(Set(assets).count == options.count)
        for asset in assets {
            #expect(NSImage(symbolName: asset, variableValue: 0) != nil, "Missing custom symbol: \(asset)")
        }
    }

    @Test func catalogContainsNativeSymbols() {
        let assets = Set(AppSymbolCatalog.symbols.values)
            .union([AppSymbolCatalog.fallback])

        for asset in assets {
            #expect(NSImage(symbolName: asset, variableValue: 0) != nil, "Missing custom symbol: \(asset)")
        }
    }

    @Test func legacyFilledNamesRenderTheSameOutline() throws {
        let pairs = [
            ("mic", "mic.fill"),
            ("gearshape", "gearshape.fill"),
            ("checkmark.circle", "checkmark.circle.fill"),
            ("cpu", "cpu.fill"),
            ("plus.circle", "plus.circle.fill"),
        ]

        for (regular, filled) in pairs {
            let regularPixels = try pixels(of: Image(appSymbol: regular))
            let filledPixels = try pixels(of: Image(appSymbol: filled))

            #expect(regularPixels == filledPixels, "Legacy variant differs: \(filled)")
        }
    }

    @Test func unknownImportedIconUsesPhosphorFallback() throws {
        let unknown = Image(appSymbol: "legacy.unmapped.symbol")
        let fallback = Image(decorative: AppSymbolCatalog.fallback)

        let unknownPixels = try pixels(of: unknown)
        let fallbackPixels = try pixels(of: fallback)

        #expect(unknownPixels == fallbackPixels)
    }

    private func pixels(of image: Image) throws -> Data {
        let renderer = ImageRenderer(content: image.font(.system(size: 24)).frame(width: 32, height: 32))
        let rendered = try #require(renderer.nsImage)
        return try #require(rendered.tiffRepresentation)
    }
}
