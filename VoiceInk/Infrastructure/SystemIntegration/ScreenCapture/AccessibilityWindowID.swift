import ApplicationServices
import Darwin

enum AccessibilityWindowID {
    typealias Lookup = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError

    // Resolve the private SPI at runtime so its absence preserves the frame/title fallback.
    private static let lookup: Lookup? = {
        guard let handle = dlopen(nil, RTLD_LAZY) else { return nil }
        defer { dlclose(handle) }
        guard let symbol = dlsym(handle, "_AXUIElementGetWindow") else { return nil }
        return unsafeBitCast(symbol, to: Lookup.self)
    }()

    static func resolve(_ element: AXUIElement, using lookup: Lookup? = lookup) -> CGWindowID? {
        guard let lookup else { return nil }
        var windowID: CGWindowID = 0
        guard lookup(element, &windowID) == .success, windowID != kCGNullWindowID else { return nil }
        return windowID
    }
}
