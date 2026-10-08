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

            #expect(renderingsMatch(regularPixels, filledPixels), "Legacy variant differs: \(filled)")
        }
    }

    @Test func distinctSymbolsRenderDifferentOutlines() throws {
        let microphonePixels = try pixels(of: Image(appSymbol: "mic"))
        let gearPixels = try pixels(of: Image(appSymbol: "gearshape"))

        #expect(!renderingsMatch(microphonePixels, gearPixels))
    }

    @Test func unknownImportedIconUsesPhosphorFallback() throws {
        let unknown = Image(appSymbol: "legacy.unmapped.symbol")
        let fallback = Image(decorative: AppSymbolCatalog.fallback)

        let unknownPixels = try pixels(of: unknown)
        let fallbackPixels = try pixels(of: fallback)

        #expect(renderingsMatch(unknownPixels, fallbackPixels))
    }

    private func pixels(of image: Image) throws -> [UInt8] {
        let renderer = ImageRenderer(content: image.font(.system(size: 24)).foregroundStyle(.black).frame(width: 32, height: 32))
        renderer.scale = 1
        let rendered = try #require(renderer.cgImage)
        #expect(rendered.width == 32 && rendered.height == 32)
        let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        var pixels = [UInt8](repeating: 0, count: 32 * 32 * 4)
        try pixels.withUnsafeMutableBytes { bytes in
            let context = try #require(CGContext(
                data: bytes.baseAddress, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 32 * 4,
                space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
            ))
            context.draw(rendered, in: CGRect(x: 0, y: 0, width: 32, height: 32))
        }
        return pixels
    }

    private func renderingsMatch(_ first: [UInt8], _ second: [UInt8]) -> Bool {
        // Identical antialiased edges can differ by one 8-bit alpha step in ImageRenderer.
        first.count == second.count && zip(first, second).allSatisfy { abs(Int($0) - Int($1)) <= 1 }
    }
}
