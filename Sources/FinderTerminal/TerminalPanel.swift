import AppKit
import SwiftTerm

/// A terminal window attached to one edge of the Finder window, styled like a real
/// macOS window: system window-background chrome (Finder's exact color), hairline
/// border, rounded corners and shadow. Inside sits the terminal plate — theme
/// background color, its own corner radius, and inner padding before the text.
/// The edge facing Finder carries a visible splitter pill in the gap (resizes both
/// windows at once); the opposite edge resizes like a normal window.
final class TerminalPanel: NSPanel {
    private let terminal: NSView
    private let container = NSView()      // window body (Finder-colored chrome)
    private let terminalBox = NSView()    // theme-colored plate holding the terminal
    private let gapHandle: DragHandle     // lives in the gap between Finder and the body
    private let gapPill = NSView()        // visible grab indicator centered in the gap
    private let outerHandle: DragHandle   // window-style resize on the opposite edge

    /// Which Finder edge the panel is attached to. Set before show().
    var side: DockSide = .bottom { didSet { layoutContent() } }

    /// Overlay mode (the Finder window is in a fullscreen space) — remembered so
    /// a live preference change can rebuild the collection behavior.
    private var overlay = false

    static let defaultHeight: CGFloat = 300
    static let minTerminalHeight: CGFloat = 120
    /// Breathing room between the Finder window and the terminal body. The panel's
    /// window frame includes this transparent strip so the splitter can live in it.
    static let gap: CGFloat = 8
    /// macOS 27 window corner radius. Measured twice, not guessed. A real Finder
    /// window captured with `screencapture -o -l<id>` has an alpha silhouette whose
    /// corner stops curving 42 device pixels in. Rendering this same layer
    /// (`.continuous`, masked) at 2x and measuring the identical way gives 41 px at
    /// radius 18 and 46 px at radius 20, so 18 is the match. Do not reason from the
    /// radius to the visual size: a continuous corner spreads well past its radius,
    /// which is why the old 26 pt (macOS 26's value) read as noticeably rounder than
    /// the window it docks to once 27 tightened the system corners.
    private static let windowRadius: CGFloat = 18
    /// Concentric with the window radius: outer radius minus the chrome padding.
    private static let plateRadius: CGFloat = 10
    private static let handleHeight: CGFloat = 8
    /// Hit zone for the gap splitter: the gap itself + a few points into the body.
    private static let gapHitHeight: CGFloat = 14
    /// Chrome padding: window edge -> terminal plate (Finder color shows here).
    /// Taken from the system, not chosen: a macOS 27 Finder toolbar button sits 8 pt
    /// off the window edge. Measured on a real window capture, where the luminance
    /// along a row through the search button's centre holds the window background
    /// for 15 device pixels and the button's own fill starts at 16.
    private static let outer: CGFloat = 8
    /// Plate padding: plate edge -> text (terminal background shows here). Same
    /// value, so the text sits as far off the plate as the plate sits off the window.
    private static let inner: CGFloat = 8

    /// Splitter drag in the gap; positive = grow the terminal (toward Finder).
    var onResizeDrag: ((CGFloat) -> Void)?
    /// Outer-edge drag; positive = grow the terminal (away from Finder).
    var onBottomResizeDrag: ((CGFloat) -> Void)?

