import AppKit

/// Which edge of the Finder window the terminal docks to.
enum DockSide: String, CaseIterable, Identifiable {
    case top, right, bottom, left
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
    var isVertical: Bool { self == .left || self == .right }
}

/// Built-in theme palettes: the ten classic Terminal.app profiles plus a set of
/// popular dark themes. Values: (background, text, cursor, selection).
enum BuiltInTheme: String, CaseIterable, Identifiable {
    case imperatorRed = "Imperator Red"
    case imperatorGreen = "Imperator Green"
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
    case dracula = "Dracula"
    case solarizedDark = "Solarized Dark"
    case monokai = "Monokai"
    case nord = "Nord"
    case oneDark = "One Dark"
    case gruvboxDark = "Gruvbox Dark"
    case tokyoNight = "Tokyo Night"
    var id: String { rawValue }

    var palette: (bg: String, fg: String, cursor: String, selection: String) {
        switch self {
        case .imperatorRed: ("#000000", "#D0342C", "#D0342C", "#264F78")
        case .imperatorGreen: ("#000000E5", "#28FE14", "#38FE27", "#0B2EEDA5")
        case .basic: ("#FFFFFF", "#000000", "#7F7F7F", "#A5CDFF")
        case .grass: ("#13773D", "#FFF0A5", "#8C2800", "#B64926")
        case .homebrew: ("#000000", "#28FE14", "#38FF12", "#083905")
        case .manPage: ("#FEF49C", "#000000", "#7F7F7F", "#A5CDFF")
        case .novel: ("#DFDBC3", "#3B2322", "#73635A", "#A4A390")
        case .ocean: ("#224FBC", "#FFFFFF", "#7F7F7F", "#216DFF")
        case .pro: ("#000000", "#F2F2F2", "#4D4D4D", "#414141")
        case .redSands: ("#7A251E", "#D7C9A7", "#FFFFFF", "#A4A390")
        case .silverAerogel: ("#929292", "#000000", "#939393", "#C1DDFF")
        case .solidColors: ("#FFFFFF", "#000000", "#7F7F7F", "#A5CDFF")
        case .dracula: ("#282A36", "#F8F8F2", "#F8F8F2", "#44475A")
        case .solarizedDark: ("#002B36", "#839496", "#839496", "#073642")
        case .monokai: ("#272822", "#F8F8F2", "#F8F8F2", "#49483E")
        case .nord: ("#2E3440", "#D8DEE9", "#D8DEE9", "#434C5E")
        case .oneDark: ("#282C34", "#ABB2BF", "#528BFF", "#3E4451")
        case .gruvboxDark: ("#282828", "#EBDBB2", "#EBDBB2", "#504945")
        case .tokyoNight: ("#1A1B26", "#A9B1D6", "#C0CAF5", "#33467C")
        }
    }
}

/// A user-created theme, persisted as JSON in UserDefaults.
struct CustomTheme: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var background: String
    var text: String
    var cursor: String
    var selection: String

    static func fresh(number: Int) -> CustomTheme {
        CustomTheme(name: "My Theme \(number)",
                    background: AppSettings.defaultCustomBackground,
                    text: AppSettings.defaultCustomText,
                    cursor: AppSettings.defaultCustomCursor,
                    selection: AppSettings.defaultCustomSelection)
    }
}

/// What the terminal theme follows. Persisted as a string:
/// "profile" | "preset:<BuiltInTheme raw>" | "custom:<uuid>".
enum ThemeSelection: Equatable {
    case profile
    case preset(BuiltInTheme)
    case custom(UUID)

    var storageValue: String {
        switch self {
        case .profile: "profile"
        case .preset(let t): "preset:\(t.rawValue)"
        case .custom(let id): "custom:\(id.uuidString)"
        }
    }

    static func parse(_ s: String?) -> ThemeSelection {
        guard let s else { return .profile }
        if s == "profile" { return .profile }
        if s.hasPrefix("preset:"), let t = BuiltInTheme(rawValue: String(s.dropFirst(7))) {
            return .preset(t)
        }
        if s.hasPrefix("custom:"), let id = UUID(uuidString: String(s.dropFirst(7))) {
            return .custom(id)
        }
        // Legacy values from the first settings version ("Terminal.app Profile",
        // "Pro", "Custom", ...) — migrate transparently.
        if s == "Custom" { return .profile }
        if let t = BuiltInTheme(rawValue: s) { return .preset(t) }
        return .profile
    }
}

/// UserDefaults-backed app settings. Keys are shared with SwiftUI @AppStorage.
enum AppSettings {
    static let themeKey = "ft.theme"
    static let positionKey = "ft.position"
    static let customThemesKey = "ft.customThemes"
    static let fontSizeKey = "ft.fontSize"
    static let hotkeyKeyCodeKey = "ft.hotkeyKeyCode"
    static let hotkeyModifiersKey = "ft.hotkeyModifiers"
    static let alertModeKey = "ft.alertMode"

    /// True (default) = warn on every close of a window with a terminal;
    /// false ("busy") = warn only when a process is running.
    static var alertAlways: Bool {
        UserDefaults.standard.string(forKey: alertModeKey) != "busy"
    }

    /// Carbon key code + Carbon modifier mask for the toggle hotkey.
    /// Default: Command-Option-Section (kVK_ISO_Section = 10, cmd|opt = 256|2048).
    static var hotkey: (keyCode: UInt32, modifiers: UInt32) {
        let d = UserDefaults.standard
        let code = d.object(forKey: hotkeyKeyCodeKey) as? Int ?? 10
        let mods = d.object(forKey: hotkeyModifiersKey) as? Int ?? (256 | 2048)
        return (UInt32(code), UInt32(mods))
    }

    // Defaults for a new custom theme: the Imperator Red palette.
    static let defaultCustomBackground = "#000000"
    static let defaultCustomText = "#D0342C"
    static let defaultCustomCursor = "#D0342C"
    static let defaultCustomSelection = "#264F78"

    static var themeSelection: ThemeSelection {
        ThemeSelection.parse(UserDefaults.standard.string(forKey: themeKey))
    }

    static var position: DockSide {
        DockSide(rawValue: UserDefaults.standard.string(forKey: positionKey) ?? "") ?? .bottom
    }

    /// 0 = follow the Terminal.app profile's font size.
    static var fontSize: CGFloat {
        CGFloat(UserDefaults.standard.double(forKey: fontSizeKey))
    }

    static var customThemes: [CustomTheme] {
        get {
            guard let data = UserDefaults.standard.data(forKey: customThemesKey),
                  let themes = try? JSONDecoder().decode([CustomTheme].self, from: data)
            else { return [] }
            return themes
        }
        set {
            UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: customThemesKey)
        }
    }

    static func customTheme(id: UUID) -> CustomTheme? {
        customThemes.first { $0.id == id }
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
