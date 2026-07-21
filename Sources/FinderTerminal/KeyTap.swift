import AppKit
import IOKit.hid

/// CGEventTap that intercepts Cmd-W BEFORE Finder closes the window, so the
/// terminate-warning can veto the close entirely (the red close button cannot
/// be intercepted — macOS offers no API — so that path keeps the post-close
/// alert). Requires Accessibility, which the app already has.
final class KeyTap {
    /// Called on the main run loop for every plain Cmd-W anywhere; return true
    /// to swallow the event (the owner then runs its own close flow).
    var onCmdW: (() -> Bool)?

    private var tap: CFMachPort?

    init() {
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let me = Unmanaged<KeyTap>.fromOpaque(refcon).takeUnretainedValue()
                return me.handle(type: type, event: event)
            },
            userInfo: selfPtr)
        guard let tap else {
            devLog("KeyTap: tap creation FAILED (missing permission?)")
            return
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        // Keyboard taps silently receive no events without Input Monitoring on
        // recent macOS — surface the grant state for diagnosis.
        let hid = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)
        devLog("KeyTap: active (inputMonitoring=\(hid == kIOHIDAccessTypeGranted ? "granted" : "\(hid.rawValue)"))")
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // The system disables taps that stall; re-enable.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard type == .keyDown,
              event.getIntegerValueField(.keyboardEventKeycode) == 13,   // W
              event.flags.contains(.maskCommand),
              !event.flags.contains(.maskAlternate),
              !event.flags.contains(.maskControl),
              !event.flags.contains(.maskShift)
        else { return Unmanaged.passUnretained(event) }

        // The run-loop source lives on the main run loop, so this callback IS
        // on main — query directly (a main.sync here deadlocks and traps).
        guard onCmdW?() ?? false else { return Unmanaged.passUnretained(event) }
        return nil   // swallow: Finder never sees the Cmd-W
    }
}
