import SwiftUI

/// Settings window content — same pattern as Imperator Dock Folders:
/// grouped Form sections in a real window, controls tinted AppColors.brand.
struct SettingsView: View {
    @AppStorage(AppSettings.themeKey) private var theme = ThemeChoice.profile.rawValue
    @AppStorage(AppSettings.positionKey) private var position = DockSide.bottom.rawValue
    @AppStorage(AppSettings.customBackgroundKey) private var customBackground = AppSettings.defaultCustomBackground
    @AppStorage(AppSettings.customTextKey) private var customText = AppSettings.defaultCustomText
    @AppStorage(AppSettings.customCursorKey) private var customCursor = AppSettings.defaultCustomCursor
    @AppStorage(AppSettings.customSelectionKey) private var customSelection = AppSettings.defaultCustomSelection
    @AppStorage(AppSettings.fontSizeKey) private var fontSize = 0.0

    var body: some View {
        Form {
            Section("Theme") {
                Picker("Theme", selection: $theme) {
                    ForEach(ThemeChoice.allCases) { choice in
                        Text(choice.rawValue).tag(choice.rawValue)
                    }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
            }

            Section("Custom Colors") {
                ColorPicker("Background", selection: colorBinding($customBackground), supportsOpacity: true)
                ColorPicker("Text", selection: colorBinding($customText), supportsOpacity: true)
                ColorPicker("Cursor", selection: colorBinding($customCursor), supportsOpacity: true)
                ColorPicker("Selection", selection: colorBinding($customSelection), supportsOpacity: true)
            }
            .disabled(theme != ThemeChoice.custom.rawValue)

            Section {
                HStack(spacing: 8) {
                    Slider(value: $fontSize, in: 0...24, step: 1)
                    Text(fontSize <= 0 ? "Auto" : "\(Int(fontSize)) pt")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 44, alignment: .trailing)
                }
            } header: {
                Text("Font Size")
            } footer: {
                Text("Auto follows the Terminal.app profile size.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }

            Section("Position") {
                Picker("Position", selection: $position) {
                    ForEach(DockSide.allCases) { s in
                        Text(s.label).tag(s.rawValue)
                    }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
            }
        }
        .formStyle(.grouped)
        .frame(width: 400)
        .padding()
        .tint(AppColors.brand)
    }

    /// Bridge hex-string storage <-> SwiftUI Color for ColorPicker.
    private func colorBinding(_ hex: Binding<String>) -> Binding<Color> {
        Binding<Color>(
            get: { Color(nsColor: NSColor(hex: hex.wrappedValue) ?? .black) },
            set: { hex.wrappedValue = NSColor($0).hexString }
        )
    }
}
