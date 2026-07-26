import SwiftUI

/// Settings window content — grouped Form in a real window (Dock Folders pattern).
/// Collapsible sections follow brandbook 7.4: button-based accordion headers with
/// a rotating chevron, 11pt semibold uppercase labels.
struct SettingsView: View {
    /// Reports the content's natural height so the window can size itself to it
    /// exactly — no guessed constant to update every time a row is added, and no
    /// scrollbar until the accordions expand past the screen.
    var onContentHeight: (CGFloat) -> Void = { _ in }

    @AppStorage(AppSettings.themeKey) private var themeSelection = ThemeSelection.profile.storageValue
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

                ShortcutSettings()
                    .frame(maxWidth: 340)

                Divider()

                staticSection("Font Size") {
                    HStack(spacing: 8) {
                        SettingsSlider(value: $fontSize, range: 0...24, step: 1)
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
                    PositionRadios()
                        .frame(maxWidth: 340)
                }

                Divider()

                staticSection("Alerts") {
                    AlertsRadios()
                        .frame(maxWidth: 340)
                }

                Divider()

                staticSection("Focus on open") {
                    FocusRadios()
                        .frame(maxWidth: 340)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(GeometryReader { geo in
                Color.clear.preference(key: ContentHeightKey.self, value: geo.size.height)
            })
        }
        .frame(minWidth: 360, minHeight: 260)
        .tint(AppColors.brand)
        .onPreferenceChange(ContentHeightKey.self) { height in
            if height > 0 { onContentHeight(height) }
        }
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
                    Text(title.uppercased())
                        .font(.system(size: 11, weight: .semibold))
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .medium))
                        .rotationEffect(.degrees(expanded.wrappedValue ? 180 : 0))
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

/// Brandbook 7.3 slider: 4pt capsule track, brand fill, 14pt knob (brand red —
/// Goran's spec), 20pt container, drag anywhere on the track.
private struct SettingsSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double

    var body: some View {
        GeometryReader { geo in
            let frac = (value - range.lowerBound) / (range.upperBound - range.lowerBound)
            let knobX = frac * (geo.size.width - 14)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.gray.opacity(0.3))
                    .frame(height: 4)
                Capsule()
                    .fill(AppColors.brand)
                    .frame(width: knobX + 7, height: 4)
                Circle()
                    .fill(AppColors.brand)
                    .frame(width: 14, height: 14)
                    .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
                    .offset(x: knobX)
            }
            .frame(height: 20)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                let f = min(max(0, g.location.x / geo.size.width), 1)
                let raw = range.lowerBound + f * (range.upperBound - range.lowerBound)
                value = (raw / step).rounded() * step
            })
        }
        .frame(height: 20)
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

/// Carries the settings content's natural height out to the window.
private struct ContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
