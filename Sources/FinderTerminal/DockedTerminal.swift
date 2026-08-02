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
    private var side: DockSide
    private var lastBodyRect = CGRect.zero
    private var displayLink: CADisplayLink?
    private var dragBase: (finder: CGRect, mouse: CGPoint)?
    /// Snapshot taken at mouseDown, before anything moves — the only moment
    /// the window frame and mouse position pair exactly.
    private var pendingDragAnchor: (finder: CGRect, mouse: CGPoint)?
    /// A poll for the new fullscreen space is in flight.
    private var adoptingFullScreen = false
    /// The user is dragging the splitter (or the outer edge) right now.
    private var splitterDragging = false
    /// When the last AX geometry notification arrived — gates the follow poll.
    private var lastGeometryEvent = Date.distantPast
    /// Drag deltas waiting for the next display tick.
    private var pendingSplitter: CGFloat = 0
    private var pendingOuter: CGFloat = 0
    /// Dock geometry from before the window went fullscreen: the frame macOS
    /// restores on the way out still has this shrink applied.
    private var preFullScreenShrink: CGFloat = 0
    private var preFullScreenHeight: CGFloat = 0
    /// Fullscreen space we reserved a strip in. A fullscreen space drops every
    /// AX resize, so room is freed by insetting the space's layout instead —
    /// the window stays in its real fullscreen space, just smaller.
    private var reservedSpace: UInt64?
    /// Set while the Cmd-W flow already handled termination — suppresses the
    /// post-close alert when the AX destroyed notification arrives.
    private var suppressCloseAlert = false

    /// Called when this terminal is done (window closed + resolved, or terminated).
    var onFinished: ((DockedTerminal) -> Void)?
    /// Cancel path of the post-close alert: give this session a new window, on
    /// the folder it was showing.
    var onWantsNewWindow: ((TerminalSession, String?) -> Void)?

    /// Docks to the frontmost Finder window. Fails (nil) if there is no usable
    /// window or no room could be freed.
    init?(session: TerminalSession, side: DockSide) {
        self.session = session
        self.side = side
        self.panel = TerminalPanel(terminal: session.view)
        panel.side = side

        guard WindowTracker.isTrusted, let f0 = tracker.attachToFrontWindow() else { return nil }
        // Resolve the CGWindowID BEFORE resizing: CGWindowList bounds lag behind
        // AX writes, so a post-shrink lookup mismatches and fails.
        guard let id = tracker.windowNumber() else { return nil }
        windowID = id

        if let space = SpaceReservation.fullScreenSpace(of: id) {
            guard reserveStrip(TerminalPanel.defaultHeight, in: space, from: f0) else { return nil }
        } else {
            guard let freed = Self.makeRoom(tracker: tracker, side: side, from: f0) else { return nil }
            shrunkBy = freed
            terminalHeight = (freed - TerminalPanel.gap).rounded()
        }
        panel.setOverlay(reservedSpace != nil)

        panel.applyTheme(session.applyTheme())
        let folder = FinderBridge.frontmostFolder() ?? NSHomeDirectory()
        session.startIfNeeded(dir: folder)
        session.cd(to: folder)

        wireCallbacks()
        if let frame = tracker.currentFrame() {
            panel.show(at: bodyRect(finder: frame), takeFocus: AppSettings.focusTerminalOnOpen)
            lastBodyRect = bodyRect(finder: frame)
        }
        tracker.startObserving()
        reassertOrder()
        startFollowing()
    }

    private func wireCallbacks() {
        tracker.onGeometryChange = { [weak self] in
            guard let self else { return }
            self.lastGeometryEvent = Date()
            self.wake()
            // Fullscreen transitions arrive as resizes.
            if self.tracker.isFullScreen {
                self.adoptFullScreenSpace()
            } else if self.reservedSpace != nil {
                self.leftFullScreenSpace()
            }
            // A splitter drag moves the window through us, not the other way
            // round: prediction there would fight our own resize.
            if self.splitterDragging {
                self.dragBase = nil
            } else if NSEvent.pressedMouseButtons & 1 != 0, let f = self.tracker.currentFrame() {
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
            // reassertOrder enumerates every on-screen window; doing that per
            // notification during a drag is the expensive part. The mouse-up
            // handler re-asserts once the drag ends.
            if NSEvent.pressedMouseButtons & 1 == 0 { self.reassertOrder() }
        }
        tracker.onFolderChange = { [weak self] in
            guard let self, let path = FinderBridge.frontmostFolder() else { return }
            self.session.cd(to: path)
        }
        tracker.onWindowClosed = { [weak self] in
            self?.windowWasClosed()
        }
        tracker.onVisibilityChange = { [weak self] in
            self?.updatePanelVisibility()
        }
        // Clicking the panel raises only the panel; bring its window along.
        NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: panel, queue: .main
        ) { [weak self] _ in
            self?.raiseWithWindow()
        }
        // cd in this shell steers Finder's front window (the common case: the
        // user is typing in the terminal whose window is active).
        session.onDirChangeFromShell = { path in
            FinderBridge.navigate(to: path)
        }
        // Drags only accumulate here; the display tick applies them. A resize per
        // mouse event means an AX (or space) write per event, which Finder cannot
        // keep up with — the deltas pile into visible lag.
        panel.onResizeDrag = { [weak self] delta in
            guard let self, self.shrunkBy > 0 else { return }
            self.splitterDragging = true
            self.pendingSplitter += delta
            self.wake()
        }
        panel.onBottomResizeDrag = { [weak self] delta in
            guard let self, self.shrunkBy > 0 else { return }
            self.splitterDragging = true
            self.pendingOuter += delta
            self.wake()
        }
    }

    /// Splitter edge: trade extent with the Finder window (or with the reserved
    /// strip when it is fullscreen).
    private func applySplitter(_ delta: CGFloat) {
        guard shrunkBy > 0, let f = tracker.currentFrame() else { return }
        let finderExtent = side.isVertical ? f.width : f.height
        let clamped = max(TerminalPanel.minTerminalHeight - terminalHeight,
                          min(delta, finderExtent - 300))
        // Whole points only: fractional geometry leaves a blurred seam between
        // the two windows (and collapses a fullscreen space outright). Carry the
        // sub-point remainder to the next tick so slow drags still track.
        let step = (terminalHeight + clamped).rounded() - terminalHeight
        guard abs(step) >= 1 else { pendingSplitter += clamped; return }
        if let space = reservedSpace {
            reserveStrip(terminalHeight + step, in: space, from: f, live: true)
        } else {
            tracker.adjust(side: side, by: -step)
            shrunkBy += step
            terminalHeight += step
            redock()
        }
    }

    /// Outer edge: the terminal's own size. In a fullscreen space that edge is
    /// the screen edge, so the strip has to change instead (mirrored).
    private func applyOuter(_ delta: CGFloat) {
        guard shrunkBy > 0 else { return }
        if let space = reservedSpace, let f = tracker.currentFrame() {
            let wanted = max(TerminalPanel.minTerminalHeight, terminalHeight - delta).rounded()
            guard abs(wanted - terminalHeight) >= 1 else { pendingOuter += delta; return }
            reserveStrip(wanted, in: space, from: f, live: true)
            return
        }
        let wanted = max(TerminalPanel.minTerminalHeight, terminalHeight + delta).rounded()
        guard abs(wanted - terminalHeight) >= 1 else { pendingOuter += delta; return }
        terminalHeight = wanted
        redock()
    }

    /// Apply whatever the drag accumulated since the last tick.
    private func flushPendingDrag() -> Bool {
        guard pendingSplitter != 0 || pendingOuter != 0 else { return false }
        let splitter = pendingSplitter, outer = pendingOuter
        pendingSplitter = 0
        pendingOuter = 0
        if splitter != 0 { applySplitter(splitter) }
        if outer != 0 { applyOuter(outer) }
        return true
    }

    /// Inset the fullscreen space's layout by `height` + gap, so its window is
    /// laid out short of the docked edge and the terminal fits in the strip.
    /// `live` = called from a drag: no frame-settle poll and no logging, both of
    /// which would stall the main thread on every mouse event.
    @discardableResult
    private func reserveStrip(_ height: CGFloat, in space: UInt64, from f: CGRect,
                              live: Bool = false) -> Bool {
        // Whole points only: a fractional reservation makes the window server
        // tear the fullscreen space down (measured — trackpad deltas are
        // fractional, which is why only real drags hit it).
        let strip = (height + TerminalPanel.gap).rounded()
        guard SpaceReservation.reserve(strip, side: side, space: space) else {
            devLog("reserveStrip: space \(space) refused \(strip)pt")
            return false
        }
        reservedSpace = space
        terminalHeight = strip - TerminalPanel.gap
        shrunkBy = strip
        if !live {
            let got = tracker.settledFrame(after: f) ?? f
            devLog("reserveStrip: \(strip)pt in space \(space) -> window \(NSStringFromRect(got))")
        }
        lastBodyRect = .zero
        redock()
        return true
    }

    /// The user pushed the window into a fullscreen space while docked: reserve a
    /// strip in the new space instead of the AX shrink. The space does not exist
    /// yet when the resize notification lands, so poll for it.
    private func adoptFullScreenSpace(attemptsLeft: Int = 8) {
        guard reservedSpace == nil, !adoptingFullScreen || attemptsLeft < 8 else { return }
        guard let space = SpaceReservation.fullScreenSpace(of: windowID) else {
            guard attemptsLeft > 0, tracker.isFullScreen else {
                adoptingFullScreen = false
                if attemptsLeft <= 0 { devLog("fullscreen space never appeared for \(windowID)") }
                return
            }
            adoptingFullScreen = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.adoptFullScreenSpace(attemptsLeft: attemptsLeft - 1)
            }
            return
        }
        adoptingFullScreen = false
        // macOS restores the pre-fullscreen frame later, and that frame still
        // carries our shrink — remember it so leaving fullscreen doesn't shrink
        // the window a second time.
        preFullScreenShrink = shrunkBy
        preFullScreenHeight = terminalHeight
        shrunkBy = 0
        guard let f = tracker.currentFrame() else { return }
        devLog("window went fullscreen -> reserving strip in space \(space)")
        panel.setOverlay(true)
        // A whole screen of room: never carry over a height the old small window
        // forced on us.
        _ = reserveStrip(max(terminalHeight, TerminalPanel.defaultHeight), in: space, from: f)
        settlePanelAcrossTransition()   // the panel has to join the fullscreen space
        startFollowing()                // display links pause while off-space
    }

    /// The window left its fullscreen space: the reservation died with it, so
    /// free room the normal way — unless the restored frame already carries the
    /// shrink from before it went fullscreen.
    private func leftFullScreenSpace() {
        devLog("leftFullScreenSpace: splitterDragging=\(splitterDragging) height=\(terminalHeight)")
        reservedSpace = nil
        panel.setOverlay(false)
        if preFullScreenShrink > 0 {
            shrunkBy = preFullScreenShrink
            terminalHeight = preFullScreenHeight
            devLog("window left fullscreen -> resuming previous dock (\(shrunkBy))")
        } else if let f = tracker.currentFrame(),
                  let freed = Self.makeRoom(tracker: tracker, side: side, from: f) {
            shrunkBy = freed
            terminalHeight = (freed - TerminalPanel.gap).rounded()
            devLog("window left fullscreen -> docked (freed \(freed))")
        } else {
            shrunkBy = 0
            devLog("window left fullscreen -> could not free room")
            return
        }
        preFullScreenShrink = 0
        lastBodyRect = .zero
        redock()
        settlePanelAcrossTransition()   // back in a normal space: the panel must return
        startFollowing()
    }

    // MARK: Geometry

    /// Shrink the Finder window along `side` to free space for the terminal.
    /// Returns the space actually freed, or nil when the window won't give it up.
    private static func makeRoom(tracker: WindowTracker, side: DockSide, from f0: CGRect) -> CGFloat? {
        let extent = { (f: CGRect) in side.isVertical ? f.width : f.height }
        var f = f0

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
        let freed = (tracker.settledFrame(after: f).map { freedSpace(side: side, pre: f, post: $0) }) ?? 0
        guard freed >= TerminalPanel.minTerminalHeight + TerminalPanel.gap else {
            if freed > 0 { tracker.adjust(side: side, by: freed) }
            return nil
        }
        return freed
    }

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

    /// The terminal was clicked or our app came forward. macOS raises only the
    /// window that was hit, so the Finder window has to be raised too — they are
    /// one unit visually but two separate windows to the window server (there is
    /// no cross-app grouping: SLSSetWindowParent accepts the call and no-ops).
    func raiseWithWindow() {
        guard shrunkBy > 0, panel.isShown, !tracker.isMinimized else { return }
        // An AX raise lifts the window as high as it goes without activating
        // Finder: just under the active app's windows. We are the active app
        // here, so that lands it directly beneath the panel — no z-order pinning
        // needed, and pinning would in fact drag the panel back down to whatever
        // level Finder happened to sit at.
        tracker.raise()
        panel.orderFrontRegardless()
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
        wake()
    }

    /// The active space changed.
    func spaceChanged() { updatePanelVisibility() }

    /// The terminal is only on screen when its Finder window is: not minimised,
    /// and on the space we are looking at.
    func updatePanelVisibility() {
        guard !tracker.isMinimized, Self.isOnActiveSpace(windowID) else {
            if panel.isVisible { panel.orderOut(nil) }
            return
        }
        if !panel.isVisible || panel.alphaValue < 0.99 { panel.fadeIn() }
        lastBodyRect = .zero            // re-place from scratch after a switch
        wake()
        redock()
        reassertOrder()
    }

    /// A space transition takes ~1s, and the window is missing from the on-screen
    /// list while it runs — one `spaceChanged()` mid-flight would leave the panel
    /// hidden, so settle it over the whole transition.
    private func settlePanelAcrossTransition() {
        for delay in [0.3, 0.9, 1.6] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.spaceChanged()
            }
        }
    }

    /// Windows on other spaces are absent from the on-screen window list.
    private static func isOnActiveSpace(_ id: CGWindowID) -> Bool {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
                as? [[String: Any]] else { return true }
        return list.contains { ($0[kCGWindowNumber as String] as? CGWindowID) == id }
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
        if splitterDragging {
            splitterDragging = false
            _ = flushPendingDrag()          // whatever the last tick missed
            if let space = reservedSpace, let f = tracker.currentFrame() {
                // Re-assert the final strip and let the frame settle now that the
                // per-event work is over.
                reserveStrip(terminalHeight, in: space, from: f)
            }
        }
        redock()
        reassertOrder()
    }

    private func startFollowing() {
        // A display link pauses when its view's window leaves the active space
        // and does not always resume — rebuild it after a space round trip.
        displayLink?.invalidate()
        displayLink = nil
        guard let view = panel.contentView else { return }
        let link = view.displayLink(target: self, selector: #selector(followTick))
        link.add(to: .main, forMode: .common)
        link.isPaused = true
        displayLink = link
    }

    @objc private func followTick() {
        guard panel.isShown else { displayLink?.isPaused = true; return }
        // Self-heal: a mouse-up we never saw (space switch, lost event) must not
        // leave the drag flag set — that would kill the follow prediction.
        if splitterDragging, NSEvent.pressedMouseButtons & 1 == 0 { splitterDragging = false }
        if flushPendingDrag() { return }
        guard dragBase == nil else { return }
        // Each poll costs two AX round trips into Finder. Idle windows are the
        // normal case, so stop the link entirely and let `wake()` restart it —
        // a geometry notification or a mouse-down always precedes real motion.
        let buttonDown = NSEvent.pressedMouseButtons & 1 != 0
        let recentMotion = Date().timeIntervalSince(lastGeometryEvent) < 0.5
        guard buttonDown || recentMotion else {
            displayLink?.isPaused = true
            return
        }
        redock()
    }

    /// Resume the follow poll: something is about to move.
    private func wake() {
        displayLink?.isPaused = false
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
        restoreWindow()
        session.terminate()
        onFinished?(self)
    }

    /// App quitting: restore Finder geometry only.
    func restoreOnQuit() {
        restoreWindow()
    }

    /// Hand the window back exactly as we found it — its own size, and its
    /// fullscreen space when it had one.
    private func restoreWindow() {
        let freed = shrunkBy
        shrunkBy = 0
        if let space = reservedSpace {
            SpaceReservation.clear(space: space)   // the space gets its full layout back
            reservedSpace = nil
        } else if freed > 0 {
            tracker.adjust(side: side, by: freed)
        }
    }

    func applyTheme() {
        panel.applyTheme(session.applyTheme())
    }

    /// True when something beyond the idle shell is running here.
    var isBusy: Bool { !session.runningProcessNames().isEmpty }

    /// Move the terminal to another edge of the same window, live: hand the old
    /// edge back, take the new one. Works in a fullscreen space too (the strip is
    /// re-reserved on the new edge). Reverts if the new edge cannot make room.
    func changeSide(to newSide: DockSide) {
        guard newSide != side, shrunkBy > 0 else { return }
        let previous = side
        let height = terminalHeight
        let space = reservedSpace

        // Give the old edge back before claiming the new one, or the window ends
        // up short on both.
        if let space {
            SpaceReservation.clear(space: space)
            reservedSpace = nil
        } else {
            tracker.adjust(side: previous, by: shrunkBy)
            if let f = tracker.currentFrame() { _ = tracker.settledFrame(after: f) }
        }
        shrunkBy = 0
        side = newSide
        panel.side = newSide

        var ok = false
        if let space, let f = tracker.currentFrame() {
            ok = reserveStrip(height, in: space, from: f)
        } else if let f = tracker.currentFrame(),
                  let freed = Self.makeRoom(tracker: tracker, side: newSide, from: f) {
            shrunkBy = freed
            terminalHeight = (freed - TerminalPanel.gap).rounded()
            ok = true
        }
        guard ok else {
            devLog("changeSide: \(newSide.rawValue) made no room -> reverting")
            side = previous
            panel.side = previous
            if let space, let f = tracker.currentFrame() {
                _ = reserveStrip(height, in: space, from: f)
            } else if let f = tracker.currentFrame(),
                      let freed = Self.makeRoom(tracker: tracker, side: previous, from: f) {
                shrunkBy = freed
                terminalHeight = (freed - TerminalPanel.gap).rounded()
            }
            lastBodyRect = .zero
            redock()
            return
        }
        lastBodyRect = .zero
        redock()
        reassertOrder()
        wake()
    }

#if DEBUG
    /// Dev: drive the splitter without a mouse.
    func devSplitterDrag(_ delta: CGFloat) {
        panel.onResizeDrag?(delta)
        _ = flushPendingDrag()      // the display tick would do this
    }
#endif

    /// Cmd-W flow already resolved this terminal (terminated or kept):
    /// the upcoming AX destroyed notification must not alert again.
    func markResolvedBeforeClose() {
        suppressCloseAlert = true
    }

    /// Close our Finder window via AX (used by the Terminate paths).
    func closeFinderWindow() {
        tracker.pressCloseButton()
    }

    /// True when `point` (AX/CGEvent space) is on this window's close button.
    func ownsCloseButton(at point: CGPoint) -> Bool {
        guard let rect = tracker.closeButtonFrame() else { return false }
        return rect.contains(point)
    }

    /// A minimise just started (yellow button clicked at `point`, or Cmd-M with
    /// this window focused): fade out alongside the Dock animation instead of
    /// waiting for the AX notification, which only lands once it has finished.
    func minimizeStarting(at point: CGPoint?) -> Bool {
        guard panel.isShown, !tracker.isMinimized else { return false }
        if let point {
            guard tracker.minimizeButtonFrame()?.contains(point) == true else { return false }
        }
        panel.fadeOut()
        // The window server decides on mouse-up: a press that drags away, or a
        // Cmd-M the window ignored, never minimises. Put the panel back then.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self, !self.tracker.isMinimized, self.shrunkBy > 0 else { return }
            self.updatePanelVisibility()
        }
        return true
    }

    /// Folder the shell is in — where a replacement window should open.
    var currentFolder: String? { session.currentDir }

    private func teardown() {
        displayLink?.invalidate()
        displayLink = nil
        tracker.stopObserving()
    }

    /// The Finder window disappeared (red button, or Cmd-W we let through) — or
    /// a fullscreen transition just swapped its AX element while the window
    /// itself lives on.
    private func windowWasClosed() {
        if WindowTracker.exists(windowID: windowID), tracker.attach(windowID: windowID) != nil {
            devLog("stale destroy notification -> re-attached to \(windowID)")
            tracker.startObserving()
            if tracker.isFullScreen {
                adoptFullScreenSpace()
            } else if reservedSpace != nil {
                leftFullScreenSpace()
            } else {
                redock()
                reassertOrder()
            }
            return
        }
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
                let folder = self.currentFolder
                self.onFinished?(self)
                self.onWantsNewWindow?(session, folder)
            default:
                break   // superseded (.stop) — a newer alert owns the decision
            }
        }
    }

    /// A close was intercepted BEFORE Finder acted on it (Cmd-W or the red
    /// button): ask first — always, or only while a process runs, per the ALERTS
    /// setting. Cancel leaves the window exactly as it was.
    func confirmClose() {
        if !AppSettings.alertAlways && !isBusy {
            markResolvedBeforeClose()
            panel.hide()
            closeFinderWindow()
            session.terminate()
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        presentTerminateAlert { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }   // Cancel: window stays open
            self.markResolvedBeforeClose()
            // Fade first: Finder's close animation then runs alongside it rather
            // than the panel vanishing once the window is already gone.
            self.panel.hide()
            self.closeFinderWindow()
            self.session.terminate()
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
