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

/// Runtime state shared from AppDelegate so the popover's switch reflects
/// whether the terminal is currently open.
final class TerminalState: ObservableObject {
    @Published var isOpen = false
}

struct PopoverContentView: View {
    @ObservedObject var state: TerminalState
    let onToggleTerminal: () -> Void
    let onShowAbout: () -> Void
    let onShowSettings: () -> Void

    @AppStorage(AppSettings.positionKey) private var position = DockSide.bottom.rawValue

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
                HStack {
                    // Brandbook 7.2 switch reflecting the terminal's open state.
                    Toggle("", isOn: Binding(get: { state.isOpen }, set: { _ in onToggleTerminal() }))
                        .toggleStyle(.switch)
                        .scaleEffect(0.55)
                        .frame(width: 36, height: 20)
                        .tint(AppColors.brand)
                        .labelsHidden()
                    HoverButton(action: onToggleTerminal) {
                        HStack {
                            Text("Toggle FinderTerminal")
                                .font(.system(size: 13))
                            Spacer()
                            Text("⌘⌥§")
                                .font(.system(size: 13).monospaced())
                                .tracking(3)
                                .foregroundStyle(.secondary)
                                .padding(.leading, 9)
                                .padding(.trailing, 6)   // tracking adds space after the last glyph
                                .padding(.vertical, 5)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 5)
                                        .stroke(Color.secondary.opacity(0.4), lineWidth: 0.5)
                                )
                        }
                        .expandTapTarget()
                    }
                    .cursor(.pointingHand)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("POSITION")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    // One row, four equal-width radio choices.
                    HStack(spacing: 0) {
                        ForEach(DockSide.allCases) { s in
                            positionRadio(s)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
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

    private func positionRadio(_ s: DockSide) -> some View {
        let selected = position == s.rawValue
        return Button {
            position = s.rawValue
        } label: {
            HStack(spacing: 4) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 11))
                    .foregroundStyle(selected ? AppColors.brand : Color.secondary)
                Text(s.label)
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
