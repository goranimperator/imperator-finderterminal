import SwiftUI

/// Settings window content — grouped Form in a real window (Dock Folders pattern).
/// Collapsible sections follow brandbook 7.4: button-based accordion headers with
/// a rotating chevron, 11pt semibold uppercase labels.
struct SettingsView: View {
    @AppStorage(AppSettings.themeKey) private var themeSelection = ThemeSelection.profile.storageValue
    @AppStorage(AppSettings.positionKey) private var position = DockSide.bottom.rawValue
    @AppStorage(AppSettings.fontSizeKey) private var fontSize = 0.0
    @State private var customThemes = AppSettings.customThemes
    @State private var themesExpanded = false
    @State private var customExpanded = false
    @State private var expandedTheme: UUID?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                accordion("Theme", expanded: $themesExpanded) {
                    VStack(spacing: 2) {
                        themeRow("Terminal.app Profile", ThemeSelection.profile.storageValue)
                        ForEach(BuiltInTheme.allCases) { t in
                            themeRow(t.rawValue, ThemeSelection.preset(t).storageValue)
                        }
                    }
                }

                Divider()

                accordion("Custom Themes", expanded: $customExpanded) {
                    if customThemes.isEmpty {
                        Text("No custom themes yet.")
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                    }
                    ForEach($customThemes) { $theme in
                        customThemeRow($theme)
                    }
                    HoverButton(action: addTheme) {
                        HStack(spacing: 4) {
                            Image(systemName: "plus.circle")
                            Text(customThemes.isEmpty ? "Create Custom Theme" : "Add Theme")
                        }
                        .font(.system(size: 12))
                    }
                    .cursor(.pointingHand)
                    .padding(.top, 2)
                }

                Divider()

                staticSection("Font Size") {
                    HStack(spacing: 8) {
                        Slider(value: $fontSize, in: 0...24, step: 1)
                            .frame(maxWidth: 240)
                        Text(fontSize <= 0 ? "Auto" : "\(Int(fontSize)) pt")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 44, alignment: .trailing)
                    }
                    Text("Auto follows the Terminal.app profile size.")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }

                Divider()

                // Position is independent of theme: it applies no matter what.
                staticSection("Position") {
                    HStack(spacing: 0) {
                        ForEach(DockSide.allCases) { s in
                            positionRadio(s)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .frame(maxWidth: 340)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 360, minHeight: 260)
        .tint(AppColors.brand)
        .onChange(of: customThemes) { _, newValue in
            AppSettings.customThemes = newValue
        }
    }

    // MARK: Theme list row (brandbook 7.5: radius 6, brand hover background)

    private func themeRow(_ label: String, _ value: String) -> some View {
        let selected = themeSelection == value
        return ThemeRowButton(label: label, selected: selected) {
            themeSelection = value
        }
    }

    // MARK: Custom theme row (accordion per theme, edit + delete)

    @ViewBuilder
    private func customThemeRow(_ theme: Binding<CustomTheme>) -> some View {
        let t = theme.wrappedValue
        let isExpanded = expandedTheme == t.id
        let isActive = themeSelection == ThemeSelection.custom(t.id).storageValue
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        expandedTheme = isExpanded ? nil : t.id
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .medium))
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        Text(t.name)
                            .font(.system(size: 13))
                        if isActive {
                            Text("ACTIVE")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(AppColors.brand)
                        }
                    }
                    .expandTapTarget()
                }
                .buttonStyle(.plain)
                .cursor(.pointingHand)
                Spacer()
                if !isActive {
                    HoverButton(action: { themeSelection = ThemeSelection.custom(t.id).storageValue }) {
                        Text("Use").font(.caption)
                    }
                    .cursor(.pointingHand)
                }
                HoverButton(action: { deleteTheme(t.id) }) {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .foregroundStyle(.red.opacity(0.7))
                }
                .cursor(.pointingHand)
            }
            if isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Name", text: theme.name)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 220)
                    colorRow("Background", theme.background)
                    colorRow("Text", theme.text)
                    colorRow("Cursor", theme.cursor)
                    colorRow("Selection", theme.selection)
                }
                .padding(.leading, 21)
                .padding(.bottom, 4)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.04)))
    }

    private func addTheme() {
        let theme = CustomTheme.fresh(number: customThemes.count + 1)
        customThemes.append(theme)
        expandedTheme = theme.id
        themeSelection = ThemeSelection.custom(theme.id).storageValue
    }

    private func deleteTheme(_ id: UUID) {
        customThemes.removeAll { $0.id == id }
        if themeSelection == "custom:\(id.uuidString)" {
            themeSelection = ThemeSelection.profile.storageValue
        }
        if expandedTheme == id { expandedTheme = nil }
    }

    /// Plain section: brandbook header (11pt semibold uppercase .secondary), no chevron.
    @ViewBuilder
    private func staticSection(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }

    // MARK: Brandbook 7.4 accordion

    @ViewBuilder
    private func accordion(_ title: String, expanded: Binding<Bool>,
                           @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { expanded.wrappedValue.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .medium))
                        .rotationEffect(.degrees(expanded.wrappedValue ? 90 : 0))
                    Text(title.uppercased())
                        .font(.system(size: 11, weight: .semibold))
                    Spacer()
                }
                .foregroundStyle(.secondary)
                .expandTapTarget()
            }
            .buttonStyle(.plain)
            .cursor(.pointingHand)
            if expanded.wrappedValue {
                content()
            }
        }
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

    private func colorRow(_ label: String, _ hex: Binding<String>) -> some View {
        HStack {
            Text(label).font(.system(size: 13))
            Spacer()
            ColorPicker("", selection: colorBinding(hex), supportsOpacity: true)
                .labelsHidden()
        }
        .frame(maxWidth: 220)
    }

    /// Bridge hex-string storage <-> SwiftUI Color for ColorPicker.
    private func colorBinding(_ hex: Binding<String>) -> Binding<Color> {
        Binding<Color>(
            get: { Color(nsColor: NSColor(hex: hex.wrappedValue) ?? .black) },
            set: { hex.wrappedValue = NSColor($0).hexString }
        )
    }
}

/// One selectable theme row: brandbook 7.5 — 6pt corner radius, brand-tinted
/// hover background, checkmark on the active row.
private struct ThemeRowButton: View {
    let label: String
    let selected: Bool
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack {
                Text(label)
                    .font(.system(size: 13))
                Spacer()
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(AppColors.brand)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(hovered ? AppColors.brand.opacity(0.1) : Color.clear)
            )
            .expandTapTarget()
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .cursor(.pointingHand)
    }
}
