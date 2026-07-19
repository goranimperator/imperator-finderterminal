import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var hotkey: Hotkey?
    private let session = TerminalSession()
    private let tracker = WindowTracker()
    private lazy var panel = TerminalPanel(terminal: session.view)

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        promptAccessibility()

        tracker.onGeometryChange = { [weak self] in
            guard let self else { return }
            self.panel.reDock(to: self.tracker.frontmostFrame())
        }
        tracker.onFolderChange = { [weak self] in
            guard let self, self.panel.isShown, let path = FinderBridge.frontmostFolder() else { return }
            self.session.cd(to: path)
        }
        session.onDirChangeFromShell = { path in
            FinderBridge.navigate(to: path)
        }

        hotkey = Hotkey { [weak self] in self?.toggle() }
    }

    @objc private func toggle() {
        if panel.isShown {
            panel.hide()
            tracker.stopObserving()
            return
        }
        let folder = FinderBridge.frontmostFolder() ?? NSHomeDirectory()
        session.startIfNeeded(dir: folder)
        session.cd(to: folder)                       // no-op on first spawn (already in folder)
        panel.show(dockedTo: tracker.frontmostFrame())
        tracker.startObserving()
    }

    private func promptAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "apple.terminal", accessibilityDescription: "Imperator FinderTerminal")
            ?? NSImage(systemSymbolName: "terminal", accessibilityDescription: "Imperator FinderTerminal")
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Toggle Terminal (⌃`)", action: #selector(toggle), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        menu.items.forEach { $0.target = self }
        menu.items.last?.target = nil   // Quit -> default responder chain
        item.menu = menu
        statusItem = item
    }
}
