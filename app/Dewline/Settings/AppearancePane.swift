import SwiftUI

struct AppearancePane: View {
    @Bindable var store: ThemeStore

    var body: some View {
        SettingsForm(restore: { Self.restore(store) }) {
            Section("Theme") {
                HStack(alignment: .top, spacing: 16) {
                    themes("Light", Theme.light, dark: false)
                    themes("Dark", Theme.dark, dark: true)
                }
            }
            Section {
                Picker("Mode", selection: $store.appearance) {
                    Text("Light").tag(ThemeStore.Appearance.light)
                    Text("Dark").tag(ThemeStore.Appearance.dark)
                    Text("Match system").tag(ThemeStore.Appearance.auto)
                }
            } footer: {
                Text("Match system follows macOS between the light theme and the dark one.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            FontSlots(store: store)
            Section {
                stepper("Text size", $store.bodySize, in: ThemeStore.bodySizes, step: 1, text: "\(Int(store.bodySize)) pt",
                        spoken: "\(Int(store.bodySize)) points")
                LabeledContent("Line height") {
                    let text = store.lineHeight.formatted(.number.precision(.fractionLength(2)))
                    HStack {
                        Text(text)
                            .monospacedDigit()
                        Slider(value: Binding { store.lineHeight } set: { store.lineHeight = ($0 * 100).rounded() / 100 },
                               in: ThemeStore.lineHeights, step: 0.05) { Text("Line height") }
                            .labelsHidden()
                            .frame(maxWidth: 200)
                            .accessibilityValue(text)
                    }
                }
                stepper("Line width", $store.columnWidth, in: ThemeStore.columnWidths, step: 2, text: "\(Int(store.columnWidth)) ch",
                        spoken: "\(Int(store.columnWidth)) characters")
            } header: {
                Text("The page")
            } footer: {
                Text("Line width is in characters at this size.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// Puts this pane's settings, and no others, back as a fresh install has them.
    static func restore(_ store: ThemeStore) {
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

    /// The value, then a stepper that moves it by `step` within `range`, rounded to hundredths so steps of 0.02 never drift.
    private func stepper(_ label: String, _ value: Binding<Double>, in range: ClosedRange<Double>, step: Double, text: String,
                         spoken: String? = nil) -> some View {
        LabeledContent(label) {
            HStack {
                Text(text)
                    .monospacedDigit()
                Stepper(label, value: Binding { value.wrappedValue } set: { value.wrappedValue = ($0 * 100).rounded() / 100 },
                        in: range, step: step)
                    .labelsHidden()
                    .accessibilityValue(spoken ?? text)
            }
        }
    }

    /// One mode's themes in a row under its name; the two modes side by side put every card in one row.
    private func themes(_ mode: String, _ themes: [Theme], dark: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(mode)
                .accessibilityAddTraits(.isHeader)
            HStack(alignment: .top, spacing: 16) {
                ForEach(themes) { ThemeCard(theme: $0, store: store, dark: dark).frame(maxWidth: .infinity) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A theme as a window in miniature, in its own mode, with its name under it. A 1.5 pt accent ring, 2 pt
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
                    .overlay(card.strokeBorder(.separator, lineWidth: 1 / scale))
                    .padding(3.5)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12.5, style: .continuous)
                            .strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 1.5)
                    )
                Text(theme.name)
                    .foregroundStyle(selected ? .primary : .secondary)
                    .padding(.horizontal, 3.5)
            }
        }
        .buttonStyle(.plain)
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
        let titleFont = Font(Chrome.brand(11, weight: 600))
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
