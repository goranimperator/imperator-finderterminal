import SwiftUI
import ServiceManagement

// MARK: - Brandbook 2.6: AppColors

enum AppColors {
    static let brand = Color(red: 0xa0/255.0, green: 0x18/255.0, blue: 0x18/255.0)
    static let brandFaded = brand.opacity(0.25)
    static let accent = Color(red: 0.43, green: 0.05, blue: 0.05)
    static let badgeRed = Color(red: 0xD9/255.0, green: 0x33/255.0, blue: 0x33/255.0)
    static let error = Color(red: 0.9, green: 0.3, blue: 0.3)

    static let brandNS = NSColor(red: 0xa0/255.0, green: 0x18/255.0, blue: 0x18/255.0, alpha: 1.0)
    static let backgroundNS = NSColor(red: 0.04, green: 0.04, blue: 0.04, alpha: 1)
}

// MARK: - Brandbook 2.7: View extensions

extension View {
    func cursor(_ cursor: NSCursor) -> some View {
        onHover { inside in
            if inside { cursor.push() } else { NSCursor.pop() }
        }
    }

    func expandTapTarget() -> some View {
        contentShape(Rectangle())
    }
}

// MARK: - Brandbook 7.1: HoverButton

struct HoverButton<Label: View>: View {
    let action: () -> Void
    @ViewBuilder let label: () -> Label
    @State private var isHovered = false

    var body: some View {
        Button(action: action) { label() }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)
            .opacity(isHovered ? 1.0 : 0.45)
            .animation(.easeInOut(duration: 0.2), value: isHovered)
            .onHover { isHovered = $0 }
    }
}

// MARK: - Brandbook 7.2: Launch at Login toggle

struct LaunchAtLoginToggle: View {
    @State private var isEnabled = SMAppService.mainApp.status == .enabled
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 6) {
            Text("Open at Login")
                .font(.caption)
            Toggle("", isOn: $isEnabled)
                .toggleStyle(.switch)
                .scaleEffect(0.55)
                .frame(width: 36, height: 20)
                .tint(AppColors.brand)
                .labelsHidden()
                .onChange(of: isEnabled) { _, newValue in
                    do {
                        if newValue { try SMAppService.mainApp.register() }
                        else { try SMAppService.mainApp.unregister() }
                    } catch {
                        isEnabled = SMAppService.mainApp.status == .enabled
                    }
                }
        }
        .opacity(isHovered ? 1.0 : 0.45)
        .animation(.easeInOut(duration: 0.2), value: isHovered)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Brandbook 18.3: Popover content

struct PopoverContentView: View {
    let onToggleTerminal: () -> Void
    let onShowAbout: () -> Void
    let onShowSettings: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // HEADER -- menu bar icon + name (Goran's spec; overrides brandbook 9.1)
            HStack(spacing: 8) {
                Image(systemName: "apple.terminal")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 16, height: 16)   // same as Free Games' header sigil
                Text("Imperator FinderTerminal")
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            // CONTENT
            VStack(alignment: .leading, spacing: 16) {
                ShortcutSettings()

                VStack(alignment: .leading, spacing: 8) {
                    sectionHeader("POSITION")
                    PositionRadios()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)

            Divider()

            // FOOTER -- LaunchAtLogin LEFT, actions RIGHT (9.2; About next to Quit, 10.1)
            HStack {
                LaunchAtLoginToggle()
                Spacer()
                HoverButton(action: onShowSettings) {
                    HStack(spacing: 4) {
                        Image(systemName: "gear")
                        Text("Settings")
                    }
                    .font(.caption)
                }
                HoverButton(action: onShowAbout) {
                    Text("About").font(.caption)
                }
                HoverButton(action: { NSApp.terminate(nil) }) {
                    Text("Quit").font(.caption)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        // Brandbook 5.1: standard popover width 340pt, height content-driven.
        .frame(width: 340)
        .fixedSize(horizontal: false, vertical: true)
        .background(Color.black.opacity(0.15))
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
    }
}

// MARK: - Shared settings controls (popover + Settings window)

/// Current shortcut row (read-only badge) + "Change Keyboard Shortcut" recorder.
struct ShortcutSettings: View {
    @AppStorage(AppSettings.hotkeyKeyCodeKey) private var hotkeyCode = 10
    @AppStorage(AppSettings.hotkeyModifiersKey) private var hotkeyMods = 256 | 2048
    @State private var isRecording = false
    @State private var recordMonitor: Any?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Keyboard Shortcut")
                    .font(.system(size: 13))
                Spacer()
                shortcutBadge(isRecording
                              ? "Type shortcut…"
                              : Hotkey.display(keyCode: UInt32(hotkeyCode),
                                               modifiers: UInt32(hotkeyMods)))
            }

            // Record a new one: click, then press the combo (Esc cancels).
            HoverButton(action: { isRecording ? stopRecording() : startRecording() }) {
                HStack(spacing: 6) {
                    Image(systemName: "square.and.pencil")
                    Text(isRecording ? "Press keys… (Esc to cancel)" : "Change Keyboard Shortcut")
                }
                .font(.system(size: 12))
                .foregroundStyle(isRecording ? AppColors.brand : Color.primary)
                .expandTapTarget()
            }
            .cursor(.pointingHand)
        }
        // The host may close mid-recording — release the key monitor, or it
        // keeps swallowing every keyDown in the app.
        .onDisappear { stopRecording() }
    }

    private func shortcutBadge(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13).monospaced())
            .tracking(text.count <= 4 ? 3 : 0)
            .foregroundStyle(.secondary)
            .padding(.leading, 9)
            .padding(.trailing, 6)
            .padding(.vertical, 5)
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .stroke(Color.secondary.opacity(0.4), lineWidth: 0.5)
            )
    }

    private func startRecording() {
        isRecording = true
        recordMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 {              // Escape cancels
                stopRecording()
                return nil
            }
            let mods = Hotkey.carbonModifiers(from: event.modifierFlags)
            guard mods != 0 else { return nil }   // require at least one modifier
            hotkeyCode = Int(event.keyCode)
            hotkeyMods = Int(mods)
            stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        isRecording = false
        if let m = recordMonitor { NSEvent.removeMonitor(m) }
        recordMonitor = nil
    }
}

