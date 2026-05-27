import CoreGraphics
import Foundation
import os

/// Session-level CGEventTap that consumes Tab/Esc when a suggestion is active.
///
/// The tap runs on a DEDICATED background thread with its own run loop — NOT
/// the main run loop. This is critical: while a ghost is showing the tap is
/// enabled and every keystroke passes through the tap's run loop. On the main
/// run loop that means each key waits behind whatever the main thread is doing
/// (the poll tick, AX snapshots, overlay layout) — fast typing then drops
/// letters and a delayed keyDown trips macOS's press-and-hold accent popup. A
/// dedicated thread keeps key delivery immediate regardless of main-thread load.
///
/// The tap is created up-front but kept disabled until `setActive(true)`.
/// Disabling when no suggestion shows means normal typing never touches the tap.
public final class KeyInterceptor: @unchecked Sendable {
    public enum Key: Sendable {
        case tab
        case esc
    }

    /// Called on the tap thread when a Tab/Esc keyDown arrives while active.
    /// Return true to CONSUME the key (swallow it), false to let it pass. The
    /// implementation must NOT block on the main thread — dispatch any
    /// main-actor work asynchronously and return the consume decision at once.
    public typealias Handler = @Sendable (Key) -> Bool

    private let handler: Handler
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var tapThread: Thread?
    private var tapRunLoop: CFRunLoop?
    /// `active` is written from the main thread (`setActive`) and read on the
    /// tap thread (`handle`), so it is guarded by a lock.
    private let lock = OSAllocatedUnfairLock(initialState: false)

    public init(handler: @escaping Handler) {
        self.handler = handler
    }

    /// Create the tap and start its dedicated run-loop thread. Must be called
    /// from the main thread. Returns false if the tap couldn't be created
    /// (typically missing Accessibility / Input Monitoring permission).
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

        // Run the tap's source on a dedicated thread's run loop so key delivery
        // is never delayed by main-thread work.
        let thread = Thread { [weak self] in
            guard let self, let tap = self.tap else { return }
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            self.runLoopSource = source
            let rl = CFRunLoopGetCurrent()
            self.tapRunLoop = rl
            CFRunLoopAddSource(rl, source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: false)  // start disabled
            CFRunLoopRun()
        }
        thread.name = "app.cocotypist.keytap"
        thread.qualityOfService = .userInteractive
        thread.start()
        self.tapThread = thread
        return true
    }

    /// Toggle whether the tap consumes Tab/Esc. When inactive, all key events
    /// flow through untouched (Tab still does its normal job in forms, etc.).
    public func setActive(_ active: Bool) {
        guard let tap else { return }
        lock.withLock { $0 = active }
        CGEvent.tapEnable(tap: tap, enable: active)
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            // macOS disabled the tap (we took too long, or user input quirk).
            // Re-enable so we keep working — only if we're still meant to be on.
            if let tap, lock.withLock({ $0 }) {
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
