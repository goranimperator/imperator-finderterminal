import AppKit

/// Talks to Finder over Apple events: read the frontmost window's folder, and
/// navigate the frontmost window to a path. Requires Automation permission
/// (granted on first use; NSAppleEventsUsageDescription must be in Info.plist).
///
/// Every Apple event runs on one private serial queue, never on the main
/// thread. A round trip to Finder costs 15-35 ms even for the smallest
/// question, which is a long time to hold the main thread: it freezes drawing
/// and, because the close-guard event tap lives on the main run loop, it also
/// delays keystrokes in every other app (measured: up to 93 ms extra).
///
/// `NSAppleScript` is not documented as thread-safe, so the rule is strict:
/// scripts are created and run on `queue` and nowhere else, and are never
/// shared with another thread. A stress run of 300 events through this
/// arrangement succeeded 300 times with the main run loop never stalled more
/// than a millisecond or so.
enum FinderBridge {
    private static let queue = DispatchQueue(
        label: "com.goranimperator.ImperatorFinderTerminal.finder-bridge", qos: .userInitiated)

    /// Compiled once, on `queue`; this script runs on every open and every folder change.
    private static var folderScript: NSAppleScript?

    /// POSIX path of the folder shown in the frontmost Finder window, or nil.
    /// `completion` is called on the main thread.
    static func frontmostFolder(_ completion: @escaping (String?) -> Void) {
        queue.async {
            let script = folderScript ?? NSAppleScript(source: """
            tell application "Finder"
                if (count of Finder windows) is 0 then return ""
                try
                    return POSIX path of (target of front Finder window as alias)
                on error
                    return ""
                end try
            end tell
            """)
            folderScript = script
            var err: NSDictionary?
            let out = script?.executeAndReturnError(&err).stringValue
            let path = (out?.isEmpty == false) ? out : nil
            DispatchQueue.main.async { completion(path) }
        }
    }

    /// Open a fresh Finder window, sized generously (Finder's default window is
    /// too small to shrink for docking) and bring Finder forward. `folder` keeps
    /// a replacement window on the directory the user was in; nil = home.
    static func openNewWindow(at folder: String? = nil) {
        let screen = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let fullHeight = NSScreen.main?.frame.height ?? screen.maxY
        let w = (screen.width * 0.5).rounded()
        let h = (screen.height * 0.75).rounded()
        let x = (screen.minX + (screen.width - w) / 2).rounded()
        let cocoaY = (screen.minY + (screen.height - h) / 2).rounded()
        let top = (fullHeight - (cocoaY + h)).rounded()   // AppleScript bounds are top-left based
        // Fall back to home if the folder is gone (deleted, unmounted).
        let target = folder.map { "(POSIX file \"\(PathUtil.appleScriptQuote($0))\" as alias)" }
            ?? "(path to home folder)"
        let src = """
        tell application "Finder"
            activate
            try
                set w to make new Finder window to \(target)
            on error
                set w to make new Finder window to (path to home folder)
            end try
            set bounds of w to {\(Int(x)), \(Int(top)), \(Int(x + w)), \(Int(top + h))}
        end tell
        """
        queue.async { _ = run(src) }
    }

    // MARK: Navigation, coalesced

    // Main thread only. A shell can `cd` many times in a burst (a script, a held
    // key, `cd -` in a loop); only the last folder matters, and each Apple event
    // takes tens of milliseconds, so while one is in flight newer paths replace
    // each other instead of queueing up behind it.
    private static var pendingPath: String?
    private static var navigating = false

    /// Point the frontmost Finder window at `path` (opens a new window if none).
    /// Returns at once; the Apple event runs on `queue`.
    static func navigate(to path: String) {
        pendingPath = path
        guard !navigating else { return }
        drainNavigation()
    }

    private static func drainNavigation() {
        guard let path = pendingPath else { navigating = false; return }
        pendingPath = nil
        navigating = true
        let p = PathUtil.appleScriptQuote(path)
        let src = """
        tell application "Finder"
            set p to POSIX file "\(p)" as alias
            if (count of Finder windows) is 0 then
                make new Finder window to p
            else
                set target of front Finder window to p
            end if
        end tell
        """
        queue.async {
            _ = run(src)
            DispatchQueue.main.async { drainNavigation() }
        }
    }

    /// Must be called on `queue`.
    @discardableResult
    private static func run(_ source: String) -> String? {
        dispatchPrecondition(condition: .onQueue(queue))
        var err: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return nil }
        let result = script.executeAndReturnError(&err)
        if let err { NSLog("FinderBridge AppleScript error: \(err)"); return nil }
        return result.stringValue
    }
}
