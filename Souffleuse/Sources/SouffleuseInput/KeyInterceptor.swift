import CoreGraphics
import Foundation

/// Session-level CGEventTap that consumes Tab/Esc when a suggestion is active.
///
/// The tap is created up-front but kept disabled until `setActive(true)` is called.
/// Disabling when no suggestion is showing avoids needlessly processing every
/// keystroke in the system.
public final class KeyInterceptor: @unchecked Sendable {
    public enum Key: Sendable {
        case tab
        case esc
    }

    /// Called on the event-tap thread. Return true to consume the key event,
    /// false to let it pass through to the focused app.
    public typealias Handler = @Sendable (Key) -> Bool

    private let handler: Handler
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var active = false

    public init(handler: @escaping Handler) {
        self.handler = handler
    }

    /// Install the tap on the main runloop. Must be called from the main thread.
    /// Returns false if the tap couldn't be created (typically missing
    /// Accessibility / Input Monitoring permission).
    @discardableResult
    public func install() -> Bool {
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let me = Unmanaged<KeyInterceptor>.fromOpaque(refcon).takeUnretainedValue()
                return me.handle(type: type, event: event)
            },
            userInfo: selfPtr
        ) else {
            return false
        }
        self.tap = tap

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        // Start disabled — only become active when a suggestion is showing.
        CGEvent.tapEnable(tap: tap, enable: false)
        return true
    }

    /// Toggle whether the tap consumes Tab/Esc. When inactive, all key events
    /// flow through untouched (Tab still does its normal job in forms, etc.).
    public func setActive(_ active: Bool) {
        guard let tap else { return }
        self.active = active
        CGEvent.tapEnable(tap: tap, enable: active)
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            // macOS disabled the tap (we took too long, or user input quirk).
            // Re-enable so we keep working.
            if let tap, active {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }
        guard type == .keyDown else {
            return Unmanaged.passUnretained(event)
        }
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let key: Key
        switch keyCode {
        case 48: key = .tab
        case 53: key = .esc
        default: return Unmanaged.passUnretained(event)
        }
        if handler(key) {
            return nil
        }
        return Unmanaged.passUnretained(event)
    }
}
