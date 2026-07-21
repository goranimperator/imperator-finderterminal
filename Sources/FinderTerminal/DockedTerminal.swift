import AppKit
import SwiftUI

/// One terminal docked to one Finder window: owns its shell session, panel,
/// AX tracker and all geometry state. AppDelegate holds one of these per
/// Finder window and fans global events (mouse, app activation) out to them.
final class DockedTerminal {
    let windowID: CGWindowID
    let session: TerminalSession
    let panel: TerminalPanel
    private let tracker = WindowTracker()

    private(set) var shrunkBy: CGFloat = 0
    private var terminalHeight: CGFloat = 0
    private let side: DockSide
    private var lastBodyRect = CGRect.zero
    private var displayLink: CADisplayLink?
    private var dragBase: (finder: CGRect, mouse: CGPoint)?
    /// Snapshot taken at mouseDown, before anything moves — the only moment
    /// the window frame and mouse position pair exactly.
    private var pendingDragAnchor: (finder: CGRect, mouse: CGPoint)?
    /// Set while the Cmd-W flow already handled termination — suppresses the
    /// post-close alert when the AX destroyed notification arrives.
    private var suppressCloseAlert = false

    /// Called when this terminal is done (window closed + resolved, or terminated).
    var onFinished: ((DockedTerminal) -> Void)?
    /// Cancel path of the post-close alert: give this session a new window.
    var onWantsNewWindow: ((TerminalSession) -> Void)?

    /// Docks to the frontmost Finder window. Fails (nil) if there is no usable
    /// window or the AX shrink freed nothing.
    init?(session: TerminalSession, side: DockSide) {
        self.session = session
        self.side = side
        self.panel = TerminalPanel(terminal: session.view)
        panel.side = side

        let extent = { (f: CGRect) in side.isVertical ? f.width : f.height }
        guard WindowTracker.isTrusted, var f = tracker.attachToFrontWindow() else { return nil }
        // Resolve the CGWindowID BEFORE resizing: CGWindowList bounds lag behind
        // AX writes, so a post-shrink lookup mismatches and fails.
        guard let id = tracker.windowNumber() else { return nil }

        // A small window is still the user's window — grow it toward the dock
        // side to make room rather than giving up. The remainder after shrinking
        // must stay above Finder's own minimum window size (~300).
        let needed = TerminalPanel.minTerminalHeight + TerminalPanel.gap + 320
        if extent(f) < needed {
            tracker.adjust(side: side, by: needed - extent(f))
            let f2 = tracker.settledFrame(after: f) ?? f
            if extent(f2) < needed - 2 {
                // Screen edge blocked the growth — undo; caller opens a new window.
                tracker.adjust(side: side, by: extent(f) - extent(f2))
                return nil
            }
            f = f2
        }

        let wanted = min(TerminalPanel.defaultHeight + TerminalPanel.gap,
                         (extent(f) * 0.45).rounded())
        tracker.adjust(side: side, by: -wanted)
        // Verify what actually happened — AX resizes can silently clamp or fail.
        let freed = (tracker.settledFrame(after: f).map { Self.freedSpace(side: side, pre: f, post: $0) }) ?? 0
        guard freed >= TerminalPanel.minTerminalHeight + TerminalPanel.gap else {
            if freed > 0 { tracker.adjust(side: side, by: freed) }
            return nil
        }

        windowID = id
        shrunkBy = freed
        terminalHeight = freed - TerminalPanel.gap

        panel.applyTheme(session.applyTheme())
        let folder = FinderBridge.frontmostFolder() ?? NSHomeDirectory()
        session.startIfNeeded(dir: folder)
        session.cd(to: folder)

        wireCallbacks()
        if let frame = tracker.currentFrame() {
            panel.show(at: bodyRect(finder: frame))
            lastBodyRect = bodyRect(finder: frame)
        }
        tracker.startObserving()
        reassertOrder()
        startFollowing()
    }

