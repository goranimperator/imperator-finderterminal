import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var eventMonitor: Any?
    private var hotkey: Hotkey?
    private var keyTap: KeyTap?
    private var mouseMonitors: [Any] = []
    private var devRemote: DevRemote?
    private var settingsWindow: NSWindow?
    private var lastSettingsFingerprint = ""

    /// One terminal per Finder window, keyed by CGWindowID.
    private var terminals: [CGWindowID: DockedTerminal] = [:]
    /// Pre-spawned shell so the next open shows a ready prompt instantly.
    private var spareSession: TerminalSession?

    /// Quake fallback (no Accessibility): a single free-floating terminal.
    private var quakeSession: TerminalSession?
    private var quakePanel: TerminalPanel?
    private var quakeOpen = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Brandbook 18.1: force dark mode, override accent, set process name.
        NSApp.appearance = NSAppearance(named: .darkAqua)
        UserDefaults.standard.set(0, forKey: "AppleAccentColor")
        ProcessInfo.processInfo.setValue("Imperator FinderTerminal", forKey: "processName")

        setupStatusItem()
        setupPopover()
        promptAccessibility()

        // Live-apply settings changes (theme colors, font size, hotkey).
        NotificationCenter.default.addObserver(
            self, selector: #selector(settingsChanged),
            name: UserDefaults.didChangeNotification, object: nil)
        lastSettingsFingerprint = Self.settingsFingerprint()

        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(frontAppChanged(_:)),
            name: NSWorkspace.didActivateApplicationNotification, object: nil)

        // Mouse-riding drag follow + z-order upkeep, fanned out to every terminal.
        mouseMonitors = [
            NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDragged], handler: { [weak self] _ in
                self?.terminals.values.forEach { $0.predictDragPosition() }
            }),
            NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp], handler: { [weak self] _ in
                self?.terminals.values.forEach { $0.settleDrag() }
            }),
        ].compactMap { $0 }

        hotkey = Hotkey { [weak self] in self?.toggleTerminal() }

        // Intercept Cmd-W before Finder closes a window that has a busy terminal,
        // so the warning can veto the close (red button can't be intercepted).
        let tap = KeyTap()
        tap.onCmdW = { [weak self] in
            // confirmCloseFromKeyboard handles both busy (ask) and idle (close
            // immediately). Two focus cases: Finder frontmost (its front window
            // has a terminal), or our own terminal panel focused — the panel
            // steals key focus on open, so Cmd-W usually lands here.
            guard let self, let t = self.cmdWTarget() else { return false }
            // Defer the alert flow out of event-tap processing.
            DispatchQueue.main.async { t.confirmCloseFromKeyboard() }
            return true
        }
        keyTap = tap

        devRemote = DevRemote(
            onToggle: { [weak self] in self?.toggleTerminal() },
            onSnapshot: { [weak self] path in self?.devSnapshot(to: path) },
            onExec: { [weak self] cmd in self?.frontTerminalSession()?.view.send(txt: cmd + "\r") }
        )

        refillSpare()
    }

    func applicationWillTerminate(_ notification: Notification) {
        terminals.values.forEach { $0.restoreOnQuit() }
    }

    // MARK: Toggle / open

    @objc private func toggleTerminal() {
        guard WindowTracker.isTrusted else { toggleQuake(); return }

        if let id = frontmostFinderWindowID(), let t = terminals[id] {
            t.requestClose()
            return
        }
        openOnFrontmostWindow(allowNewWindow: true)
    }

    private func frontmostFinderWindowID() -> CGWindowID? {
        let probe = WindowTracker()
        guard probe.attachToFrontWindow() != nil else { return nil }
        return probe.windowNumber()
    }

    /// The terminal a Cmd-W press is aimed at, if any.
    private func cmdWTarget() -> DockedTerminal? {
        switch NSWorkspace.shared.frontmostApplication?.bundleIdentifier {
        case "com.apple.finder":
            return frontmostFinderWindowID().flatMap { terminals[$0] }
        case Bundle.main.bundleIdentifier:
            guard let panel = NSApp.keyWindow as? TerminalPanel else { return nil }
            return terminals.values.first { $0.panel === panel }
        default:
            return nil
        }
    }

    private func frontTerminalSession() -> TerminalSession? {
        if let id = frontmostFinderWindowID(), let t = terminals[id] { return t.session }
        return terminals.values.first?.session ?? quakeSession
    }

    private func openOnFrontmostWindow(allowNewWindow: Bool) {
        let session = takeSpareSession()
        if let t = DockedTerminal(session: session, side: AppSettings.position) {
            adopt(t)
            return
        }
        // AX can be transiently slow — retry once before opening a new window.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self else { return }
            if let t = DockedTerminal(session: session, side: AppSettings.position) {
                self.adopt(t)
                return
            }
            guard allowNewWindow else { session.terminate(); return }
            devLog("both dock attempts failed -> opening new window")
            FinderBridge.openNewWindow()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                guard let self else { return }
                if let t = DockedTerminal(session: session, side: AppSettings.position) {
                    self.adopt(t)
                } else {
                    session.terminate()
                }
            }
        }
    }

    private func adopt(_ t: DockedTerminal) {
        terminals[t.windowID] = t
        t.onFinished = { [weak self] finished in
            self?.terminals.removeValue(forKey: finished.windowID)
        }
        t.onWantsNewWindow = { [weak self] session in
            // Cancel path of the post-close alert: dock the surviving session
            // to a fresh Finder window.
            FinderBridge.openNewWindow()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                if let nt = DockedTerminal(session: session, side: AppSettings.position) {
                    self?.adopt(nt)
                } else {
                    session.terminate()
                }
            }
        }
        refillSpare()
    }

    private func takeSpareSession() -> TerminalSession {
        let s = spareSession ?? TerminalSession()
        spareSession = nil
        s.startIfNeeded(dir: FinderBridge.frontmostFolder() ?? NSHomeDirectory())
        return s
    }

    private func refillSpare() {
        guard spareSession == nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, self.spareSession == nil else { return }
            let s = TerminalSession()
            s.startIfNeeded(dir: NSHomeDirectory())
            self.spareSession = s
        }
    }

    // MARK: Quake fallback (no Accessibility)

    private func toggleQuake() {
        if quakeOpen {
            quakePanel?.hide()
            quakeOpen = false
            return
        }
        let session = quakeSession ?? TerminalSession()
        quakeSession = session
        session.startIfNeeded(dir: FinderBridge.frontmostFolder() ?? NSHomeDirectory())
        let panel = quakePanel ?? TerminalPanel(terminal: session.view)
        quakePanel = panel
        panel.applyTheme(session.applyTheme())
        panel.show(at: TerminalPanel.quakeFrame())
        quakeOpen = true
    }

    // MARK: Global event fan-out

    @objc private func frontAppChanged(_ note: Notification) {
        terminals.values.forEach {
            $0.redock()
            $0.reassertOrder()
        }
    }

    private func promptAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    // MARK: Settings

    private static func settingsFingerprint() -> String {
        let d = UserDefaults.standard
        let keys = [AppSettings.themeKey, AppSettings.positionKey, AppSettings.fontSizeKey,
                    AppSettings.hotkeyKeyCodeKey, AppSettings.hotkeyModifiersKey]
            .map { d.string(forKey: $0) ?? String(d.double(forKey: $0)) }
        let themes = d.data(forKey: AppSettings.customThemesKey)?.hashValue ?? 0
        return keys.joined(separator: "|") + "|\(themes)"
    }

    @objc private func settingsChanged() {
        let fp = Self.settingsFingerprint()
        guard fp != lastSettingsFingerprint else { return }
        lastSettingsFingerprint = fp
        terminals.values.forEach { $0.applyTheme() }
        if let quakeSession, let quakePanel {
            quakePanel.applyTheme(quakeSession.applyTheme())
        }
        let hk = AppSettings.hotkey
        hotkey?.register(keyCode: hk.keyCode, modifiers: hk.modifiers)
        // Position changes apply to terminals opened from now on.
    }

    // Real settings window, same pattern as Imperator Dock Folders' main window.
    func showSettings() {
        if let w = settingsWindow, w.isVisible {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let win = settingsWindow ?? {
            // Initial height = the collapsed content incl. shortcut/alerts/position,
            // no scrollbar; user can resize vertically (width is fixed — single column).
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 490),
                             styleMask: [.titled, .closable, .resizable, .miniaturizable],
                             backing: .buffered, defer: false)
            w.isReleasedWhenClosed = false
            w.minSize = NSSize(width: 360, height: 490)
            w.maxSize = NSSize(width: 360, height: 2000)
            // Just above the floating terminal panel — settings must never end up behind it.
            w.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
            return w
        }()
        win.contentView = NSHostingView(rootView: SettingsView())
        win.title = "Imperator FinderTerminal Settings"
        win.setFrameAutosaveName("SettingsWindow")
        if settingsWindow == nil {
            // The autosaved frame may carry an older layout's height — open at
            // the designed size; resizes persist within the session only.
            win.setContentSize(NSSize(width: 360, height: 490))
            win.center()
        }
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow = win
    }

    // MARK: Menu bar + popover + about

    // Brandbook 8.1 + 18.1: square status item, 18pt template icon, click opens popover.
    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            let base = NSImage(systemSymbolName: "apple.terminal", accessibilityDescription: "Imperator FinderTerminal")
                ?? NSImage(systemSymbolName: "terminal", accessibilityDescription: "Imperator FinderTerminal")
            // Brandbook 8.1: 18x18pt logical size, template (programmatic NSImage allowed).
            if let img = base?.copy() as? NSImage {
                img.size = NSSize(width: 18, height: 18)
                img.isTemplate = true
                button.image = img
            }
            button.action = #selector(togglePopover)
            button.target = self
        }
    }

    // Brandbook 6.1 / 18.1: 340pt transient popover with SwiftUI content.
    private func setupPopover() {
        popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        let host = NSHostingController(rootView: PopoverContentView(
            onToggleTerminal: { [weak self] in
                self?.popover.performClose(nil)
                self?.toggleTerminal()
            },
            onShowAbout: { [weak self] in
                self?.popover.performClose(nil)
                self?.showAbout()
            },
            onShowSettings: { [weak self] in
                self?.popover.performClose(nil)
                self?.showSettings()
            }
        ))
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
        popover.contentSize = NSSize(width: 340, height: host.view.fittingSize.height)

        eventMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            self?.popover.performClose(nil)
        }
    }

    // Brandbook 10.2: About panel -- standalone NSPanel, 300x260, transparent title bar.
    private var aboutPanel: NSPanel?

    private func showAbout() {
        if aboutPanel == nil {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 260),
                                styleMask: [.titled, .closable, .fullSizeContentView],
                                backing: .buffered, defer: false)
            panel.titlebarAppearsTransparent = true
            panel.titleVisibility = .hidden
            panel.isMovableByWindowBackground = true
            panel.isReleasedWhenClosed = false
            panel.contentViewController = NSHostingController(rootView: AboutView())
            aboutPanel = panel
        }
        // True screen center on every open (center() sits high, near the menu
        // bar). Compute from the fixed content size — the live frame is not
        // laid out yet on the first open and reads as zero.
        if let panel = aboutPanel, let screen = NSScreen.main {
            let f = screen.frame
            let size = panel.frameRect(forContentRect: NSRect(x: 0, y: 0, width: 300, height: 260)).size
            panel.setFrame(NSRect(x: f.midX - size.width / 2, y: f.midY - size.height / 2,
                                  width: size.width, height: size.height), display: false)
        }
        aboutPanel?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    // MARK: Dev verification

    /// Write the frontmost terminal's rendered content + geometry state.
    private func devSnapshot(to path: String) {
        let t = (frontmostFinderWindowID().flatMap { terminals[$0] }) ?? terminals.values.first
        var meta: [String: Any] = [
            "terminalCount": terminals.count,
            "quakeOpen": quakeOpen,
        ]
        if let t {
            meta["shrunkBy"] = t.shrunkBy
            meta["panelFrame"] = NSStringFromRect(t.panel.frame)
            meta["panelVisible"] = t.panel.isShown
            meta["chromeColor"] = t.panel.debugChromeColor
            meta["font"] = "\(t.session.view.font.fontName) \(t.session.view.font.pointSize)"
            meta["lineSpacing"] = t.session.view.lineSpacing
        }
        if let data = try? JSONSerialization.data(withJSONObject: meta, options: [.sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: path + ".json"))
        }
        guard let v = t?.panel.contentView,
              let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
        v.cacheDisplay(in: v.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?
            .write(to: URL(fileURLWithPath: path + ".png"))
    }
}

/// Append a line to the dev decision log.
func devLog(_ s: String) {
    let line = s + "\n"
    let url = URL(fileURLWithPath: "/tmp/ft-dock.log")
    if let h = try? FileHandle(forWritingTo: url) {
        h.seekToEndOfFile()
        h.write(line.data(using: .utf8)!)
        try? h.close()
    } else {
        try? line.write(to: url, atomically: true, encoding: .utf8)
    }
}
