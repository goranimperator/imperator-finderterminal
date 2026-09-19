import AppKit
import SwiftUI

/// The menu bar panel, drawn by the app rather than by `NSPopover`.
///
/// `NSPopover` draws its own frame and gives no way to set the radius. On macOS
/// 27 that frame is far rounder than the popup the system itself puts under a
/// menu bar item: measured with `screencapture -o -l`, an `NSPopover` from a
/// binary stamped `sdk 27.0` stops curving 87 device pixels in, while the popup
/// under Imperator WidgetClock, whose binary still carries an old stamp and so
/// still gets the old frame, stops at 20. Matching the system popup therefore
/// means drawing the surface here.
///
/// Everything below is measured off that WidgetClock popup rather than guessed:
/// the corner, the arrow's height and base, and the material.
final class MenuBarPanel: NSPanel {
    /// Measured: the menu bar popup's corner stops curving 20 device pixels in,
    /// against a Finder window's 42. Do not substitute brandbook 13's 18pt
    /// window radius; a popup is tighter than a window on macOS 27.
    ///
    /// Circular, not `.continuous`: the shape is built with `NSBezierPath`,
    /// whose rounded rect is a circular arc, and mixing the two curves adds them
    /// into a corner measuring 33 device pixels instead of 19.
    static let cornerRadius: CGFloat = 10
    /// Measured: the arrow rises 18 device pixels from the body to its tip.
    private static let arrowHeight: CGFloat = 9
    /// Measured: 44 device pixels across where it meets the body.
    private static let arrowWidth: CGFloat = 22
    /// Gap between the menu bar and the arrow's tip.
    private static let menuBarGap: CGFloat = 2

    private let host: NSHostingView<AnyView>
    private let container = NSVisualEffectView()
    private let shape = CAShapeLayer()
    private var clickMonitor: Any?
    private var keyMonitor: Any?
    /// The menu bar button this panel hangs off, so a click on it is left to the
    /// button's own action instead of being treated as a click outside.
    private weak var anchor: NSStatusBarButton?
    /// Where the arrow points, in the panel's own coordinates.
    private var arrowCenterX: CGFloat = 0

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
        container.material = .popover
        container.blendingMode = .behindWindow
        container.state = .active
        container.wantsLayer = true
        // A layer mask, not `maskImage`: the shape has an arrow at a position
        // that moves with the status item, and a resizable mask image can only
        // stretch a fixed picture.
        container.layer?.mask = shape

        host.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            // The content sits below the arrow, which occupies the top strip.
            host.topAnchor.constraint(equalTo: container.topAnchor, constant: Self.arrowHeight),
            host.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        contentView = container
    }

    var isShown: Bool { isVisible }

    /// Show under the menu bar button, with the arrow pointing at it.
    func show(from button: NSStatusBarButton) {
        guard let buttonWindow = button.window else { return }
        anchor = button

        let size = host.fittingSize
        setContentSize(NSSize(width: frame.width, height: size.height + Self.arrowHeight))

        let buttonFrame = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = buttonWindow.screen ?? NSScreen.main
        var x = buttonFrame.midX - frame.width / 2
        // Keep the whole panel on screen when the item sits near an edge. The
        // arrow then slides within the panel instead, so it still points at the
        // item rather than the panel's middle.
        if let visible = screen?.visibleFrame {
            x = min(max(x, visible.minX + 8), visible.maxX - frame.width - 8)
        }
        setFrameTopLeftPoint(NSPoint(x: x, y: buttonFrame.minY - Self.menuBarGap))

        arrowCenterX = buttonFrame.midX - x
        updateShape()

        orderFrontRegardless()
        startMonitoring()
    }

    func close(_ sender: Any? = nil) {
        stopMonitoring()
        orderOut(nil)
        onClose?()
    }

    /// Rebuild the mask: a rounded body with an arrow on top, pointing at the
    /// status item.
    private func updateShape() {
        let bounds = container.bounds
        guard bounds.width > 0, bounds.height > Self.arrowHeight else { return }
        shape.frame = bounds
        shape.path = Self.outline(in: bounds, arrowCenterX: arrowCenterX)
    }

    override func layoutIfNeeded() {
        super.layoutIfNeeded()
        updateShape()
    }

    /// The panel's silhouette, in a bottom-left origin coordinate space.
    private static func outline(in bounds: CGRect, arrowCenterX: CGFloat) -> CGPath {
        let r = cornerRadius
        let body = CGRect(x: bounds.minX, y: bounds.minY,
                          width: bounds.width, height: bounds.height - arrowHeight)
        // Keep the arrow's base inside the rounded corners.
        let half = arrowWidth / 2
        let cx = min(max(arrowCenterX, body.minX + r + half), body.maxX - r - half)
        let tip = CGPoint(x: cx, y: bounds.maxY)   // one arrowHeight above the body
        // Measured: the system's topmost arrow row is 8 device pixels wide.
        let tipHalf: CGFloat = 2
        let tipRound: CGFloat = 1

        let path = CGMutablePath()
        path.move(to: CGPoint(x: body.minX + r, y: body.minY))
        path.addLine(to: CGPoint(x: body.maxX - r, y: body.minY))
        path.addArc(tangent1End: CGPoint(x: body.maxX, y: body.minY),
                    tangent2End: CGPoint(x: body.maxX, y: body.minY + r), radius: r)
        path.addLine(to: CGPoint(x: body.maxX, y: body.maxY - r))
        path.addArc(tangent1End: CGPoint(x: body.maxX, y: body.maxY),
                    tangent2End: CGPoint(x: body.maxX - r, y: body.maxY), radius: r)
        // The arrow: straight edges with a rounded tip, which is what the system
        // draws. Measured on the system popup, its width grows roughly linearly
        // from 8 device pixels at the tip to 44 at the base. A single quadratic
        // across the whole arrow was tried first and gives a dome instead: 22
        // device pixels wide a quarter of the way up, where the system is 8.
        path.addLine(to: CGPoint(x: cx + half, y: body.maxY))
        path.addLine(to: CGPoint(x: tip.x + tipHalf, y: tip.y - tipRound))
        path.addQuadCurve(to: CGPoint(x: tip.x - tipHalf, y: tip.y - tipRound),
                          control: CGPoint(x: tip.x, y: tip.y + tipRound))
        path.addLine(to: CGPoint(x: cx - half, y: body.maxY))
        path.addLine(to: CGPoint(x: body.minX + r, y: body.maxY))
        path.addArc(tangent1End: CGPoint(x: body.minX, y: body.maxY),
                    tangent2End: CGPoint(x: body.minX, y: body.maxY - r), radius: r)
        path.addLine(to: CGPoint(x: body.minX, y: body.minY + r))
        path.addArc(tangent1End: CGPoint(x: body.minX, y: body.minY),
                    tangent2End: CGPoint(x: body.minX + r, y: body.minY), radius: r)
        path.closeSubpath()
        return path
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

    // A borderless panel refuses key status by default, which would leave the
    // SwiftUI content unable to take the Escape key or drive its controls.
    override var canBecomeKey: Bool { true }

    deinit { stopMonitoring() }
}