    init(terminal: NSView) {
        self.terminal = terminal
        self.gapHandle = DragHandle()
        self.outerHandle = DragHandle()
        super.init(contentRect: NSRect(x: 0, y: 0, width: 600, height: Self.defaultHeight),
                   styleMask: [.borderless],
                   backing: .buffered, defer: false)
        // Normal level: the panel lives in the regular window stack, slotted just
        // above its Finder window via order(_:relativeTo:) — so anything covering
        // that window covers the terminal too. It must NOT float over other apps.
        isFloatingPanel = false
        level = .normal
        hidesOnDeactivate = false
        collectionBehavior = Self.behavior(overlay: false)
        hasShadow = true
        backgroundColor = .clear
        isOpaque = false

        // Window body: exact system window background (same as Finder), rounded,
        // with the standard macOS hairline edge. Sits beside the transparent gap strip.
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor  // refined in applyTheme
        container.layer?.cornerRadius = Self.windowRadius
        container.layer?.cornerCurve = .continuous
        container.layer?.masksToBounds = true
        // Single physical pixel on retina, barely-there like the real Finder edge
        // (tuned against side-by-side screenshots; the top-edge highlight of real
        // chrome is brighter than the sides, so err dark).
        container.layer?.borderWidth = 0.5
        container.layer?.borderColor = NSColor(white: 1, alpha: 0.08).cgColor
        contentView?.addSubview(container)

        // Terminal plate: theme background, own rounded corners.
        terminalBox.wantsLayer = true
        terminalBox.layer?.cornerRadius = Self.plateRadius
        terminalBox.layer?.cornerCurve = .continuous
        terminalBox.layer?.masksToBounds = true
        terminalBox.layer?.backgroundColor = NSColor.black.cgColor
        container.addSubview(terminalBox)

        terminalBox.addSubview(terminal)

        // Splitter in the gap between Finder and the terminal body: resizes both
        // at once. Visible pill so it can be found. The near-invisible fill makes
        // the window own the gap pixels — macOS hit-tests borderless windows per
        // pixel, so a fully transparent gap would let clicks fall through to
        // whatever app is behind.
        gapHandle.onDrag = { [weak self] dx, dy in
            guard let self else { return }
            self.onResizeDrag?(Self.growDelta(towardFinder: true, side: self.side, dx: dx, dy: dy))
        }
        gapHandle.wantsLayer = true
        gapHandle.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.01).cgColor
        contentView?.addSubview(gapHandle)
        gapPill.wantsLayer = true
        gapPill.layer?.backgroundColor = NSColor(white: 1, alpha: 0.28).cgColor
        gapPill.layer?.cornerRadius = 2.5
        contentView?.addSubview(gapPill)

        // Opposite edge: normal window resize.
        outerHandle.onDrag = { [weak self] dx, dy in
            guard let self else { return }
            self.onBottomResizeDrag?(Self.growDelta(towardFinder: false, side: self.side, dx: dx, dy: dy))
        }
        container.addSubview(outerHandle)

