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
        if AXUIElementCopyAttributeValue(w, kAXSubroleAttribute as CFString, &subrole) == .success,
           let s = subrole as? String, s == (kAXStandardWindowSubrole as String) { return true }
        // A fullscreen window is a real window whatever subrole it reports; the
        // desktop never carries the fullscreen attribute.
        var full: CFTypeRef?
        return AXUIElementCopyAttributeValue(w, "AXFullScreen" as CFString, &full) == .success
            && (full as? Bool) == true
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

    /// Re-attach to a specific window by its CGWindowID. Used when a fullscreen
    /// transition replaces the AX element of a window that is still very much
    /// alive. Returns its Cocoa frame.
    @discardableResult
    func attach(windowID: CGWindowID) -> CGRect? {
        stopObserving()
        window = nil
        guard let pid = Self.finderPID() else { return nil }
        let app = AXUIElementCreateApplication(pid)
        var wins: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &wins) == .success,
              let candidates = wins as? [AXUIElement] else { return nil }
        for candidate in candidates where Self.isStandardWindow(candidate) {
            window = candidate
            if windowNumber() == windowID { return currentFrame() }
        }
        window = nil
        return nil
    }

    /// Is this window still known to the window server (any space)?
    static func exists(windowID: CGWindowID) -> Bool {
        guard let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID)
                as? [[String: Any]] else { return false }
        return list.contains { ($0[kCGWindowNumber as String] as? CGWindowID) == windowID }
    }

    /// Raw AX frame: top-left origin, same coordinate space as CGWindowList.
    private func rawFrame() -> CGRect? {
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
        return CGRect(origin: p, size: s)
    }

    /// Cocoa (bottom-left origin, global) frame of the tracked window.
    func currentFrame() -> CGRect? {
        rawFrame().map(Self.axToCocoa)
    }

    /// True while the window owns a fullscreen space. Such a window cannot be
    /// resized through AX — the space fixes its frame — so the terminal has to
    /// overlay it instead of docking beside it.
    var isFullScreen: Bool {
        guard let w = window else { return false }
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(w, "AXFullScreen" as CFString, &v) == .success
        else { return false }
        return (v as? Bool) ?? false
    }

    /// Finder applies AX position/size writes asynchronously; reading straight
    /// back returns the old frame. Poll briefly until the frame changes.
    func settledFrame(after previous: CGRect) -> CGRect? {
        let deadline = Date().addingTimeInterval(0.15)
        while Date() < deadline {
            if let f = currentFrame(), f != previous { return f }
            usleep(20_000)
        }
        return currentFrame()
    }

    /// CGWindowID of the tracked window, resolved by matching the AX frame
    /// against Finder's on-screen windows. Used to slot the terminal panel
    /// directly above its Finder window in the global z-order.
    func windowNumber() -> CGWindowID? {
        // On-screen first (cheapest, unambiguous). A window in a fullscreen space
        // that is not the space being shown is absent from that list, so fall
        // back to every window before giving up.
        windowNumber(options: [.optionOnScreenOnly]) ?? windowNumber(options: [.optionAll])
    }

    private func windowNumber(options: CGWindowListOption) -> CGWindowID? {
        guard let pid = Self.finderPID(), let raw = rawFrame(),
              let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID)
                as? [[String: Any]] else { return nil }
        for info in list {
            guard let owner = info[kCGWindowOwnerPID as String] as? pid_t, owner == pid,
                  let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let b = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = b["X"], let y = b["Y"], let w = b["Width"], let h = b["Height"]
            else { continue }
            if abs(x - raw.minX) < 2, abs(y - raw.minY) < 2,
               abs(w - raw.width) < 2, abs(h - raw.height) < 2 {
                return info[kCGWindowNumber as String] as? CGWindowID
            }
        }
        return nil
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

    /// Enter or leave the native fullscreen space. Returns false when the write
    /// was rejected.
    @discardableResult
    func setFullScreen(_ on: Bool) -> Bool {
        guard let w = window else { return false }
        return AXUIElementSetAttributeValue(w, "AXFullScreen" as CFString, on as CFTypeRef) == .success
    }

    /// Press the tracked window's close button (AX) — closes the Finder window
    /// exactly like clicking the red button.
    func pressCloseButton() {
        guard let w = window else { return }
        var btn: CFTypeRef?
        if AXUIElementCopyAttributeValue(w, kAXCloseButtonAttribute as CFString, &btn) == .success,
           let b = btn {
            AXUIElementPerformAction(b as! AXUIElement, kAXPressAction as CFString)
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
                case kAXTitleChangedNotification: me.onFolderChange?()
                case kAXUIElementDestroyedNotification: me.onWindowClosed?()
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
