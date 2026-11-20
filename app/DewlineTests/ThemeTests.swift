import AppKit
import Testing
@testable import Dewline

struct ThemeTests {
    /// Gamma-encoded components in the color's own space, sRGB or Display P3.
    private func components(_ color: NSColor) -> [Double] {
        [color.redComponent, color.greenComponent, color.blueComponent].map(Double.init)
    }

    @Test func oklchConvertsToSRGBAndDisplayP3() {
        // References computed through CIE XYZ with the CSS Color 4 matrices.
        let srgb: [(OKLCH, [Double])] = [
            (OKLCH(l: 1, c: 0, h: 0), [1, 1, 1]),
            (OKLCH(l: 0, c: 0, h: 0), [0, 0, 0]),
            (OKLCH(l: 0.6279553606, c: 0.2576833077, h: 29.2338851923), [1, 0, 0]),
            (OKLCH(l: 0.50, c: 0.20, h: 266), [0.176436, 0.329970, 0.826868]),
            (OKLCH(l: 0.80, c: 0.15, h: 155), [0.378526, 0.853859, 0.573974]),
        ]
        for (oklch, expected) in srgb {
            let color = oklch.color
            #expect(color.colorSpace == .sRGB, "\(oklch)")
            #expect(zip(components(color), expected).allSatisfy { abs($0 - $1) < 0.0005 }, "\(oklch): \(components(color))")
        }
        let wide = OKLCH(l: 0.65, c: 0.22, h: 145).color
        #expect(wide.colorSpace == .displayP3)
        #expect(zip(components(wide), [0.271949, 0.675031, 0.229157]).allSatisfy { abs($0 - $1) < 0.0005 }, "\(components(wide))")
    }

    @Test func everyThemeDefinesEveryToken() {
        #expect(Theme.all.map(\.name) == ["Tidewater", "Onionskin", "Nightwatch", "Carbon"])
        for theme in Theme.all {
            for (appearance, tokens) in [("light", theme.light), ("dark", theme.dark)] {
                for token in Token.required {
                    #expect(tokens[token] != nil, "\(theme.name) \(appearance) has no \(token)")
                }
            }
            #expect(Set(theme.light.keys) == Set(theme.dark.keys), "\(theme.name)")
            #expect(Set(theme.lightColors.keys) == Set(theme.light.keys) && Set(theme.darkColors.keys) == Set(theme.dark.keys))
        }
    }

    @Test func textMeetsContrastInEveryVariant() {
        for theme in Theme.all {
            for (dark, authored) in [(false, theme.light), (true, theme.dark)] {
                for (variant, tokens) in [("authored", authored), ("increased", Theme.increased(authored, dark: dark))] {
                    let paper = tokens[.paper]!
                    let label = "\(theme.name) \(dark ? "dark" : "light") \(variant)"
                    for token in [Token.ink, .ink2, .heading, .link] {
                        #expect(tokens[token]!.contrast(with: paper) >= 4.5, "\(label) \(token)")
                    }
                    #expect(tokens[.syntax]!.contrast(with: paper) >= 3, "\(label) syntax")
                    #expect(tokens[.accent]!.contrast(with: paper) >= 3, "\(label) accent")
                    #expect(tokens[.ink]!.contrast(with: tokens[.selection]!) >= 4.5, "\(label) ink on selection")
                }
            }
        }
    }

    @Test func everyThemeReadsAtWCAGLevels() {
        for theme in Theme.all {
            for (dark, tokens) in [(false, theme.light), (true, theme.dark)] {
                let label = "\(theme.name) \(dark ? "dark" : "light")"
                for ground in [Token.paper, .chrome] {
                    for text in [Token.ink, .ink2, .gitModified] {
                        #expect(tokens[text]!.contrast(with: tokens[ground]!) >= 4.5, "\(label) \(text) on \(ground)")
                    }
                    for glyph in [Token.ink3, .cursor, .writerClaude, .writerCodex, .writerCursor, .writerGemini, .writerCopilot, .writerApp] {
                        #expect(tokens[glyph]!.contrast(with: tokens[ground]!) >= 3, "\(label) \(glyph) on \(ground)")
                    }
                }
                #expect(tokens[.accent] == (dark ? Brand.accent.dark : Brand.accent.light), "\(label)")
                // On a dark page the writers' inks keep their hue and read as text.
                for writer in [Token.writerClaude, .writerCodex, .writerCursor, .writerGemini, .writerCopilot] where dark {
                    #expect(tokens[writer]!.contrast(with: tokens[.paper]!) >= 4.5 && tokens[writer]!.c >= 0.12, "\(label) \(writer)")
                }
            }
        }
    }