        layoutContent()
    }

    /// Map a raw mouse delta to "grow the terminal" points for the given side.
    /// The splitter edge faces Finder; the outer edge faces away from it.
    private static func growDelta(towardFinder: Bool, side: DockSide, dx: CGFloat, dy: CGFloat) -> CGFloat {
        switch (side, towardFinder) {
        case (.bottom, true): dy          // drag up eats into Finder
        case (.bottom, false): -dy        // drag down grows outward
        case (.top, true): -dy
        case (.top, false): dy
        case (.left, true): dx
        case (.left, false): -dx
        case (.right, true): -dx
        case (.right, false): dx
        }
    }

    /// Goran-specified exact chrome shade: #1B1B1B.
    private func chromeColor() -> CGColor {
        CGColor(srgbRed: 0x1B / 255.0, green: 0x1B / 255.0, blue: 0x1B / 255.0, alpha: 1)
    }

    /// Match the current theme: plate gets the theme background (opaque — it sits
    /// on solid window chrome), chrome tracks the Finder color.
    func applyTheme(_ theme: TerminalTheme) {
        container.layer?.backgroundColor = chromeColor()
        terminalBox.layer?.backgroundColor =
            (theme.background ?? .black).withAlphaComponent(1).cgColor
    }

    private func layoutContent() {
        guard let cv = contentView else { return }
        let w = cv.bounds.width
        let h = cv.bounds.height
        let g = Self.gap
        let hit = Self.gapHitHeight

        // Body fills everything except the transparent gap strip on the Finder side.
        // The gap handle spans the strip plus a few points into the body; the pill
        // sits centered in the strip. The outer handle hugs the opposite edge.
        switch side {
        case .bottom:   // Finder above: gap strip on top
            container.frame = NSRect(x: 0, y: 0, width: w, height: h - g)
            gapHandle.frame = NSRect(x: 0, y: h - hit, width: w, height: hit)
            gapPill.frame = NSRect(x: (w - 36) / 2, y: h - g + 1.5, width: 36, height: 5)
            outerHandle.frame = NSRect(x: 0, y: 0, width: container.bounds.width, height: Self.handleHeight)
        case .top:      // Finder below: gap strip at bottom
            container.frame = NSRect(x: 0, y: g, width: w, height: h - g)
            gapHandle.frame = NSRect(x: 0, y: 0, width: w, height: hit)
            gapPill.frame = NSRect(x: (w - 36) / 2, y: 1.5, width: 36, height: 5)
            outerHandle.frame = NSRect(x: 0, y: container.bounds.height - Self.handleHeight,
                                       width: container.bounds.width, height: Self.handleHeight)
        case .left:     // Finder to the right: gap strip on the right
            container.frame = NSRect(x: 0, y: 0, width: w - g, height: h)
            gapHandle.frame = NSRect(x: w - hit, y: 0, width: hit, height: h)
            gapPill.frame = NSRect(x: w - g + 1.5, y: (h - 36) / 2, width: 5, height: 36)
            outerHandle.frame = NSRect(x: 0, y: 0, width: Self.handleHeight, height: container.bounds.height)
        case .right:    // Finder to the left: gap strip on the left
            container.frame = NSRect(x: g, y: 0, width: w - g, height: h)
            gapHandle.frame = NSRect(x: 0, y: 0, width: hit, height: h)
            gapPill.frame = NSRect(x: 1.5, y: (h - 36) / 2, width: 5, height: 36)
            outerHandle.frame = NSRect(x: container.bounds.width - Self.handleHeight, y: 0,
                                       width: Self.handleHeight, height: container.bounds.height)
        }
        container.autoresizingMask = [.width, .height]
        gapHandle.cursor = side.isVertical ? .resizeLeftRight : .resizeUpDown
        outerHandle.cursor = side.isVertical ? .resizeLeftRight : .resizeUpDown

        let b = container.bounds
        terminalBox.frame = b.insetBy(dx: Self.outer, dy: Self.outer)
        terminalBox.autoresizingMask = [.width, .height]
        terminal.frame = terminalBox.bounds.insetBy(dx: Self.inner, dy: Self.inner)
        terminal.autoresizingMask = [.width, .height]

        // Keep gap furniture glued to the right edges on resize.
        switch side {
        case .bottom:
            gapHandle.autoresizingMask = [.width, .minYMargin]
            gapPill.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin]
            outerHandle.autoresizingMask = [.width, .maxYMargin]
        case .top:
            gapHandle.autoresizingMask = [.width, .maxYMargin]
            gapPill.autoresizingMask = [.minXMargin, .maxXMargin, .maxYMargin]
            outerHandle.autoresizingMask = [.width, .minYMargin]
        case .left:
            gapHandle.autoresizingMask = [.height, .minXMargin]
            gapPill.autoresizingMask = [.minYMargin, .maxYMargin, .minXMargin]
            outerHandle.autoresizingMask = [.height, .maxXMargin]
        case .right:
            gapHandle.autoresizingMask = [.height, .maxXMargin]
            gapPill.autoresizingMask = [.minYMargin, .maxYMargin, .maxXMargin]
            outerHandle.autoresizingMask = [.height, .minXMargin]
        }
    }

#if DEBUG
    /// Dev introspection: what the chrome layer actually holds.
    var debugChromeColor: String {
        guard let cg = container.layer?.backgroundColor,
              let c = NSColor(cgColor: cg)?.usingColorSpace(.sRGB) else { return "nil" }
        return String(format: "#%02X%02X%02X", Int(c.redComponent * 255),
                      Int(c.greenComponent * 255), Int(c.blueComponent * 255))
    }