    private func wireCallbacks() {
        tracker.onGeometryChange = { [weak self] in
            guard let self else { return }
            if NSEvent.pressedMouseButtons & 1 != 0, let f = self.tracker.currentFrame() {
                if let base = self.dragBase {
                    // Size change = a resize, not a move: prediction would
                    // misplace the panel — fall back to display-link polling.
                    if base.finder.size != f.size { self.dragBase = nil }
                } else {
                    // A drag is confirmed (the window actually moved). Anchor
                    // on the exact mouseDown pairing when we have it; the AX
                    // frame here is a frame stale against the fresh mouse and
                    // would bake in a constant offset.
                    self.dragBase = self.pendingDragAnchor ?? (f, NSEvent.mouseLocation)
                }
            } else {
                self.dragBase = nil
            }
            self.redock()
            self.reassertOrder()
        }
        tracker.onFolderChange = { [weak self] in
            guard let self, let path = FinderBridge.frontmostFolder() else { return }
            self.session.cd(to: path)
        }
        tracker.onWindowClosed = { [weak self] in
            self?.windowWasClosed()
        }
        // cd in this shell steers Finder's front window (the common case: the
        // user is typing in the terminal whose window is active).
        session.onDirChangeFromShell = { path in
            FinderBridge.navigate(to: path)
        }
        panel.onResizeDrag = { [weak self] delta in
            guard let self, self.shrunkBy > 0, let f = self.tracker.currentFrame() else { return }
            let finderExtent = self.side.isVertical ? f.width : f.height
            let maxGrow = finderExtent - 300
            let diff = max(TerminalPanel.minTerminalHeight - self.terminalHeight, min(delta, maxGrow))
            guard abs(diff) > 0.5 else { return }
            self.tracker.adjust(side: self.side, by: -diff)
            self.shrunkBy += diff
            self.terminalHeight += diff
            self.redock()
        }
        panel.onBottomResizeDrag = { [weak self] delta in
            guard let self, self.shrunkBy > 0 else { return }
            self.terminalHeight = max(TerminalPanel.minTerminalHeight, self.terminalHeight + delta)
            self.redock()
        }
    }

    // MARK: Geometry

    private static func freedSpace(side: DockSide, pre f: CGRect, post f2: CGRect) -> CGFloat {
        switch side {
        case .bottom: f2.minY - f.minY
        case .top: f.maxY - f2.maxY
        case .left: f2.minX - f.minX
        case .right: f.maxX - f2.maxX
        }
    }

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

    func redock() {
        guard shrunkBy > 0, let f = tracker.currentFrame() else { return }
        let rect = bodyRect(finder: f)
        guard rect != lastBodyRect else { return }
        lastBodyRect = rect
        panel.reDock(at: rect)
    }

    /// Slot the panel directly above its Finder window in the global z-order.
    func reassertOrder() {
        guard panel.isVisible, let num = tracker.windowNumber() else { return }
        panel.order(.above, relativeTo: Int(num))
    }

    /// mouseDown snapshot (fed from the global mouseDown monitor). Prediction
    /// activates on the first geometry notification — which only arrives when
    /// the window really moves, so inner drags (text selection, file
    /// marquee) never drive the panel.
    func armDrag() {
        guard shrunkBy > 0, let f = tracker.currentFrame(),
              f.contains(NSEvent.mouseLocation) else {
            pendingDragAnchor = nil
            return
        }
        pendingDragAnchor = (f, NSEvent.mouseLocation)
    }

    /// Mouse-riding drag prediction (fed from the global drag monitor).
    func predictDragPosition() {
        guard shrunkBy > 0, let base = dragBase else { return }
        let mouse = NSEvent.mouseLocation
        let predicted = base.finder.offsetBy(dx: mouse.x - base.mouse.x,
                                             dy: mouse.y - base.mouse.y)
        let rect = bodyRect(finder: predicted)
        guard rect != lastBodyRect else { return }
        lastBodyRect = rect
        panel.reDock(at: rect)
    }

