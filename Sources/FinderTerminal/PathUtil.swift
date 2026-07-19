import Foundation

enum PathUtil {
    /// Normalize a filesystem path for loop-safe comparison between Finder and the shell.
    /// Handles `file://` URLs (from OSC 7), percent-encoding, symlinks and trailing slashes.
    static func normalize(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return nil }
        if s.contains("://") {
            // OSC 7 gives file://host/path — pull out the path component.
            if let comps = URLComponents(string: s), let p = comps.path.removingPercentEncoding {
                s = p
            } else if let u = URL(string: s) {
                s = u.path
            }
        }
        s = (s as NSString).expandingTildeInPath
        guard s.hasPrefix("/") else { return nil }
        // standardizedFileURL resolves .. and trailing slash consistently.
        return URL(fileURLWithPath: s).standardizedFileURL.path
    }

    /// Wrap a path as a single-quoted shell token.
    static func shellQuote(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Escape a string for embedding inside an AppleScript double-quoted literal.
    static func appleScriptQuote(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