    /// Code tokens sit on one band against the paper: text contrast on the paper and the code background, and far enough
    /// from each other and from the ink to tell apart.
    @Test func codeTokensReadAndStandApart() {
        func distance(_ a: OKLCH, _ b: OKLCH) -> Double {
            let (ha, hb) = (a.h * .pi / 180, b.h * .pi / 180)
            let (da, db) = (a.c * cos(ha) - b.c * cos(hb), a.c * sin(ha) - b.c * sin(hb))
            return ((a.l - b.l) * (a.l - b.l) + da * da + db * db).squareRoot()
        }
        for theme in Theme.all {
            for (dark, tokens) in [(false, theme.light), (true, theme.dark)] {
                let label = "\(theme.name) \(dark ? "dark" : "light")"
                let roles = [Token.ink, .codeKeyword, .codeString, .codeNumber, .codeType, .codeFunction, .codeComment]
                for token in roles {
                    for ground in [Token.paper, .codeBackground] {
                        #expect(tokens[token]!.contrast(with: tokens[ground]!) >= 4.5, "\(label) \(token) on \(ground)")
                    }
                }
                for (index, a) in roles.enumerated() {
                    for b in roles[(index + 1)...] {
                        #expect(distance(tokens[a]!, tokens[b]!) >= 0.09, "\(label) \(a) and \(b)")
                    }
                }
                #expect(tokens[.codeKeyword]!.h == tokens[.accent]!.h, "\(label)")
            }
        }
    }

    /// The heading ladder steps by 1.25 from the body in whole points: 31, 25, 20, then the body size.
    @MainActor @Test func headingsStepByAQuarter() throws {
        let suite = "dev.arkwerx.dewline.tests.themes.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ThemeStore(defaults: defaults)
        #expect(store.bodySize == 16)
        #expect((1...4).map { store.heading($0).font.pointSize } == [31, 25, 20, 16])
    }

    @Test func mixingInOKLabKeepsGraysGray() {
        let gray = OKLCH(l: 0.2, c: 0, h: 0).mixed(with: OKLCH(l: 0.8, c: 0, h: 0), by: 0.25)
        #expect(abs(gray.l - 0.35) < 1e-9 && gray.c == 0)
    }

    @MainActor @Test func namedWritersMarkInTheirOwnInk() {
        let store = ThemeStore.shared
        let inks = [Writer.claude, .codex, .cursor, .gemini, .copilot, .git, .unknown].map { store.writerColor($0) }
        #expect(Set(inks).count == inks.count)
        #expect(store.writerColor(.collaborator) == store.color(.ink2))
        #expect(Writer.unknown.name == "Another app")
    }

    @MainActor @Test func choicesPersistAndPost() throws {
        let suite = "dev.arkwerx.dewline.tests.themes"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ThemeStore(defaults: defaults)
        #expect(store.lightTheme == .tidewater && store.darkTheme == .nightwatch && store.appearance == .auto)
        let listener = Listener()
        NotificationCenter.default.addObserver(listener, selector: #selector(Listener.changed), name: ThemeStore.didChange, object: store)
        store.lightTheme = .onionskin
        store.darkTheme = .carbon
        store.bodySize = 40
        store.columnWidth = 76
        #expect(listener.posts == 4)
        let reloaded = ThemeStore(defaults: defaults)
        #expect(reloaded.lightTheme == .onionskin && reloaded.darkTheme == .carbon)
        #expect(reloaded.bodySize == ThemeStore.bodySizes.upperBound && reloaded.columnWidth == 76)
    }

    /// A theme saved before there were four reads as the nearest one, and a theme saved in the other slot as its partner.
    @MainActor @Test func retiredThemesMapToTheFour() throws {
        let suite = "dev.arkwerx.dewline.tests.themes.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        for (light, dark, expected) in [
            ("Aurora", "Solarized", (Theme.tidewater, Theme.nightwatch)), ("Gruvbox", "Gruvbox", (.tidewater, .carbon)),
            ("Dawnline", "Tokyo Night", (.onionskin, .carbon)), ("Nightwatch", "Onionskin", (.tidewater, .carbon)),
            ("Nothing", "Nothing", (.tidewater, .nightwatch)),
        ] {
            defaults.set(light, forKey: "DewlineLightTheme")
            defaults.set(dark, forKey: "DewlineDarkTheme")
            let store = ThemeStore(defaults: defaults)
            #expect(store.lightTheme == expected.0 && store.darkTheme == expected.1, "\(light), \(dark)")
        }
    }

    @MainActor @Test func savedFacesKeepOnlyFamiliesThatExist() throws {
        let suite = "dev.arkwerx.dewline.tests.themes.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("JetBrains Mono", forKey: "DewlineBodyFace")
        defaults.set("No Such Family", forKey: "DewlineHeadingFace")
        let store = ThemeStore(defaults: defaults)
        #expect(store.bodyFace == "JetBrains Mono" && store.headingFace == Faces.heading)
    }

    @MainActor @Test func headingsDefaultToBricolageAndKeepAChosenFace() throws {
        let suite = "dev.arkwerx.dewline.tests.themes.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(ThemeStore(defaults: defaults).heading(1).font.familyName == "Bricolage Grotesque")
        defaults.set("SF Pro", forKey: "DewlineHeadingFace")
        let heading = ThemeStore(defaults: defaults).heading(2).font
        #expect(heading.familyName == NSFont.systemFont(ofSize: heading.pointSize).familyName)
    }
}

@MainActor
private final class Listener: NSObject {
    var posts = 0

    @objc func changed(_ notification: Notification) {
        posts += 1
    }
}
