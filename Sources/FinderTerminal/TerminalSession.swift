import AppKit
import SwiftTerm

/// Owns a single persistent shell running in a SwiftTerm view.
/// - Applies the Terminal.app theme.
/// - `cd(to:)` drives the shell into a folder (Finder -> terminal).
/// - Reports shell-initiated directory changes via `onDirChangeFromShell` (terminal -> Finder),
///   using OSC 7 which the system emits because we spawn with TERM_PROGRAM=Apple_Terminal.
final class TerminalSession: NSObject, LocalProcessTerminalViewDelegate {
    let view: LocalProcessTerminalView
    private var started = false

    /// The directory both sides currently agree on (normalized). Single source of
    /// truth that breaks the Finder<->terminal feedback loop: a change is only
    /// propagated when it differs from this.
    private(set) var currentDir: String?

    /// Called when the user `cd`s inside the shell. Receives a normalized path.
    var onDirChangeFromShell: ((String) -> Void)?

    /// A `cd` we sent that the shell has not echoed back yet. The pre-spawned
    /// shell's first prompt still reports its spawn directory, and propagating
    /// that would drag Finder to the wrong folder for a moment. Bounded in time
    /// so a shell that never confirms cannot disable the reverse sync.
    private var awaiting: (dir: String, sentAt: Date)?

    override init() {
        view = LocalProcessTerminalView(frame: .zero)
        super.init()
        view.processDelegate = self
        applyTheme()
    }

    @discardableResult
    func applyTheme() -> TerminalTheme {
        let t = TerminalTheme.current()
        // Opaque profile background: the panel's terminal plate paints the same
        // color behind the inset text area, so plate padding and text area read
        // as one seamless surface.
        view.nativeBackgroundColor = (t.background ?? .black).withAlphaComponent(1)
        if let fg = t.foreground { view.nativeForegroundColor = fg }
        if let cur = t.cursor { view.caretColor = cur }
        if let sel = t.selection { view.selectedTextBackgroundColor = sel }
        if t.ansi.count == 16 { view.installColors(t.ansi) }
        view.font = t.font
        if view.lineSpacing != t.lineHeight { view.lineSpacing = t.lineHeight }
        return t
    }

    func startIfNeeded(dir: String) {
        guard !started else { return }
        started = true
        currentDir = PathUtil.normalize(dir)

        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        // Makes /etc/zshrc source /etc/zshrc_Apple_Terminal, which emits OSC 7 on every prompt.
        env["TERM_PROGRAM"] = "Apple_Terminal"
        let envArray = env.map { "\($0.key)=\($0.value)" }

        // -l: login shell so the user's PATH and rc files load, like Terminal.app.
        view.startProcess(executable: shell, args: ["-l"], environment: envArray,
                          execName: nil, currentDirectory: dir)
    }

    /// Finder -> terminal. Only sends `cd` if the folder actually differs.
    func cd(to rawPath: String) {
        guard started, let path = PathUtil.normalize(rawPath), path != currentDir else { return }
        currentDir = path
        awaiting = (path, Date())
        // Ctrl-U clears any half-typed line first so we don't corrupt the user's input.
        view.send(txt: "\u{15}cd \(PathUtil.shellQuote(path))\r")
    }

    /// Names of processes currently running under the shell (empty = idle prompt).
    func runningProcessNames() -> [String] {
        guard started, view.process.shellPid > 0 else { return [] }
        // -l lists "pid name" per line — one spawn instead of pgrep + ps-per-pid.
        return Self.run("/usr/bin/pgrep", ["-lP", "\(view.process.shellPid)"])
            .split(separator: "\n")
            .compactMap { line in
                line.split(separator: " ", maxSplits: 1)
                    .dropFirst().first.map { String($0) }
            }
    }

    /// Kill the shell and everything under it, like closing a real terminal
    /// window: SIGHUP to the shell's process group.
    func terminate() {
        guard started else { return }
        let pid = view.process.shellPid
        if pid > 0 { kill(-pid, SIGHUP) }
        started = false
        currentDir = nil
        awaiting = nil
    }

    private static func run(_ path: String, _ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        try? p.run()
        p.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }

    // MARK: LocalProcessTerminalViewDelegate

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        guard let dir = directory, let path = PathUtil.normalize(dir) else { return }
        if let awaiting, Date().timeIntervalSince(awaiting.sentAt) < 2 {
            // Still catching up with our own cd: this prompt is stale.
            if path == awaiting.dir { self.awaiting = nil }
            return
        }
        awaiting = nil
        guard path != currentDir else { return }
        currentDir = path
        onDirChangeFromShell?(path)
    }

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        // Shell exited (user typed `exit`). Allow a fresh spawn on next open.
        started = false
        currentDir = nil
    }
}