/// Warn on window close: always, or only with a live process.
struct AlertsRadios: View {
    @AppStorage(AppSettings.alertModeKey) private var alertMode = "always"

    var body: some View {
        HStack(spacing: 0) {
            RadioButton(label: "Always on", selected: alertMode == "always") { alertMode = "always" }
                .frame(maxWidth: .infinity, alignment: .leading)
            RadioButton(label: "Only running processes", selected: alertMode == "busy") { alertMode = "busy" }
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Who has the keyboard when the terminal opens.
struct FocusRadios: View {
    @AppStorage(AppSettings.focusKey) private var focus = "terminal"

    var body: some View {
        HStack(spacing: 0) {
            RadioButton(label: "Terminal", selected: focus != "finder") { focus = "terminal" }
                .frame(maxWidth: .infinity, alignment: .leading)
            RadioButton(label: "Finder", selected: focus == "finder") { focus = "finder" }
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// One row, four equal-width dock-side choices.
struct PositionRadios: View {
    @AppStorage(AppSettings.positionKey) private var position = DockSide.bottom.rawValue

    var body: some View {
        HStack(spacing: 0) {
            ForEach(DockSide.allCases) { s in
                RadioButton(label: s.label, selected: position == s.rawValue) { position = s.rawValue }
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

struct RadioButton: View {
    let label: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 11))
                    .foregroundStyle(selected ? AppColors.brand : Color.secondary)
                Text(label)
                    .font(.system(size: 11))
            }
            .expandTapTarget()
        }
        .buttonStyle(.plain)
        .cursor(.pointingHand)
    }
}

// MARK: - Brandbook 10.3: About view

struct AboutView: View {
    @State private var linkHovered = false

    private var version: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "Version \(v) (Build \(b))"
    }

    private var copyright: String {
        let year = Calendar.current.component(.year, from: Date())
        return "© 1986-\(year) Goran Imperator"
    }

    var body: some View {
        VStack(alignment: .center, spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 64, height: 64)
            Text("Imperator FinderTerminal")
                .font(.headline)
            Text(version)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(copyright)
                .font(.caption)
                .foregroundStyle(.tertiary)
            Text("goranimperator.com")
                .font(.caption)
                .foregroundStyle(AppColors.brand)
                .underline(linkHovered)
                .onHover { linkHovered = $0 }
                .cursor(.pointingHand)
                .onTapGesture {
                    NSWorkspace.shared.open(URL(string: "https://www.goranimperator.com")!)
                }
        }
        .padding(24)
        .frame(width: 300, height: 260)
    }
}
