import AppKit
import ApplicationServices

/// Accessibility-based tracking of the frontmost Finder window: its screen frame,
/// and notifications when it moves, resizes, or navigates to another folder.
final class WindowTracker {
    private var observer: AXObserver?
    private var observedWindow: AXUIElement?

    var onGeometryChange: (() -> Void)?   // moved / resized
    var onFolderChange: (() -> Void)?     // title changed ~= navigated

    static var isTrusted: Bool { AXIsProcessTrusted() }

    private static func finderPID() -> pid_t? {
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder")
            .first?.processIdentifier
    }

    private func frontWindow() -> AXUIElement? {
        guard let pid = Self.finderPID() else { return nil }
        let app = AXUIElementCreateApplication(pid)
        var win: CFTypeRef?
        if AXUIElementCopyAttributeValue(app, kAXMainWindowAttribute as CFString, &win) == .success,
           let w = win {
            return (w as! AXUIElement)
        }
        var wins: CFTypeRef?
        if AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &wins) == .success,
           let arr = wins as? [AXUIElement], let first = arr.first {
            return first
        }
        return nil
    }

    /// Cocoa (bottom-left origin, global) frame of the frontmost Finder window.
    func frontmostFrame() -> CGRect? {
        guard let w = frontWindow() else { return nil }
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

    /// AX reports top-left origin measured from the menu-bar screen; Cocoa is bottom-left.
    static func axToCocoa(_ r: CGRect) -> CGRect {
        let menuBarScreen = NSScreen.screens.first { $0.frame.origin == .zero } ?? NSScreen.main
        let h = menuBarScreen?.frame.height ?? 0
        return CGRect(x: r.origin.x, y: h - r.origin.y - r.size.height,
                      width: r.size.width, height: r.size.height)
    }

    func startObserving() {
        stopObserving()
        guard let pid = Self.finderPID(), let window = frontWindow() else { return }

        let callback: AXObserverCallback = { _, _, notification, refcon in
            guard let refcon else { return }
            let me = Unmanaged<WindowTracker>.fromOpaque(refcon).takeUnretainedValue()
            let isTitle = (notification as String) == (kAXTitleChangedNotification as String)
            DispatchQueue.main.async {
                if isTitle { me.onFolderChange?() } else { me.onGeometryChange?() }
            }
        }

        var obs: AXObserver?
        guard AXObserverCreate(pid, callback, &obs) == .success, let obs else { return }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for note in [kAXMovedNotification, kAXResizedNotification, kAXTitleChangedNotification] {
            AXObserverAddNotification(obs, window, note as CFString, refcon)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
        observer = obs
        observedWindow = window
    }

    func stopObserving() {
        if let obs = observer, let w = observedWindow {
            for note in [kAXMovedNotification, kAXResizedNotification, kAXTitleChangedNotification] {
                AXObserverRemoveNotification(obs, w, note as CFString)
            }
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
        }
        observer = nil
        observedWindow = nil
    }
}