    func settleDrag() {
        dragBase = nil
        pendingDragAnchor = nil
        redock()
        reassertOrder()
    }

    private func startFollowing() {
        guard displayLink == nil, let view = panel.contentView else { return }
        let link = view.displayLink(target: self, selector: #selector(followTick))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    @objc private func followTick() {
        guard panel.isShown, dragBase == nil else { return }
        redock()
    }

    // MARK: Closing

    /// Toggle-off entry point: ask first if something is running (the hotkey
    /// must not silently kill a busy process), then close.
    func requestClose() {
        guard isBusy else { close(); return }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        presentTerminateAlert { [weak self] response in
            if response == .alertFirstButtonReturn { self?.close() }
        }
    }

    /// Hide, give the space back, end this controller.
    private func close() {
        teardown()
        panel.hide()
        if shrunkBy > 0 {
            tracker.adjust(side: side, by: shrunkBy)
            shrunkBy = 0
        }
        session.terminate()
        onFinished?(self)
    }

    /// App quitting: restore Finder geometry only.
    func restoreOnQuit() {
        if shrunkBy > 0 { tracker.adjust(side: side, by: shrunkBy) }
    }

    func applyTheme() {
        panel.applyTheme(session.applyTheme())
    }

    /// True when something beyond the idle shell is running here.
    var isBusy: Bool { !session.runningProcessNames().isEmpty }

    /// Cmd-W flow already resolved this terminal (terminated or kept):
    /// the upcoming AX destroyed notification must not alert again.
    func markResolvedBeforeClose() {
        suppressCloseAlert = true
    }

    /// Close our Finder window via AX (used by the Cmd-W Terminate path).
    func closeFinderWindow() {
        tracker.pressCloseButton()
    }

    private func teardown() {
        displayLink?.invalidate()
        displayLink = nil
        tracker.stopObserving()
    }

    /// The Finder window disappeared (red button, or Cmd-W we let through).
    private func windowWasClosed() {
        shrunkBy = 0
        teardown()

        if suppressCloseAlert {
            panel.hide()
            onFinished?(self)
            return
        }

        // Warn per the ALERTS setting; Cancel re-docks the session to a new window.
        if !AppSettings.alertAlways && !isBusy {
            panel.hide()
            session.terminate()
            onFinished?(self)
            return
        }
        presentTerminateAlert { [weak self] response in
            guard let self else { return }
            switch response {
            case .alertFirstButtonReturn:
                self.session.terminate()
                self.panel.hide()
                self.onFinished?(self)
            case .alertSecondButtonReturn:
                // Cancel: keep the session alive, re-dock it to a new window.
                self.panel.hide()
                let session = self.session
                self.onFinished?(self)
                self.onWantsNewWindow?(session)
            default:
                break   // superseded (.stop) — a newer alert owns the decision
            }
        }
    }

    /// Cmd-W was intercepted BEFORE the window closed: ask first — always, or
    /// only while a process runs, per the ALERTS setting.
    func confirmCloseFromKeyboard() {
        if !AppSettings.alertAlways && !isBusy {
            markResolvedBeforeClose()
            session.terminate()
            panel.hide()
            closeFinderWindow()
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        presentTerminateAlert { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }   // Cancel: window stays open
            self.markResolvedBeforeClose()
            self.session.terminate()
            self.panel.hide()
            self.closeFinderWindow()
        }
    }

    private func presentTerminateAlert(completion: @escaping (NSApplication.ModalResponse) -> Void) {
        // A newer question supersedes an older one (e.g. red close button while
        // the toggle-off alert is up): abort it — .stop matches no button, so
        // its completion is a no-op — instead of queueing a second sheet.
        if let sheet = panel.attachedSheet { panel.endSheet(sheet, returnCode: .stop) }
        let alert = NSAlert()
        alert.messageText = "Do you want to terminate running FinderTerminal?"
        alert.addButton(withTitle: "Terminate")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        alert.beginSheetModal(for: panel, completionHandler: completion)
    }
}
