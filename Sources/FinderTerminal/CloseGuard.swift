import AppKit
import IOKit.hid

/// CGEventTap that catches every way of closing a Finder window BEFORE Finder
/// sees it — Cmd-W and a click on the red close button — so the terminate
/// warning can veto the close and leave the window untouched. macOS offers no
/// way to veto a close after the fact, hence the tap. Requires Accessibility,
/// which the app already has.
final class CloseGuard {
    /// Plain Cmd-W anywhere. Return true to swallow it.
    var onCmdW: (() -> Bool)?
    /// A click at this point (global, top-left origin, as CGEvent reports it).
    /// Return true when it landed on the close button of a window we guard.
    var onCloseButtonClick: ((CGPoint) -> Bool)?
    /// A minimise is starting (yellow button or Cmd-M). Observed, never swallowed:
    /// AX only reports a minimise once its animation has finished, which is too
    /// late to fade along with it.
    var onMinimizeStart: ((CGPoint?) -> Void)?

    private var tap: CFMachPort?
    /// A mouse-down we swallowed: its mouse-up has to go too, or Finder sees a
    /// stray click on the button.
    private var swallowingClick = false

    init() {
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
            | CGEventMask(1 << CGEventType.leftMouseDown.rawValue)
            | CGEventMask(1 << CGEventType.leftMouseUp.rawValue)
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let me = Unmanaged<CloseGuard>.fromOpaque(refcon).takeUnretainedValue()
                return me.handle(type: type, event: event)
            },
            userInfo: selfPtr)
        guard let tap else {
            devLog("CloseGuard: tap creation FAILED (missing permission?)")
            return
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        // Taps silently receive nothing without Input Monitoring on recent
        // macOS — surface the grant state for diagnosis.
        let hid = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)
        devLog("CloseGuard: active (inputMonitoring=\(hid == kIOHIDAccessTypeGranted ? "granted" : "\(hid.rawValue)"))")
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // The system disables taps that stall; re-enable.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        // The run-loop source lives on the main run loop, so this callback IS on
        // main — query AX directly (a main.sync here deadlocks and traps).
        switch type {
        case .leftMouseDown:
            onMinimizeStart?(event.location)
            guard onCloseButtonClick?(event.location) ?? false else {
                return Unmanaged.passUnretained(event)
            }
            swallowingClick = true
            return nil
        case .leftMouseUp:
            guard swallowingClick else { return Unmanaged.passUnretained(event) }
            swallowingClick = false
            return nil
        case .keyDown:
            // Cmd-M minimises: observe it, let it through.
            if event.getIntegerValueField(.keyboardEventKeycode) == 46,       // M
               event.flags.contains(.maskCommand),
               !event.flags.contains(.maskAlternate), !event.flags.contains(.maskControl) {
                onMinimizeStart?(nil)
                return Unmanaged.passUnretained(event)
            }
            guard event.getIntegerValueField(.keyboardEventKeycode) == 13,   // W
                  event.flags.contains(.maskCommand),
                  !event.flags.contains(.maskAlternate),
                  !event.flags.contains(.maskControl),
                  !event.flags.contains(.maskShift),
                  onCmdW?() ?? false
            else { return Unmanaged.passUnretained(event) }
            return nil   // swallow: Finder never sees the Cmd-W
        default:
            return Unmanaged.passUnretained(event)
        }
    }
}
