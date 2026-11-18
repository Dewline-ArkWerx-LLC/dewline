import SwiftUI

/// The body, heading and code faces, as sections of Settings > Appearance.
struct FontSlots: View {
    /// Families on this Mac, all and fixed-pitch; read once, for the pickers.
    private static let mac = (all: Faces.installed(monospaced: false), monospaced: Faces.installed(monospaced: true))

    @Bindable var store: ThemeStore
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let colors = scheme == .dark ? store.darkTheme.darkColors : store.lightTheme.lightColors
        let faces = { (sections: [(String, [String])]) -> [(String?, [(String, String)])] in
            sections.filter { !$0.1.isEmpty }.map { ($0.0, $0.1.map { ($0, $0) }) }
        }
        let text = faces([("System", Faces.system), ("Bundled", Faces.bundled), ("This Mac", Self.mac.all)])
        let code = faces([("System", ["SF Mono"]), ("Bundled", ["JetBrains Mono"]), ("This Mac", Self.mac.monospaced)])
        SettingsSection(title: "Faces") {
            SettingsRow(label: "Body") {
                MenuField("Body font", selection: $store.bodyFace, sections: text)
            }
            SettingsRow(label: "Headings") {
                MenuField("Heading font", selection: $store.headingFace, sections: text)
            }
            SettingsRow(label: "Code") {
                MenuField("Code font", selection: $store.codeFace, sections: code)
            }
        }
        SettingsSection(title: "Preview", note: "Code is sized to the body font's x-height. Source mode (⌥⌘U) sets the whole page in the code font.") {
            FontPreview(store: store, colors: colors)
        }
    }
}

/// A heading, a paragraph and a code line set as the editor sets them, on the current theme's paper.
struct FontPreview: View {
    let store: ThemeStore
    let colors: [Token: NSColor]

    private func color(_ token: Token) -> Color {
        Color(nsColor: colors[token]!)
    }

    var body: some View {
        let body = store.bodyFont
        let heading = store.heading(2).font
        let code = store.codeFont(size: body.pointSize * body.xHeight / store.codeFont(size: body.pointSize).xHeight)
        let excerpt = Excerpt.open
        var paragraph = AttributedString(excerpt.paragraph)
        for link in excerpt.links {
            guard let range = Range(link, in: paragraph) else { continue }
            paragraph[range].swiftUI.foregroundColor = color(.link)
            paragraph[range].swiftUI.underlineStyle = .single
        }
        return VStack(alignment: .leading, spacing: 10) {
            Text(excerpt.heading)
                .font(Font(heading))
                .lineLimit(1)
                .foregroundStyle(color(.heading))
            Text(paragraph)
                .font(Font(body))
                .lineSpacing(max(store.bodyLineHeight - (body.ascender - body.descender + body.leading), 0))
                .lineLimit(4)
                .foregroundStyle(color(.ink))
            Text(excerpt.code)
                .font(Font(code))
                .lineLimit(1)
                .foregroundStyle(color(.ink))
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(color(.codeBackground), in: .rect(cornerRadius: 4))
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color(.paper), in: .rect(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Station.color(.hairline), lineWidth: 1))
        .accessibilityElement(children: .combine)
    }
}
