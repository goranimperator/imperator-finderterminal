import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var eventMonitor: Any?
    private var hotkey: Hotkey?
    private let session = TerminalSession()
    private let tracker = WindowTracker()
    private lazy var panel = TerminalPanel(terminal: session.view)

    /// Terminal strip is "open" (session docked), even while temporarily hidden
    /// because another app is frontmost.
    private var terminalOpen = false
    /// Total points we shaved off the Finder window (to give back on close);
    /// 0 = quake fallback mode.
    private var shrunkBy: CGFloat = 0
    /// Current terminal thickness (height for top/bottom, width for left/right) —
    /// independent of `shrunkBy` once the user resizes the outer edge.
    private var terminalHeight: CGFloat = 0
    /// Docking side frozen at open time (settings may change while open).
    private var side: DockSide = .bottom
    /// Per-frame follower: polls the Finder frame on every display refresh while
    /// the panel is visible, so dragging never lags behind by more than a frame.
    private var displayLink: CADisplayLink?
    private var lastBodyRect = CGRect.zero
    /// Mouse-riding drag prediction: while the Finder window is being moved, its
    /// motion is the mouse's motion. Anchoring the last AX-known frame to the mouse
    /// lets the panel move in the same event stream as the drag — zero perceived
    /// lag — while AX notifications keep re-anchoring the base (handles edge snap).
    private var dragBase: (finder: CGRect, mouse: CGPoint)?
    private var mouseMonitors: [Any] = []
    private var devRemote: DevRemote?
    private var settingsWindow: NSWindow?
    private var lastSettingsFingerprint = ""

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Brandbook 18.1: force dark mode, override accent, set process name.
        NSApp.appearance = NSAppearance(named: .darkAqua)
        UserDefaults.standard.set(0, forKey: "AppleAccentColor")
        ProcessInfo.processInfo.setValue("Imperator FinderTerminal", forKey: "processName")

        setupStatusItem()
        setupPopover()
        promptAccessibility()

        tracker.onGeometryChange = { [weak self] in
            guard let self else { return }
            // Re-anchor the drag prediction on every AX ground truth. A size change
            // means the window is being resized, not moved — mouse prediction would
            // move the panel the wrong way, so hand over to display-link polling.
            if NSEvent.pressedMouseButtons & 1 != 0, let f = self.tracker.currentFrame() {
                if let base = self.dragBase, base.finder.size != f.size {
                    self.dragBase = nil
                } else {
                    self.dragBase = (f, NSEvent.mouseLocation)
                }
            } else {
                self.dragBase = nil
            }
            self.redock()
        }
        tracker.onFolderChange = { [weak self] in
            guard let self, self.terminalOpen, let path = FinderBridge.frontmostFolder() else { return }
            self.session.cd(to: path)
        }
        tracker.onWindowClosed = { [weak self] in
            guard let self, self.terminalOpen else { return }
            self.terminalOpen = false
            self.shrunkBy = 0                        // window is gone; nothing to restore
            self.stopFollowing()
            self.panel.hide()
            self.tracker.stopObserving()
        }
        session.onDirChangeFromShell = { path in
            FinderBridge.navigate(to: path)
        }

        // Gap splitter: trades space between the Finder window and the terminal, live.
        panel.onResizeDrag = { [weak self] delta in
            guard let self, self.terminalOpen, self.shrunkBy > 0,
                  let f = self.tracker.currentFrame() else { return }
            let finderExtent = self.side.isVertical ? f.width : f.height
            let maxGrow = finderExtent - 300                    // keep Finder usable
            let diff = max(TerminalPanel.minTerminalHeight - self.terminalHeight, min(delta, maxGrow))
            guard abs(diff) > 0.5 else { return }
            self.tracker.adjust(side: self.side, by: -diff)
            self.shrunkBy += diff
            self.terminalHeight += diff
            self.redock()
        }

        // Outer edge resizes like a normal window (Finder untouched).
        panel.onBottomResizeDrag = { [weak self] delta in
            guard let self, self.terminalOpen, self.shrunkBy > 0 else { return }
            self.terminalHeight = max(TerminalPanel.minTerminalHeight, self.terminalHeight + delta)
            self.redock()
        }

        // Live-apply settings changes (theme colors, font size, dock side).
        NotificationCenter.default.addObserver(
            self, selector: #selector(settingsChanged),
            name: UserDefaults.didChangeNotification, object: nil)
        lastSettingsFingerprint = Self.settingsFingerprint()

        // Hide the strip while neither Finder nor this app is frontmost (it must
        // never float above other apps), show it again when Finder returns.
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(frontAppChanged(_:)),
            name: NSWorkspace.didActivateApplicationNotification, object: nil)

        // Mouse-riding drag follow: move the panel inside the drag's own event
        // stream instead of waiting for AX to report the window position.
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDragged]) { [weak self] _ in
            self?.predictDragPosition()
        } { mouseMonitors.append(m) }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] _ in
            guard let self else { return }
            self.dragBase = nil
            self.redock()                            // settle on AX ground truth
        } { mouseMonitors.append(m) }

        hotkey = Hotkey { [weak self] in self?.toggleTerminal() }

        devRemote = DevRemote(
            onToggle: { [weak self] in self?.toggleTerminal() },
            onSnapshot: { [weak self] path in self?.devSnapshot(to: path) }
        )

        // Pre-spawn the shell so the first toggle shows a ready prompt instead of
        // paying zsh login/rc startup time. The first open cd:s it to the right folder.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.session.startIfNeeded(dir: NSHomeDirectory())
        }
    }

    /// Write the panel's rendered content + geometry state for headless verification.
    private func devSnapshot(to path: String) {
        var meta: [String: Any] = [
            "terminalOpen": terminalOpen,
            "shrunkBy": shrunkBy,
            "panelFrame": NSStringFromRect(panel.frame),
            "panelVisible": panel.isShown,
            "chromeColor": panel.debugChromeColor,
        ]
        if let f = tracker.currentFrame() { meta["finderFrame"] = NSStringFromRect(f) }
        if let data = try? JSONSerialization.data(withJSONObject: meta, options: [.sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: path + ".json"))
        }
        guard let v = panel.contentView,
              let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
        v.cacheDisplay(in: v.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?
            .write(to: URL(fileURLWithPath: path + ".png"))
    }

    func applicationWillTerminate(_ notification: Notification) {
        if terminalOpen, shrunkBy > 0 { tracker.adjust(side: side, by: shrunkBy) }
    }

    /// How much space the shrink actually freed on the docking side.
    private func freedSpace(pre f: CGRect, post f2: CGRect) -> CGFloat {
        switch side {
        case .bottom: f2.minY - f.minY
        case .top: f.maxY - f2.maxY
        case .left: f2.minX - f.minX
        case .right: f.maxX - f2.maxX
        }
    }

    /// The terminal body rect for the current Finder frame: glued `gap` points
    /// off the docking edge, `terminalHeight` thick, matching Finder's other axis.
    private func bodyRect(finder f: CGRect) -> CGRect {
        let g = TerminalPanel.gap
        let t = terminalHeight
        return switch side {
        case .bottom: CGRect(x: f.minX, y: f.minY - g - t, width: f.width, height: t)
        case .top: CGRect(x: f.minX, y: f.maxY + g, width: f.width, height: t)
        case .left: CGRect(x: f.minX - g - t, y: f.minY, width: t, height: f.height)
        case .right: CGRect(x: f.maxX + g, y: f.minY, width: t, height: f.height)
        }
    }

    @objc private func toggleTerminal() {
        if terminalOpen {
            if panel.isShown {
                closeTerminal()
            } else if shrunkBy > 0 {
                // Docked but hidden (another app was frontmost): bring it back.
                panel.orderFrontRegardless()
                NSApp.activate(ignoringOtherApps: true)
                panel.makeKey()
                redock()
            } else {
                // Open but never properly docked — retry the full docking flow.
                openDockedOrFallback()
            }
            return
        }

        let folder = FinderBridge.frontmostFolder() ?? NSHomeDirectory()
        session.startIfNeeded(dir: folder)
        session.cd(to: folder)                       // no-op on first spawn (already in folder)
        panel.applyTheme(session.applyTheme())       // re-read theme on every open

        side = AppSettings.position
        panel.side = side
        terminalOpen = true
        openDockedOrFallback()
    }

    private func openDockedOrFallback() {
        guard WindowTracker.isTrusted else {
            shrunkBy = 0
            panel.show(at: TerminalPanel.quakeFrame())
            return
        }
        if dockToCurrentWindow() { return }

        // No usable Finder window — the terminal must never float alone.
        // Open a fresh one and dock once AX can see it.
        FinderBridge.openNewWindow()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self, self.terminalOpen, self.shrunkBy == 0 else { return }
            if !self.dockToCurrentWindow() {
                self.panel.show(at: TerminalPanel.quakeFrame())
            }
            if let path = FinderBridge.frontmostFolder() { self.session.cd(to: path) }
        }
    }

    /// Attach to the frontmost Finder window, shrink it, and show the terminal
    /// in the freed space. Returns false if there is no usable window.
    private func dockToCurrentWindow() -> Bool {
        let extent = { (f: CGRect) in self.side.isVertical ? f.width : f.height }
        guard let f = tracker.attachToFrontWindow(), extent(f) > 400 else { return false }
        let wanted = min(TerminalPanel.defaultHeight + TerminalPanel.gap,
                         (extent(f) * 0.45).rounded())
        tracker.adjust(side: side, by: -wanted)
        // Verify what actually happened — AX resizes can silently clamp or fail
        // (was the cause of the panel covering Finder content).
        let freed = (tracker.currentFrame().map { freedSpace(pre: f, post: $0) }) ?? 0
        if freed >= TerminalPanel.minTerminalHeight + TerminalPanel.gap {
            shrunkBy = freed
            terminalHeight = freed - TerminalPanel.gap
            redockOrShow(show: true)
            tracker.startObserving()
            return true
        }
        if freed > 0 { tracker.adjust(side: side, by: freed) }   // undo partial shrink
        return false
    }

    private func closeTerminal() {
        terminalOpen = false
        stopFollowing()
        panel.hide()
        tracker.stopObserving()
        if shrunkBy > 0 {
            tracker.adjust(side: side, by: shrunkBy) // give the space back to Finder
            shrunkBy = 0
        }
    }

    private func redock() {
        redockOrShow(show: false)
    }

    private func redockOrShow(show: Bool) {
        guard terminalOpen || show, shrunkBy > 0, let f = tracker.currentFrame() else { return }
        let rect = bodyRect(finder: f)
        guard rect != lastBodyRect || show else { return }   // skip no-op frame updates
        lastBodyRect = rect
        if show {
            panel.show(at: rect)
            startFollowing()
        } else {
            panel.reDock(at: rect)
        }
    }

    /// AX move/resize notifications arrive in coarse bursts while dragging, which
    /// makes notification-driven docking lag. Instead, poll the Finder frame on
    /// every display refresh while the panel is visible — reDock is skipped when
    /// nothing moved, so the steady-state cost is one AX read per frame.
    private func startFollowing() {
        guard displayLink == nil, let view = panel.contentView else { return }
        let link = view.displayLink(target: self, selector: #selector(followTick))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopFollowing() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func followTick() {
        // While mouse prediction is active it owns the panel position; AX polling
        // here would push stale frames and fight the fresher mouse data.
        guard terminalOpen, panel.isShown, dragBase == nil else { return }
        redock()
    }

    /// Place the panel from the live mouse position during a window drag.
    private func predictDragPosition() {
        guard terminalOpen, shrunkBy > 0, let base = dragBase else { return }
        let mouse = NSEvent.mouseLocation
        let predicted = base.finder.offsetBy(dx: mouse.x - base.mouse.x,
                                             dy: mouse.y - base.mouse.y)
        let rect = bodyRect(finder: predicted)
        guard rect != lastBodyRect else { return }
        lastBodyRect = rect
        panel.reDock(at: rect)
    }

    @objc private func frontAppChanged(_ note: Notification) {
        guard terminalOpen else { return }
        let bid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
        if bid == "com.apple.finder" || bid == Bundle.main.bundleIdentifier {
            panel.orderFrontRegardless()
            redock()
        } else {
            panel.orderOut(nil)
        }
    }

    private func promptAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    // MARK: Settings

    private static func settingsFingerprint() -> String {
        let d = UserDefaults.standard
        return [AppSettings.themeKey, AppSettings.positionKey, AppSettings.customBackgroundKey,
                AppSettings.customTextKey, AppSettings.customCursorKey,
                AppSettings.customSelectionKey, AppSettings.fontSizeKey]
            .map { d.string(forKey: $0) ?? String(d.double(forKey: $0)) }
            .joined(separator: "|")
    }

    @objc private func settingsChanged() {
        let fp = Self.settingsFingerprint()
        guard fp != lastSettingsFingerprint else { return }
        lastSettingsFingerprint = fp
        panel.applyTheme(session.applyTheme())
        if terminalOpen, AppSettings.position != side {
            // Re-dock on the newly chosen side.
            closeTerminal()
            toggleTerminal()
        }
    }

    // Real settings window, same pattern as Imperator Dock Folders' main window.
    func showSettings() {
        if let w = settingsWindow, w.isVisible {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let win = settingsWindow ?? {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 640),
                             styleMask: [.titled, .closable, .resizable, .miniaturizable],
                             backing: .buffered, defer: false)
            w.isReleasedWhenClosed = false
            // Just above the floating terminal panel — settings must never end up behind it.
            w.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
            return w
        }()
        win.contentView = NSHostingView(rootView: SettingsView())
        win.title = "Imperator FinderTerminal Settings"
        win.setFrameAutosaveName("SettingsWindow")
        if settingsWindow == nil { win.center() }
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow = win
    }

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
            panel.center()
            aboutPanel = panel
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
}
