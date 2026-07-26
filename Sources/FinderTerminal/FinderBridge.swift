import AppKit

/// Talks to Finder over Apple events: read the frontmost window's folder, and
/// navigate the frontmost window to a path. Requires Automation permission
/// (granted on first use; NSAppleEventsUsageDescription must be in Info.plist).
enum FinderBridge {
    /// Compiled once; this script runs on every open and every folder change.
    private static let frontmostFolderScript = NSAppleScript(source: """
    tell application "Finder"
        if (count of Finder windows) is 0 then return ""
        try
            return POSIX path of (target of front Finder window as alias)
        on error
            return ""
        end try
    end tell
    """)

    /// POSIX path of the folder shown in the frontmost Finder window, or nil.
    static func frontmostFolder() -> String? {
        assert(Thread.isMainThread)
        var err: NSDictionary?
        guard let out = frontmostFolderScript?.executeAndReturnError(&err).stringValue,
              !out.isEmpty else { return nil }
        return out
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
        _ = run(src)
    }

    /// Point the frontmost Finder window at `path` (opens a new window if none).
    static func navigate(to path: String) {
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
        _ = run(src)
    }

    @discardableResult
    private static func run(_ source: String) -> String? {
        // NSAppleScript must run on the main thread.
        assert(Thread.isMainThread)
        var err: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return nil }
        let result = script.executeAndReturnError(&err)
        if let err { NSLog("FinderBridge AppleScript error: \(err)") ; return nil }
        return result.stringValue
    }
}
