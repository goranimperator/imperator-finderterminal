import AppKit

/// Borderless overlay that docks over the frontmost Finder window (quake-style),
/// or drops from the top of the screen when no Finder window is open.
final class TerminalPanel: NSPanel {
    private let terminal: NSView
    private static let panelHeight: CGFloat = 300

    init(terminal: NSView) {
        self.terminal = terminal
        super.init(contentRect: NSRect(x: 0, y: 0, width: 600, height: Self.panelHeight),
                   styleMask: [.borderless],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hasShadow = true
        backgroundColor = .clear
        terminal.autoresizingMask = [.width, .height]
        contentView?.addSubview(terminal)
        terminal.frame = contentView?.bounds ?? .zero
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    var isShown: Bool { isVisible && alphaValue > 0.01 }

    func show(dockedTo finderFrame: CGRect?) {
        let target = Self.dockFrame(finderFrame)
        setFrame(target.offsetBy(dx: 0, dy: -24), display: false)
        alphaValue = 0
        makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        makeFirstResponder(terminal)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            animator().setFrame(target, display: true)
            animator().alphaValue = 1
        }
    }

    func hide() {
        let out = frame.offsetBy(dx: 0, dy: -24)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            animator().setFrame(out, display: true)
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.orderOut(nil)
        })
    }

    /// Follow the Finder window while already visible (no animation).
    func reDock(to finderFrame: CGRect?) {
        guard isShown else { return }
        setFrame(Self.dockFrame(finderFrame), display: true)
    }

    private static func dockFrame(_ finder: CGRect?) -> CGRect {
        if let f = finder, f.width > 200, f.height > 120 {
            let h = min(panelHeight, f.height - 44)
            return CGRect(x: f.minX, y: f.minY, width: f.width, height: h)
        }
        let screen = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1200, height: 800)
        return CGRect(x: screen.minX, y: screen.maxY - panelHeight, width: screen.width, height: panelHeight)
    }
}
