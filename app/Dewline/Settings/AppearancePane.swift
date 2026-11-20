import SwiftUI

struct AppearancePane: View {
    @Bindable var store: ThemeStore

    var body: some View {
        SettingsPage {
            SettingsSection(title: "Theme") {
                HStack(alignment: .top, spacing: 16) {
                    themes("Light", Theme.light, dark: false)
                    themes("Dark", Theme.dark, dark: true)
                }
            }
            SettingsSection(note: "Match system follows macOS between the light theme and the dark one.") {
                SettingsRow(label: "Mode") {
                    TextChoice(label: "Mode", selection: $store.appearance, options: [("Light", .light), ("Dark", .dark), ("Match system", .auto)])
                }
            }
            FontSlots(store: store)
            SettingsSection(title: "The page", note: "Line width is in characters at this size.") {
                SettingsRow(label: "Text size") {
                    KeyStepper(label: "Text size", value: $store.bodySize, range: ThemeStore.bodySizes, step: 1,
                               text: { "\(Int($0)) pt" }, spoken: { "\(Int($0)) points" })
                }
                SettingsRow(label: "Line height") {
                    KeyStepper(label: "Line height", value: $store.lineHeight, range: ThemeStore.lineHeights, step: 0.02,
                               text: { $0.formatted(.number.precision(.fractionLength(2))) })
                }
                SettingsRow(label: "Line width") {
                    KeyStepper(label: "Line width", value: $store.columnWidth, range: ThemeStore.columnWidths, step: 2,
                               text: { "\(Int($0)) ch" }, spoken: { "\(Int($0)) characters" })
                }
            }
            RestoreDefaults {
                let factory = ThemeStore.factory
                store.appearance = factory.appearance
                store.lightTheme = factory.lightTheme
                store.darkTheme = factory.darkTheme
                store.bodyFace = factory.bodyFace
                store.headingFace = factory.headingFace
                store.codeFace = factory.codeFace
                store.bodySize = factory.bodySize
                store.lineHeight = factory.lineHeight
                store.columnWidth = factory.columnWidth
            }
        }
    }

    /// One mode's themes in a row under its name; the two modes side by side put every card in one row.
    private func themes(_ mode: String, _ themes: [Theme], dark: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(mode)
                .font(Station.label)
                .foregroundStyle(Station.color(.ink))
                .accessibilityAddTraits(.isHeader)
            HStack(alignment: .top, spacing: 16) {
                ForEach(themes) { ThemeCard(theme: $0, store: store, dark: dark).frame(maxWidth: .infinity) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A theme as a window in miniature, in its own mode, with its name under it. A 1.5 pt signal ring, 2 pt
/// out, marks the theme its mode uses; the name keeps its weight, so selecting one doesn't shift its line.
private struct ThemeCard: View {
    let theme: Theme
    let store: ThemeStore
    let dark: Bool
    @Environment(\.displayScale) private var scale

    var body: some View {
        let selected = (dark ? store.darkTheme : store.lightTheme) == theme
        let card = RoundedRectangle(cornerRadius: 9, style: .continuous)
        Button {
            if dark { store.darkTheme = theme } else { store.lightTheme = theme }
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                MiniWindow(theme: theme, dark: dark)
                    .aspectRatio(1.55, contentMode: .fit)
                    .clipShape(card)
                    .overlay(card.strokeBorder(Station.stroke, lineWidth: 1 / scale))
                    .padding(3.5)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12.5, style: .continuous)
                            .strokeBorder(selected ? Station.color(.accent) : .clear, lineWidth: 1.5)
                    )
                Text(theme.name)
                    .font(Station.label)
                    .foregroundStyle(Station.color(selected ? .ink : .ink2))
                    .padding(.horizontal, 3.5)
            }
        }
        .buttonStyle(BareButtonStyle(radius: 12.5))
        .help(theme.summary)
        .accessibilityLabel(theme.name)
        .accessibilityHint(theme.summary)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The main window drawn small in a theme's colors: the sidebar on the chrome, a hairline, and the page with a title,
/// two lines, and one outside change underlined in the accent.
private struct MiniWindow: View {
    let theme: Theme
    let dark: Bool

    var body: some View {
        let colors = dark ? theme.darkColors : theme.lightColors
        let titleFont = Station.brand(11, weight: 600)
        Canvas { context, size in
            func color(_ token: Token) -> Color {
                Color(nsColor: colors[token] ?? colors[.ink2]!)
            }
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(color(.paper)))
            let side = CGRect(x: 0, y: 0, width: (size.width * 0.28).rounded(), height: size.height)
            context.fill(Path(side), with: .color(color(.chrome)))
            context.fill(Path(CGRect(x: side.maxX, y: 0, width: 1, height: size.height)), with: .color(color(.rule)))
            for (index, width) in [0.62, 0.44, 0.7].enumerated() {
                let bar = CGRect(x: side.minX + 8, y: 12 + CGFloat(index) * 7, width: (side.width - 16) * width, height: 2)
                context.fill(Path(roundedRect: bar, cornerRadius: 1), with: .color(color(.ink2).opacity(0.55)))
            }
            let page = CGRect(x: side.maxX + 1, y: 0, width: size.width - side.maxX - 1, height: size.height)
            let title = context.resolve(Text("Field notes").font(titleFont).foregroundStyle(color(.heading)))
            context.draw(title, at: CGPoint(x: page.minX + 10, y: page.minY + 12), anchor: .topLeading)
            for (index, width) in [0.72, 0.5].enumerated() {
                let bar = CGRect(x: page.minX + 10, y: page.minY + 32 + CGFloat(index) * 7, width: (page.width - 20) * width, height: 2)
                context.fill(Path(roundedRect: bar, cornerRadius: 1), with: .color(color(.ink2).opacity(0.5)))
            }
            let mark = CGRect(x: page.minX + 10, y: page.minY + 37, width: (page.width - 20) * 0.3, height: 1)
            context.fill(Path(mark), with: .color(color(.accent)))
        }
        .accessibilityHidden(true)
    }
}
