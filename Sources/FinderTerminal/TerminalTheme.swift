import AppKit
import SwiftTerm

/// Colors + font pulled from the user's Terminal.app default profile so the
/// embedded terminal matches the system Terminal look.
struct TerminalTheme {
    var background: NSColor?      // keeps the profile's alpha (translucent backgrounds)
    var blur: CGFloat             // profile "BackgroundBlur", 0...1
    var foreground: NSColor?
    var cursor: NSColor?
    var selection: NSColor?
    var ansi: [SwiftTerm.Color]   // exactly 16
    var font: NSFont
    var lineHeight: CGFloat       // profile "FontHeightSpacing" multiplier, 1.0 = default

    /// xterm basic 16-color palette, used per-slot when a profile color is missing.
    private static let fallback16: [(UInt16, UInt16, UInt16)] = [
        (0, 0, 0), (205, 0, 0), (0, 205, 0), (205, 205, 0),
        (0, 0, 238), (205, 0, 205), (0, 205, 205), (229, 229, 229),
        (127, 127, 127), (255, 0, 0), (0, 255, 0), (255, 255, 0),
        (92, 92, 255), (255, 0, 255), (0, 255, 255), (255, 255, 255),
    ]

    private static let ansiKeys = [
        "ANSIBlackColor", "ANSIRedColor", "ANSIGreenColor", "ANSIYellowColor",
        "ANSIBlueColor", "ANSIMagentaColor", "ANSICyanColor", "ANSIWhiteColor",
        "ANSIBrightBlackColor", "ANSIBrightRedColor", "ANSIBrightGreenColor", "ANSIBrightYellowColor",
        "ANSIBrightBlueColor", "ANSIBrightMagentaColor", "ANSIBrightCyanColor", "ANSIBrightWhiteColor",
    ]

    /// Theme for the current AppSettings selection. Presets and custom themes
    /// reuse the Terminal.app profile's font and ANSI palette; only the core
    /// colors change.
    static func current() -> TerminalTheme {
        var t = fromTerminalApp()
        switch AppSettings.themeSelection {
        case .profile:
            break
        case .preset(let preset):
            let p = preset.palette
            t.background = NSColor(hex: p.bg)
            t.foreground = NSColor(hex: p.fg)
            t.cursor = NSColor(hex: p.cursor)
            t.selection = NSColor(hex: p.selection)
            t.blur = 0
        case .custom(let id):
            if let c = AppSettings.customTheme(id: id) {
                t.background = NSColor(hex: c.background)
                t.foreground = NSColor(hex: c.text)
                t.cursor = NSColor(hex: c.cursor)
                t.selection = NSColor(hex: c.selection)
                t.blur = 0
            }
        }
        if AppSettings.fontSize > 0 {
            t.font = NSFont(descriptor: t.font.fontDescriptor, size: AppSettings.fontSize) ?? t.font
        }
        return t
    }

    static func fromTerminalApp() -> TerminalTheme {
        let d = UserDefaults(suiteName: "com.apple.Terminal")
        let profileName = d?.string(forKey: "Default Window Settings")
            ?? d?.string(forKey: "Startup Window Settings")
        let settings = d?.dictionary(forKey: "Window Settings")
        let profile = (profileName.flatMap { settings?[$0] }) as? [String: Any]

        func color(_ key: String) -> NSColor? {
            guard let data = profile?[key] as? Data else { return nil }
            let c = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: data)
            return c?.usingColorSpace(.sRGB) ?? c
        }

        var ansi: [SwiftTerm.Color] = []
        for (i, key) in ansiKeys.enumerated() {
            if let c = color(key), let st = c.swiftTermColor {
                ansi.append(st)
            } else {
                let (r, g, b) = fallback16[i]
                ansi.append(SwiftTerm.Color(red: r &* 257, green: g &* 257, blue: b &* 257))
            }
        }

        let font: NSFont = {
            if let data = profile?["Font"] as? Data,
               let f = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSFont.self, from: data) {
                return f
            }
            return NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        }()

        return TerminalTheme(
            background: color("BackgroundColor"),
            blur: CGFloat(profile?["BackgroundBlur"] as? Double ?? 0),
            foreground: color("TextColor"),
            cursor: color("CursorColor"),
            selection: color("SelectionColor"),
            ansi: ansi,
            font: font,
            lineHeight: CGFloat(profile?["FontHeightSpacing"] as? Double ?? 1.0)
        )
    }
}

private extension NSColor {
    var swiftTermColor: SwiftTerm.Color? {
        guard let c = usingColorSpace(.sRGB) else { return nil }
        func u16(_ v: CGFloat) -> UInt16 { UInt16(max(0, min(1, v)) * 65535) }
        return SwiftTerm.Color(red: u16(c.redComponent), green: u16(c.greenComponent), blue: u16(c.blueComponent))
    }
}
