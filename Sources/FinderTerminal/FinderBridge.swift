import AppKit

/// Talks to Finder over Apple events: read the frontmost window's folder, and
/// navigate the frontmost window to a path. Requires Automation permission
/// (granted on first use; NSAppleEventsUsageDescription must be in Info.plist).
enum FinderBridge {
    /// POSIX path of the folder shown in the frontmost Finder window, or nil.
    static func frontmostFolder() -> String? {
        let src = """
        tell application "Finder"
            if (count of Finder windows) is 0 then return ""
            try
                return POSIX path of (target of front Finder window as alias)
            on error
                return ""
            end try
        end tell
        """
        guard let out = run(src), !out.isEmpty else { return nil }
        return out
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
