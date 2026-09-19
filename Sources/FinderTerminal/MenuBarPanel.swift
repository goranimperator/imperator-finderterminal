import AppKit
import SwiftUI

/// The menu bar panel, drawn by the app rather than by `NSPopover`.
///
/// `NSPopover` draws its own frame, and on macOS 27 that frame is far rounder
/// than a window: measured against a real Finder window, a popover's corner
/// stops curving 87 device pixels in where the window's stops at 42. Nothing in
/// the popover API sets that radius, so matching the system's window shape means
/// drawing the surface here instead.
///
/// The radius is the menu bar popup's own, not the window radius. Brandbook 13
/// carries 18pt for window-shaped surfaces and says in as many words that the
/// popup surface has not been measured separately and should be, rather than
/// inheriting the window figure. Measured here: the macOS 27 menu bar popup
/// corner stops curving 20 device pixels in, against a window's 42.
final class MenuBarPanel: NSPanel {
    /// Measured: a menu bar popup's corner stops curving 20 device pixels in,
    /// against a window's 42. Do not substitute the 18pt window radius here; a
    /// popup is tighter than a window on macOS 27.
    ///
    /// Circular, not `.continuous`: the mask that clips the material is a
    /// `NSBezierPath` rounded rect, which is a circular arc, and mixing the two
    /// curves adds them into a corner wider than either.
    static let cornerRadius: CGFloat = 10
    /// Gap between the menu bar and the panel's top edge.
    private static let menuBarGap: CGFloat = 6

    private let host: NSHostingView<AnyView>
    private var clickMonitor: Any?
    private var keyMonitor: Any?
    /// The menu bar button this panel hangs off, so a click on it is left to the
    /// button's own action instead of being treated as a click outside.
    private weak var anchor: NSStatusBarButton?

    /// Called when the panel closes itself, so the owner can drop its reference
    /// to the monitors and keep the menu bar button's pressed state honest.
    var onClose: (() -> Void)?

    init<Content: View>(content: Content, width: CGFloat) {
        host = NSHostingView(rootView: AnyView(content))
        super.init(contentRect: NSRect(x: 0, y: 0, width: width, height: 100),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: true)

        // Brandbook 20.3, minus the always-on-top behaviour: this panel is
        // transient, so it closes on the first click elsewhere rather than
        // living above other apps.
        level = .popUpMenu
        isFloatingPanel = true
        hidesOnDeactivate = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        isMovable = false

        // The surface is the system's own popover material, not a colour copied
        // out of a screenshot: `NSVisualEffectView` with `.popover` blends what
        // is behind the panel exactly the way AppKit does for a real one, and it
        // tracks appearance and accessibility settings for free. The SwiftUI
        // content then lays brandbook 6.1's `.black.opacity(0.15)` over it.
        let container = NSVisualEffectView()
        container.material = .popover
        container.blendingMode = .behindWindow
        container.state = .active
        container.wantsLayer = true
        container.layer?.cornerRadius = Self.cornerRadius
        container.layer?.cornerCurve = .circular
        container.layer?.masksToBounds = true
        container.layer?.borderWidth = 0.5
        container.layer?.borderColor = NSColor(white: 1, alpha: 0.08).cgColor
        // Clip the effect view itself, or the material is drawn square behind
        // the rounded layer and the corners come back filled.
        container.maskImage = Self.cornerMask(radius: Self.cornerRadius)

        host.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            host.topAnchor.constraint(equalTo: container.topAnchor),
            host.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        contentView = container
    }

    var isShown: Bool { isVisible }

    /// Show under the menu bar button, right-aligned to it the way a popover is.
    func show(from button: NSStatusBarButton) {
        guard let buttonWindow = button.window else { return }
        anchor = button

        let size = host.fittingSize
        setContentSize(NSSize(width: frame.width, height: size.height))

        let buttonFrame = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = buttonWindow.screen ?? NSScreen.main
        var x = buttonFrame.midX - frame.width / 2
        // Keep the whole panel on screen when the item sits near an edge.
        if let visible = screen?.visibleFrame {
            x = min(max(x, visible.minX + 8), visible.maxX - frame.width - 8)
        }
        setFrameTopLeftPoint(NSPoint(x: x, y: buttonFrame.minY - Self.menuBarGap))

        orderFrontRegardless()
        startMonitoring()
    }

    func close(_ sender: Any? = nil) {
        stopMonitoring()
        orderOut(nil)
        onClose?()
    }

    /// Transient behaviour, which `NSPopover` gave for free: a click anywhere
    /// else, or Escape, dismisses the panel.
    private func startMonitoring() {
        stopMonitoring()
        clickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            guard let self else { return }
            // The status item's own click is the toggle. Closing here too would
            // race the button's action, which then reopens what it just closed.
            if let window = self.anchor?.window,
               window.frame.contains(NSEvent.mouseLocation) { return }
            self.close()
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }   // Escape
            self?.close()
            return nil
        }
    }

    private func stopMonitoring() {
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        clickMonitor = nil
        keyMonitor = nil
    }

    /// A resizable mask with the panel's corner, so `NSVisualEffectView` blends
    /// only inside the rounded shape.
    private static func cornerMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }

    // A borderless panel refuses key status by default, which would leave the
    // SwiftUI content unable to take the Escape key or drive its controls.
    override var canBecomeKey: Bool { true }

    deinit { stopMonitoring() }
}
