import Carbon.HIToolbox
import CoreGraphics
import Foundation

/// One press of an unassigned key under a held modifier-only shortcut, so other apps'
/// modifier-tap detectors (Raycast's Option tap, for example) read the hold as a chord.
/// Adapted from Hex (MIT), https://github.com/anomalyco/hex `post_chord_breaker`.
enum ChordBreaker {
    /// A hole in the virtual key codes between keypad `*` (0x43) and keypad `+` (0x45): no keyboard
    /// sends it, it has no system action, and macOS layouts other than Unicode Hex Input map nothing to it.
    static let keyCode: CGKeyCode = 0x44
    /// ASCII "VOICEI"; lets VoiceInk's own taps recognize the breaker.
    static let eventMarker: Int64 = 0x564F_4943_4549

    static func isMarked(_ event: CGEvent) -> Bool {
        event.getIntegerValueField(.eventSourceUserData) == eventMarker
    }

    static func isChordBreaker(type: CGEventType, event: CGEvent) -> Bool {
        (type == .keyDown || type == .keyUp) && isMarked(event)
            && event.getIntegerValueField(.keyboardEventKeycode) == Int64(keyCode)
    }

    static func makeEvents(flags: CGEventFlags) -> [CGEvent] {
        [true, false].compactMap { isDown in
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: isDown) else { return nil }
            event.flags = flags
            event.setIntegerValueField(.eventSourceUserData, value: eventMarker)
            return event
        }
    }
}

/// Posts the breaker at the HID tap, where other apps' HID and session taps see it, and drops it
/// at an annotated-session tap before the focused app, which would otherwise beep at an unhandled key.
final class ChordBreakerPoster: @unchecked Sendable {
    static let shared = ChordBreakerPoster()

    // Confined to the shortcut tap thread.
    private var filter: SystemShortcutEventTap?
    private var lastFailureLogAt: TimeInterval?

    func post(flags: CGEventFlags) -> Bool {
        precondition(ShortcutEventTapThread.shared.isCurrent)
        // Taps receive no key events during Secure Event Input, so the filter could not drop the breaker.
        guard !IsSecureEventInputEnabled() else { return false }
        guard isFilterEnabled() else { return false }
        let events = ChordBreaker.makeEvents(flags: flags)
        guard events.count == 2 else { return false }
        for event in events { event.post(tap: .cghidEventTap) }
        return true
    }

    private func isFilterEnabled() -> Bool {
        if let filter, filter.isValid {
            if !filter.isEnabled { filter.enable() }
            return filter.isEnabled
        }
        filter?.stop()
        filter = nil
        do {
            let mask = (CGEventMask(1) << CGEventType.keyDown.rawValue) | (CGEventMask(1) << CGEventType.keyUp.rawValue)
            filter = try SystemShortcutEventTap(eventsOfInterest: mask, location: .cgAnnotatedSessionEventTap) { [weak self] type, event in
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    self?.filter?.enable()
                    return false
                }
                return ChordBreaker.isChordBreaker(type: type, event: event)
            }
            return true
        } catch {
            let now = ProcessInfo.processInfo.systemUptime
            if lastFailureLogAt.map({ now - $0 >= 60 }) ?? true {
                lastFailureLogAt = now
                ShortcutDiagnostics.warning("chord-breaker result=unavailable reason=filter-install-failed")
            }
            return false
        }
    }
}
