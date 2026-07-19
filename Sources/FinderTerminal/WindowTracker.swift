import AppKit
import ApplicationServices

/// Accessibility-based control of the frontmost Finder window: read its frame,
/// resize it (to make room for the docked terminal), and observe move/resize/
/// navigation/close events.
final class WindowTracker {
    private var observer: AXObserver?
    private(set) var window: AXUIElement?

    var onGeometryChange: (() -> Void)?   // moved / resized
    var onFolderChange: (() -> Void)?     // title changed ~= navigated
    var onWindowClosed: (() -> Void)?     // window destroyed

    static var isTrusted: Bool { AXIsProcessTrusted() }

    private static func finderPID() -> pid_t? {
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder")
            .first?.processIdentifier
    }

    /// True for real, user-facing Finder windows — filters out the desktop window,
    /// which Finder also reports (it spans the whole screen and must never be docked to).
    private static func isStandardWindow(_ w: AXUIElement) -> Bool {
        var subrole: CFTypeRef?
        guard AXUIElementCopyAttributeValue(w, kAXSubroleAttribute as CFString, &subrole) == .success,
              let s = subrole as? String else { return false }
        return s == (kAXStandardWindowSubrole as String)
    }

    /// Grab the frontmost Finder window as the tracked window. Returns its Cocoa frame.
    @discardableResult
    func attachToFrontWindow() -> CGRect? {
        stopObserving()
        window = nil
        guard let pid = Self.finderPID() else { return nil }
        let app = AXUIElementCreateApplication(pid)
        var win: CFTypeRef?
        if AXUIElementCopyAttributeValue(app, kAXMainWindowAttribute as CFString, &win) == .success,
           let w = win, Self.isStandardWindow(w as! AXUIElement) {
            window = (w as! AXUIElement)
        } else {
            var wins: CFTypeRef?
            if AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &wins) == .success,
               let arr = wins as? [AXUIElement] {
                window = arr.first(where: Self.isStandardWindow)
            }
        }
        return currentFrame()
    }

    /// Cocoa (bottom-left origin, global) frame of the tracked window.
    func currentFrame() -> CGRect? {
        guard let w = window else { return nil }
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(w, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(w, kAXSizeAttribute as CFString, &sizeRef) == .success
        else { return nil }
        var p = CGPoint.zero
        var s = CGSize.zero
        AXValueGetValue(posRef as! AXValue, .cgPoint, &p)
        AXValueGetValue(sizeRef as! AXValue, .cgSize, &s)
        return Self.axToCocoa(CGRect(origin: p, size: s))
    }

    /// Grow (positive delta) or shrink (negative) the tracked window along the given
    /// edge. AX origin is top-left, so changes toward top/left also move the origin;
    /// the opposite edge stays put — freeing space for the terminal on that side.
    func adjust(side: DockSide, by delta: CGFloat) {
        guard let w = window else { return }
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(w, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(w, kAXSizeAttribute as CFString, &sizeRef) == .success
        else { return }
        var p = CGPoint.zero
        var s = CGSize.zero
        AXValueGetValue(posRef as! AXValue, .cgPoint, &p)
        AXValueGetValue(sizeRef as! AXValue, .cgSize, &s)
        switch side {
        case .bottom: s.height += delta
        case .top: p.y -= delta; s.height += delta
        case .left: p.x -= delta; s.width += delta
        case .right: s.width += delta
        }
        if let pv = AXValueCreate(.cgPoint, &p) {
            AXUIElementSetAttributeValue(w, kAXPositionAttribute as CFString, pv)
        }
        if let sv = AXValueCreate(.cgSize, &s) {
            AXUIElementSetAttributeValue(w, kAXSizeAttribute as CFString, sv)
        }
    }

    /// AX reports top-left origin measured from the menu-bar screen; Cocoa is bottom-left.
    static func axToCocoa(_ r: CGRect) -> CGRect {
        let menuBarScreen = NSScreen.screens.first { $0.frame.origin == .zero } ?? NSScreen.main
        let h = menuBarScreen?.frame.height ?? 0
        return CGRect(x: r.origin.x, y: h - r.origin.y - r.size.height,
                      width: r.size.width, height: r.size.height)
    }

    private static let notes = [
        kAXMovedNotification, kAXResizedNotification,
        kAXTitleChangedNotification, kAXUIElementDestroyedNotification,
    ]

    func startObserving() {
        guard observer == nil, let pid = Self.finderPID(), let window else { return }

        let callback: AXObserverCallback = { _, _, notification, refcon in
            guard let refcon else { return }
            let me = Unmanaged<WindowTracker>.fromOpaque(refcon).takeUnretainedValue()
            let note = notification as String
            DispatchQueue.main.async {
                switch note {
                case kAXTitleChangedNotification as String: me.onFolderChange?()
                case kAXUIElementDestroyedNotification as String: me.onWindowClosed?()
                default: me.onGeometryChange?()
                }
            }
        }

        var obs: AXObserver?
        guard AXObserverCreate(pid, callback, &obs) == .success, let obs else { return }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for note in Self.notes {
            AXObserverAddNotification(obs, window, note as CFString, refcon)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
        observer = obs
    }

    func stopObserving() {
        if let obs = observer, let w = window {
            for note in Self.notes {
                AXObserverRemoveNotification(obs, w, note as CFString)
            }
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
        }
        observer = nil
    }
}
