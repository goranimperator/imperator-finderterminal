import AppKit

/// Which edge of the Finder window the terminal docks to.
enum DockSide: String, CaseIterable, Identifiable {
    case top, right, bottom, left
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
    var isVertical: Bool { self == .left || self == .right }
}

/// Terminal theme selection: follow Terminal.app's default profile, one of the
/// ten classic Terminal.app presets, or fully custom colors.
enum ThemeChoice: String, CaseIterable, Identifiable {
    case profile = "Terminal.app Profile"
    case basic = "Basic"
    case grass = "Grass"
    case homebrew = "Homebrew"
    case manPage = "Man Page"
    case novel = "Novel"
    case ocean = "Ocean"
    case pro = "Pro"
    case redSands = "Red Sands"
    case silverAerogel = "Silver Aerogel"
    case solidColors = "Solid Colors"
    case custom = "Custom"
    var id: String { rawValue }
}

/// UserDefaults-backed app settings. Keys are shared with SwiftUI @AppStorage.
enum AppSettings {
    static let themeKey = "ft.theme"
    static let positionKey = "ft.position"
    static let customBackgroundKey = "ft.customBackground"
    static let customTextKey = "ft.customText"
    static let customCursorKey = "ft.customCursor"
    static let customSelectionKey = "ft.customSelection"
    static let fontSizeKey = "ft.fontSize"

    // Imperator-flavored custom defaults (brandbook palette).
    static let defaultCustomBackground = "#0A0A0A"
    static let defaultCustomText = "#CFC8BD"
    static let defaultCustomCursor = "#A01818"
    static let defaultCustomSelection = "#A0181866"

    static var theme: ThemeChoice {
        ThemeChoice(rawValue: UserDefaults.standard.string(forKey: themeKey) ?? "") ?? .profile
    }

    static var position: DockSide {
        DockSide(rawValue: UserDefaults.standard.string(forKey: positionKey) ?? "") ?? .bottom
    }

    static var customBackground: NSColor {
        NSColor(hex: UserDefaults.standard.string(forKey: customBackgroundKey) ?? defaultCustomBackground)
            ?? NSColor(hex: defaultCustomBackground)!
    }

    static var customText: NSColor {
        NSColor(hex: UserDefaults.standard.string(forKey: customTextKey) ?? defaultCustomText)
            ?? NSColor(hex: defaultCustomText)!
    }

    static var customCursor: NSColor {
        NSColor(hex: UserDefaults.standard.string(forKey: customCursorKey) ?? defaultCustomCursor)
            ?? NSColor(hex: defaultCustomCursor)!
    }

    static var customSelection: NSColor {
        NSColor(hex: UserDefaults.standard.string(forKey: customSelectionKey) ?? defaultCustomSelection)
            ?? NSColor(hex: defaultCustomSelection)!
    }

    /// 0 = follow the Terminal.app profile's font size.
    static var fontSize: CGFloat {
        CGFloat(UserDefaults.standard.double(forKey: fontSizeKey))
    }
}

extension NSColor {
    /// "#RRGGBB" or "#RRGGBBAA".
    convenience init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6 || s.count == 8, let v = UInt64(s, radix: 16) else { return nil }
        let hasAlpha = s.count == 8
        let divisor: CGFloat = 255
        let r = CGFloat((v >> (hasAlpha ? 24 : 16)) & 0xFF) / divisor
        let g = CGFloat((v >> (hasAlpha ? 16 : 8)) & 0xFF) / divisor
        let b = CGFloat((v >> (hasAlpha ? 8 : 0)) & 0xFF) / divisor
        let a = hasAlpha ? CGFloat(v & 0xFF) / divisor : 1
        self.init(srgbRed: r, green: g, blue: b, alpha: a)
    }

    var hexString: String {
        guard let c = usingColorSpace(.sRGB) else { return "#000000" }
        if c.alphaComponent >= 0.999 {
            return String(format: "#%02X%02X%02X",
                          Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
        }
        return String(format: "#%02X%02X%02X%02X",
                      Int(c.redComponent * 255), Int(c.greenComponent * 255),
                      Int(c.blueComponent * 255), Int(c.alphaComponent * 255))
    }
}
