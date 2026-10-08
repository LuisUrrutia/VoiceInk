import ApplicationServices
import Foundation
import Testing
@testable import VoiceInk

struct AccessibilityWindowIDTests {
    @Test func returnsResolvedWindowID() {
        let element = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
        let lookup: AccessibilityWindowID.Lookup = { _, windowID in
            windowID.pointee = 42
            return .success
        }

        let windowID = AccessibilityWindowID.resolve(element, using: lookup)

        #expect(windowID == 42)
    }

    @Test func returnsNilWhenSymbolIsUnavailable() {
        let element = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)

        let windowID = AccessibilityWindowID.resolve(element, using: nil)

        #expect(windowID == nil)
    }

    @Test func returnsNilWhenLookupFailsEvenWithNonzeroID() {
        let element = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
        let lookup: AccessibilityWindowID.Lookup = { _, windowID in
            windowID.pointee = 42
            return .cannotComplete
        }

        let windowID = AccessibilityWindowID.resolve(element, using: lookup)

        #expect(windowID == nil)
    }

    @Test func returnsNilWhenLookupSucceedsWithNullID() {
        let element = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
        let lookup: AccessibilityWindowID.Lookup = { _, _ in .success }

        let windowID = AccessibilityWindowID.resolve(element, using: lookup)

        #expect(windowID == nil)
    }
}