#endif

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    /// An accessory app has no menu bar, so nothing matches the standard editing
    /// key equivalents and Cmd-C/V never reach the terminal. Route them here.
    ///
    /// The same gap hides every shortcut SwiftTerm only publishes as a menu
    /// action — clear, find, font size — so those are routed here too, to the
    /// keys Terminal.app uses for them.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard mods == .command || mods == [.command, .shift],
              let key = event.charactersIgnoringModifiers?.lowercased() else {
            return super.performKeyEquivalent(with: event)
        }
        let shift = mods.contains(.shift)

        switch (key, shift) {
        case ("k", false): if clearTerminal() { return true }
        case ("f", false): if findAction(.showFindInterface) { return true }
        case ("g", false): if findAction(.nextMatch) { return true }
        case ("g", true):  if findAction(.previousMatch) { return true }
        // Cmd-+ is Shift-= on a US layout and a bare + on a Nordic one.
        case ("+", _), ("=", false): if stepFontSize(by: 1) { return true }
        case ("-", false): if stepFontSize(by: -1) { return true }
        case ("0", false): if setFontSize(0) { return true }
        default: break
        }

        guard !shift else { return super.performKeyEquivalent(with: event) }
        let action: Selector? = switch key {
        case "c": #selector(NSText.copy(_:))
        case "v": #selector(NSText.paste(_:))
        case "x": #selector(NSText.cut(_:))
        case "a": #selector(NSText.selectAll(_:))
        default: nil
        }
        guard let action, terminal.responds(to: action) else {
            return super.performKeyEquivalent(with: event)
        }
        terminal.perform(action, with: self)
        return true
    }

    /// Cmd-K: empty the screen and the scrollback with it.
    private func clearTerminal() -> Bool {
        guard let view = terminal as? TerminalView else { return false }
        // Home, erase the screen, erase the scrollback (xterm's E3) — the bytes
        // `clear` itself sends on a current terminfo, fed to the emulator rather
        // than to the shell so a running program is not interrupted.
        view.feed(text: "\u{1b}[H\u{1b}[2J\u{1b}[3J")
        // The shell drew the prompt that just went away and will not repaint it
        // until the next keystroke, which reads as a terminal that cleared
        // itself and then died. Ctrl-L is the shell's own redraw, so zsh puts
        // the prompt back at the top and a full-screen program repaints.
        view.send(txt: "\u{0c}")
        return true
    }

    /// Cmd-F / Cmd-G / Cmd-Shift-G: SwiftTerm's find bar.
    private func findAction(_ action: NSTextFinder.Action) -> Bool {
        guard let view = terminal as? TerminalView else { return false }
        // SwiftTerm reads the action off the sender's menu item tag, so a menu
        // item is what it has to be handed, menu bar or no menu bar.
        let item = NSMenuItem()
        item.tag = action.rawValue
        view.performTextFinderAction(item)
        return true
    }

    /// Cmd-+ / Cmd-- step the size, Cmd-0 goes back to the profile's own.
    ///
    /// Written to the setting rather than to the view: the size belongs to
    /// `AppSettings`, the Settings slider shows it, and the fan-out applies it
    /// to every open terminal. Setting `view.font` here would be reverted by the
    /// next theme apply.
    private func stepFontSize(by delta: CGFloat) -> Bool {
        // 0 means "follow the Terminal.app profile", so step from what is drawn.
        let current = AppSettings.fontSize > 0
            ? AppSettings.fontSize
            : (terminal as? TerminalView)?.font.pointSize ?? 12
        return setFontSize(min(max(current + delta, 6), 24))
    }

    @discardableResult
    private func setFontSize(_ size: CGFloat) -> Bool {
        UserDefaults.standard.set(Double(size), forKey: AppSettings.fontSizeKey)
        return true
    }

    /// Never let AppKit nudge the panel back on-screen — it must sit exactly in
    /// the gap beside the Finder window, even partially off-screen near the Dock.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }

    var isShown: Bool { isVisible && alphaValue > 0.01 }

    /// Overlay mode = the Finder window sits in a fullscreen space. Such a space
    /// only shows windows that opt in, and a `.normal` window never draws above
    /// a fullscreen one — so join all spaces and float. Outside fullscreen both
    /// would put the panel over unrelated apps, so it stays `.normal` there.
    func setOverlay(_ on: Bool) {
        overlay = on
        collectionBehavior = Self.behavior(overlay: on)
        level = on ? .floating : .normal
    }

    /// Re-read the Mission Control preference. The window server only looks at
    /// `collectionBehavior` when it is set, so a live change has to be pushed.
    func refreshCollectionBehavior() {
        collectionBehavior = Self.behavior(overlay: overlay)
    }

    /// `.transient` takes the panel out of the Mission Control and Exposé
    /// overview — the Finder window then shows there alone. It also means the
    /// window is unmanaged by Spaces, which is fine here: `updatePanelVisibility`
    /// already decides per space whether the panel belongs on screen.
    private static func behavior(overlay: Bool) -> NSWindow.CollectionBehavior {
        var b: NSWindow.CollectionBehavior =
            overlay ? [.canJoinAllSpaces, .fullScreenAuxiliary] : [.fullScreenAuxiliary]
        if AppSettings.hideInMissionControl { b.insert(.transient) }
        return b
    }


    /// `rect` is the visible body; the window adds the transparent gap strip on
    /// the Finder-facing side.
    private func windowFrame(forBody rect: CGRect) -> CGRect {
        let g = Self.gap
        return switch side {
        case .bottom: CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height + g)
        case .top: CGRect(x: rect.minX, y: rect.minY - g, width: rect.width, height: rect.height + g)
        case .left: CGRect(x: rect.minX, y: rect.minY, width: rect.width + g, height: rect.height)
        case .right: CGRect(x: rect.minX - g, y: rect.minY, width: rect.width + g, height: rect.height)
        }
    }

    /// `takeFocus` false leaves Finder in charge: the panel appears but keyboard
    /// focus stays where it was (Settings ▸ Focus).
    func show(at rect: CGRect, takeFocus: Bool = true) {
        setFrame(windowFrame(forBody: rect), display: false)
        layoutContent()
        alphaValue = 0
        if takeFocus {
            makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            makeFirstResponder(terminal)
        } else {
            orderFront(nil)
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Self.fadeDuration
            animator().alphaValue = 1
        }
    }

    /// One fade for every way the panel leaves or returns — same duration, same
    /// default easing — so it always reads as one gesture and its reverse.
    private static let fadeDuration: TimeInterval = 0.22

    func fadeOut() {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = Self.fadeDuration
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, self.alphaValue < 0.01 else { return }
            self.orderOut(nil)
        })
    }

    /// Come back with the window instead of popping in.
    func fadeIn() {
        alphaValue = 0
        orderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Self.fadeDuration
            animator().alphaValue = 1
        }
    }

    func hide() {
        // A sheet on a hidden panel would linger invisibly; .stop matches no
        // alert button, so pending completions become no-ops.
        if let sheet = attachedSheet { endSheet(sheet, returnCode: .stop) }
        fadeOut()
    }

    /// Follow the Finder window (no animation). Applies while hidden too, so a
    /// panel that sat out a space switch comes back in the right place.
    /// `display: false` — the window server composites the new frame either way,
    /// and forcing a synchronous display pass per mouse event is what makes a
    /// follow feel heavy.
    func reDock(at rect: CGRect) {
        setFrame(windowFrame(forBody: rect), display: false)
    }

    static func quakeFrame() -> CGRect {
        let screen = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1200, height: 800)
        return CGRect(x: screen.minX, y: screen.maxY - defaultHeight,
                      width: screen.width, height: defaultHeight)
    }
}

/// Invisible drag zone along an edge; owns its resize cursor and reports raw
/// mouse deltas in global points.
private final class DragHandle: NSView {
    var onDrag: ((CGFloat, CGFloat) -> Void)?
    var cursor: NSCursor = .resizeUpDown {
        didSet { window?.invalidateCursorRects(for: self) }
    }
    private var last = CGPoint.zero

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: cursor)
    }

    override func mouseDown(with event: NSEvent) {
        last = NSEvent.mouseLocation
    }

    override func mouseDragged(with event: NSEvent) {
        let p = NSEvent.mouseLocation
        onDrag?(p.x - last.x, p.y - last.y)
        last = p
    }
}
