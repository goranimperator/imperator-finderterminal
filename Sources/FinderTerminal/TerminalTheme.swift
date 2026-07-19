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

    /// The ten classic Terminal.app profile palettes: (background, text, cursor, selection).
    private static let presets: [ThemeChoice: (String, String, String, String)] = [
        .basic: ("#FFFFFF", "#000000", "#7F7F7F", "#A5CDFF"),
        .grass: ("#13773D", "#FFF0A5", "#8C2800", "#B64926"),
        .homebrew: ("#000000", "#28FE14", "#38FF12", "#083905"),
        .manPage: ("#FEF49C", "#000000", "#7F7F7F", "#A5CDFF"),
        .novel: ("#DFDBC3", "#3B2322", "#73635A", "#A4A390"),
        .ocean: ("#224FBC", "#FFFFFF", "#7F7F7F", "#216DFF"),
        .pro: ("#000000", "#F2F2F2", "#4D4D4D", "#414141"),
        .redSands: ("#7A251E", "#D7C9A7", "#FFFFFF", "#A4A390"),
        .silverAerogel: ("#929292", "#000000", "#939393", "#C1DDFF"),
        .solidColors: ("#FFFFFF", "#000000", "#7F7F7F", "#A5CDFF"),
    ]

    /// Theme for the current AppSettings selection. Presets and custom reuse the
    /// Terminal.app profile's font and ANSI palette; only the core colors change.
    static func current() -> TerminalTheme {
        var t = fromTerminalApp()
        switch AppSettings.theme {
        case .profile:
            break
        case .custom:
            t.background = AppSettings.customBackground
            t.foreground = AppSettings.customText
            t.cursor = AppSettings.customCursor
            t.selection = AppSettings.customSelection
            t.blur = 0
        case let choice:
            if let (bg, fg, cur, sel) = presets[choice] {
                t.background = NSColor(hex: bg)
                t.foreground = NSColor(hex: fg)
                t.cursor = NSColor(hex: cur)
                t.selection = NSColor(hex: sel)
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
