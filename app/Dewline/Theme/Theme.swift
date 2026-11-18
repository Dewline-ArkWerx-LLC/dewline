import AppKit

/// A color as authored: OKLab lightness from 0 to 1, chroma, and hue in degrees.
struct OKLCH: Hashable, Sendable {
    let l: Double
    let c: Double
    let h: Double

    /// Linear-light sRGB components, outside 0...1 where the color lies outside sRGB.
    var linearSRGB: [Double] {
        let a = c * cos(h * .pi / 180)
        let b = c * sin(h * .pi / 180)
        let l = l + 0.3963377774 * a + 0.2158037573 * b
        let m = self.l - 0.1055613458 * a - 0.0638541728 * b
        let s = self.l - 0.0894841775 * a - 1.2914855480 * b
        let (l3, m3, s3) = (l * l * l, m * m * m, s * s * s)
        return [
            4.0767416621 * l3 - 3.3077115913 * m3 + 0.2309699292 * s3,
            -1.2684380046 * l3 + 2.6097574011 * m3 - 0.3413193965 * s3,
            -0.0041960863 * l3 - 0.7034186147 * m3 + 1.7076147010 * s3,
        ]
    }

    /// The color in sRGB, or in Display P3 when it lies outside sRGB, clipped to P3.
    var color: NSColor {
        let rgb = linearSRGB
        func encoded(_ linear: [Double]) -> [Double] {
            linear.map {
                let x = min(max($0, 0), 1)
                return x <= 0.0031308 ? 12.92 * x : 1.055 * pow(x, 1 / 2.4) - 0.055
            }
        }
        if rgb.allSatisfy({ (-0.0001...1.0001).contains($0) }) {
            let srgb = encoded(rgb)
            return NSColor(srgbRed: srgb[0], green: srgb[1], blue: srgb[2], alpha: 1)
        }
        let p3 = encoded([
            0.8224619687 * rgb[0] + 0.1775380313 * rgb[1],
            0.0331941989 * rgb[0] + 0.9668058011 * rgb[1],
            0.0170826307 * rgb[0] + 0.0723974407 * rgb[1] + 0.9105199286 * rgb[2],
        ])
        return NSColor(displayP3Red: p3[0], green: p3[1], blue: p3[2], alpha: 1)
    }

    /// The WCAG contrast ratio between this color and `other`.
    func contrast(with other: OKLCH) -> Double {
        func luminance(_ color: OKLCH) -> Double {
            let rgb = color.linearSRGB
            return max(0.2126 * rgb[0] + 0.7152 * rgb[1] + 0.0722 * rgb[2], 0)
        }
        let (a, b) = (luminance(self), luminance(other))
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    /// The distance to `other` in OKLab, times 100, so 1 is about the smallest difference anyone sees.
    func deltaE(_ other: OKLCH) -> Double {
        let (a0, b0) = (c * cos(h * .pi / 180), c * sin(h * .pi / 180))
        let (a1, b1) = (other.c * cos(other.h * .pi / 180), other.c * sin(other.h * .pi / 180))
        let (dl, da, db) = (l - other.l, a0 - a1, b0 - b1)
        return (dl * dl + da * da + db * db).squareRoot() * 100
    }

    func lightened(by delta: Double) -> OKLCH {
        OKLCH(l: l + delta, c: c, h: h)
    }

    /// The color `t` of the way to `other`, mixed in OKLab, so two distant hues meet through a grayer middle instead
    /// of turning through the hues between them.
    func mixed(with other: OKLCH, by t: Double) -> OKLCH {
        func lab(_ color: OKLCH) -> (Double, Double) {
            (color.c * cos(color.h * .pi / 180), color.c * sin(color.h * .pi / 180))
        }
        let (a0, b0) = lab(self)
        let (a1, b1) = lab(other)
        let (a, b) = (a0 + (a1 - a0) * t, b0 + (b1 - b0) * t)
        let hue = atan2(b, a) * 180 / .pi
        return OKLCH(l: l + (other.l - l) * t, c: (a * a + b * b).squareRoot(), h: hue < 0 ? hue + 360 : hue)
    }
}

extension OKLCH {
    /// Reads an AppKit color through extended sRGB, so a Display P3 color keeps the part outside sRGB.
    init?(_ color: NSColor) {
        guard let rgb = color.usingColorSpace(.extendedSRGB) else { return nil }
        let linear = [rgb.redComponent, rgb.greenComponent, rgb.blueComponent].map { (v: CGFloat) -> Double in
            let x = abs(Double(v))
            let y = x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4)
            return v < 0 ? -y : y
        }
        let l = cbrt(0.4122214708 * linear[0] + 0.5363325363 * linear[1] + 0.0514459929 * linear[2])
        let m = cbrt(0.2119034982 * linear[0] + 0.6806995451 * linear[1] + 0.1073969566 * linear[2])
        let s = cbrt(0.0883024619 * linear[0] + 0.2817188376 * linear[1] + 0.6299787005 * linear[2])
        let a = 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s
        let b = 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
        let hue = atan2(b, a) * 180 / .pi
        self.init(l: 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s, c: (a * a + b * b).squareRoot(), h: hue < 0 ? hue + 360 : hue)
    }
}

/// The brand's colors, OKLCH, for a light page and a dark one. Every accent in the app reads `accent` through
/// `Token.accent`; the marks below fill their tokens in every theme that doesn't author them.
enum Brand {
    /// Green, #107460 and #7BC5B2: structure and the system accent.
    static let accent = (light: OKLCH(l: 0.5009, c: 0.0907, h: 174.5), dark: OKLCH(l: 0.7694, c: 0.0793, h: 176.0))
    /// Orange from the icon's cursor, #C9482A and #FF8A5C: the caret and the 2 x 12 pt bar beside it. Writers' inks,
    /// #A8509F / #EBBCE8 for Claude, #3D4AB0 / #95A0F6 for Codex, #296B8D / #81B9DA for any other app. Git's words,
    /// #7D550B / #BFA067 for modified (also git's ink as a writer), #22603B / #79C796 for new.
    static let marks: [Token: (light: OKLCH, dark: OKLCH)] = [
        .cursor: (OKLCH(l: 0.5753, c: 0.1700, h: 34.4), OKLCH(l: 0.7533, c: 0.1546, h: 41.6)),
        .writerClaude: (OKLCH(l: 0.5686, c: 0.1521, h: 331.4), OKLCH(l: 0.8502, c: 0.0788, h: 328.3)),
        .writerCodex: (OKLCH(l: 0.4595, c: 0.1615, h: 272.8), OKLCH(l: 0.7318, c: 0.1250, h: 277.3)),
        .writerApp: (OKLCH(l: 0.5013, c: 0.0852, h: 234.7), OKLCH(l: 0.7590, c: 0.0752, h: 235.0)),
        .gitModified: (OKLCH(l: 0.4813, c: 0.0969, h: 75.7), OKLCH(l: 0.7207, c: 0.0833, h: 82.0)),
        .gitAdded: (OKLCH(l: 0.4384, c: 0.0884, h: 154.1), OKLCH(l: 0.7658, c: 0.1052, h: 155.4)),
    ]
}

/// A theme's named colors (synthesis 2.1).
enum Token: String, CaseIterable, Sendable {
    case paper, ink, ink2, syntax, heading, accent, link, selection, sidebarTint, codeBackground, quoteRule
    /// The window's chrome around the page: sidebar, tab row, status bar, panels; and its hairlines.
    case chrome, rule
    /// Code highlighting's colors. A dev theme authors them from its editor's palette; Dewline's themes derive them
    /// (`Theme.coded`).
    case codeKeyword, codeString, codeNumber, codeType, codeFunction, codeComment, codeTag, codeInserted, codeDeleted
    /// Older chrome roles, each now one of the tokens above (`Theme.stationed`): frame, islandSide, sunken and keycap
    /// are chrome; islandEditor and raised are paper; hairline is rule; signal and glow are the accent; ink3 sits 30%
    /// of the way from ink2 to the paper.
    case frame, islandEditor, islandSide, raised, sunken, keycap, hairline, ink3, signal, glow
    /// The cursor bar, writers' inks and git's words, from `Brand.marks` unless the theme authors them.
    case cursor, writerClaude, writerCodex, writerApp, gitModified, gitAdded

    static let code: [Token] = [.codeKeyword, .codeString, .codeNumber, .codeType, .codeFunction, .codeComment, .codeTag, .codeInserted, .codeDeleted]
    static let station: [Token] = [.chrome, .rule, .frame, .islandEditor, .islandSide, .raised, .sunken, .keycap, .hairline, .ink3, .signal, .glow]
    static let marks: [Token] = [.cursor, .writerClaude, .writerCodex, .writerApp, .gitModified, .gitAdded]
    static let required = allCases.filter { !code.contains($0) && !station.contains($0) && !marks.contains($0) }

    /// The name in words: "code keyword", "ink 2".
    var label: String {
        rawValue.replacing(/[A-Z0-9]/) { " " + $0.output.lowercased() }
    }
}

/// One of Dewline's named themes: its tokens for a light and a dark appearance, authored in OKLCH and converted to
/// colors once, when the theme loads.
struct Theme: Identifiable, Hashable, Sendable {
    let name: String
    let summary: String
    let light: [Token: OKLCH]
    let dark: [Token: OKLCH]
    let lightColors: [Token: NSColor]
    let darkColors: [Token: NSColor]
    let increasedLightColors: [Token: NSColor]
    let increasedDarkColors: [Token: NSColor]

    var id: String { name }

    /// `table` holds one row per token: its name, then L C h for light and L C h for dark. A `-` in place of either
    /// triple leaves that side to the derivation.
    init(_ name: String, _ summary: String, _ table: String) {
        var light: [Token: OKLCH] = [:]
        var dark: [Token: OKLCH] = [:]
        for row in table.split(separator: "\n") {
            var fields = row.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            let token = Token(rawValue: fields.removeFirst())!
            func triple() -> OKLCH? {
                if fields.first == "-" {
                    fields.removeFirst()
                    return nil
                }
                let values = fields.prefix(3).map { Double($0)! }
                fields.removeFirst(3)
                return OKLCH(l: values[0], c: values[1], h: values[2])
            }
            light[token] = triple()
            dark[token] = triple()
        }
        let authored = (light: light, dark: dark)
        light = Self.stationed(Self.coded(light), increased: false)
        dark = Self.stationed(Self.coded(dark), increased: false)
        self.name = name
        self.summary = summary
        self.light = light
        self.dark = dark
        lightColors = light.mapValues(\.color)
        darkColors = dark.mapValues(\.color)
        // A dark-only port carries its dark block in the light slot too, so contrast rises away from the paper.
        increasedLightColors = Self.stationed(Self.coded(Self.increased(authored.light, dark: light[.paper]!.l < 0.5)), increased: true).mapValues(\.color)
        increasedDarkColors = Self.stationed(Self.coded(Self.increased(authored.dark, dark: dark[.paper]!.l < 0.5)), increased: true).mapValues(\.color)
    }

    /// `tokens` with the chrome's roles, stepped off the paper in its own hue so every theme has them: chrome a step
    /// darker than the paper in light and lighter in dark, the rule further, ink3 30% of the way from ink2 to the paper.
    /// The older roles alias these, and the brand's marks fill in. Under Increase Contrast the rule takes ink3. A role
    /// the theme authors stays.
    static func stationed(_ authored: [Token: OKLCH], increased: Bool) -> [Token: OKLCH] {
        let paper = authored[.paper]!
        let dark = paper.l < 0.5
        let hue = authored[.sidebarTint]!.h
        let chroma = min(paper.c * 1.6, 0.03)
        func step(_ delta: Double) -> OKLCH {
            OKLCH(l: min(max(paper.l + (dark ? delta : -delta), 0), 1), c: chroma, h: hue)
        }
        let chrome = authored[.chrome] ?? step(dark ? 0.03 : 0.02)
        let ink3 = authored[.ink3] ?? authored[.ink2]!.mixed(with: paper, by: 0.3)
        let rule = authored[.rule] ?? step(dark ? 0.13 : 0.085)
        let accent = authored[.accent]!
        var derived: [Token: OKLCH] = [
            .chrome: chrome, .rule: rule, .ink3: ink3,
            .frame: chrome, .islandSide: chrome, .sunken: chrome, .keycap: chrome,
            .islandEditor: paper, .raised: paper, .hairline: rule,
            .signal: accent, .glow: accent,
        ]
        for (token, mark) in Brand.marks {
            derived[token] = dark ? mark.dark : mark.light
        }
        var tokens = authored.merging(derived) { authored, _ in authored }
        if increased { (tokens[.rule], tokens[.hairline]) = (ink3, ink3) }
        return tokens
    }

    /// `tokens` with code highlighting's colors: keywords in the accent's hue, the rest at hues turned from the link's,
    /// all at the link's lightness, which reads on the paper; comments in ink2, tags and keys in the heading's color,
    /// insertions green and deletions red. A code color the theme authors, as a dev theme does from its editor's
    /// palette, stays.
    static func coded(_ authored: [Token: OKLCH]) -> [Token: OKLCH] {
        let link = authored[.link]!
        let accent = authored[.accent]!
        func turned(_ hue: Double) -> OKLCH {
            OKLCH(l: link.l, c: min(max(link.c, 0.08), 0.14), h: (hue + 360).truncatingRemainder(dividingBy: 360))
        }
        let derived: [Token: OKLCH] = [
            .codeKeyword: OKLCH(l: link.l, c: min(max(accent.c, 0.08), 0.16), h: accent.h),
            .codeString: turned(link.h + 240),
            .codeNumber: turned(link.h + 60),
            .codeType: turned(link.h + 150),
            .codeFunction: turned(link.h - 35),
            .codeComment: authored[.ink2]!,
            .codeTag: authored[.heading]!,
            .codeInserted: turned(150),
            .codeDeleted: turned(25),
        ]
        return authored.merging(derived) { authored, _ in authored }
    }

    /// `tokens` under Increase Contrast (synthesis 2.1): ink at L 0.15 or 0.97, ink2 at 7:1 on paper and syntax with it,
    /// link and accent 0.06 further from the paper.
    static func increased(_ tokens: [Token: OKLCH], dark: Bool) -> [Token: OKLCH] {
        let step = dark ? 0.01 : -0.01
        var tokens = tokens
        let ink = tokens[.ink]!
        tokens[.ink] = OKLCH(l: dark ? 0.97 : 0.15, c: ink.c, h: ink.h)
        var ink2 = tokens[.ink2]!
        while ink2.contrast(with: tokens[.paper]!) < 7 {
            ink2 = ink2.lightened(by: step)
        }
        tokens[.ink2] = ink2
        tokens[.syntax] = ink2
        tokens[.link] = tokens[.link]!.lightened(by: 6 * step)
        tokens[.accent] = tokens[.accent]!.lightened(by: 6 * step)
        return tokens
    }

    static func == (lhs: Theme, rhs: Theme) -> Bool {
        lhs.name == rhs.name
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(name)
    }

    /// The theme for the light or dark slot saved under `name`. A theme from before there were four maps to the nearest
    /// one, and a theme saved in the other slot to its partner there.
    static func named(_ name: String, dark: Bool) -> Theme? {
        switch name {
        case "Tidewater", "Nightwatch", "Aurora", "Solarized": dark ? .nightwatch : .tidewater
        case "Gruvbox": dark ? .carbon : .tidewater
        case "Onionskin", "Carbon", "Dawnline", "Dusk", "Nord", "Tokyo Night": dark ? .carbon : .onionskin
        default: nil
        }
    }

    static let light = [tidewater, onionskin]
    static let dark = [nightwatch, carbon]
    static let all = light + dark

    /// The defaults' palette: warm paper and green-black ink by day, green-black paper and cream ink at night, a cool
    /// green-gray chrome, and the brand's green as the accent. Selection is the green at 15% over the paper, the rule
    /// ink at 12% (cream at 10%) over the chrome.
    private static let brand = """
        paper           0.9763 0.007  88.6    0.1918 0.0122 167.1
        chrome          0.9392 0.0058 153.8   0.2442 0.0108 176.2
        ink             0.2396 0.0117 167.6   0.9079 0.0186 86.2
        ink2            0.475  0.0145 164.4   0.7249 0.014  130.8
        ink3            0.5583 0.0113 154.9   0.6023 0.0122 149.7
        rule            0.8646 0.0063 156.2   0.3224 0.0095 162.2
        codeBackground  0.9495 0.0099 87.5    0.2182 0.0119 167.4
        heading         0.2396 0.0117 167.6   0.9079 0.0186 86.2
        link            0.2396 0.0117 167.6   0.9079 0.0186 86.2
        selection       0.9048 0.0172 162.4   0.2932 0.0246 172.9
        syntax          0.62   0.01   160     0.52   0.012  165
        sidebarTint     0.9392 0.0058 153.8   0.2442 0.0108 176.2
        quoteRule       0.80   0.008  160     0.40   0.01   165
        accent          \(Brand.accent.light.l) \(Brand.accent.light.c) \(Brand.accent.light.h)   \(Brand.accent.dark.l) \(Brand.accent.dark.c) \(Brand.accent.dark.h)
        """

    static let tidewater = Theme("Tidewater", "Warm paper, green-black ink, a green accent.", brand)

    /// Chrome B's lightness steps without the green: gray paper and ink, the brand's green as the accent, links in the
    /// ink. Selection is the green at 15% over the paper.
    private static let neutral = """
        paper           0.975  0.002  255     0.19   0.003  260
        chrome          0.938  0.003  255     0.242  0.003  260
        ink             0.215  0.004  260     0.915  0.003  250
        ink2            0.465  0.004  260     0.735  0.004  255
        ink3            0.555  0.004  260     0.605  0.004  255
        rule            0.862  0.003  255     0.32   0.003  260
        codeBackground  0.948  0.003  255     0.216  0.003  260
        heading         0.215  0.004  260     0.915  0.003  250
        link            0.215  0.004  260     0.915  0.003  250
        selection       0.9039 0.014  181.4   0.2769 0.0124 187.8
        syntax          0.62   0.004  260     0.52   0.004  260
        sidebarTint     0.938  0.003  255     0.242  0.003  260
        quoteRule       0.80   0.003  255     0.40   0.003  260
        accent          \(Brand.accent.light.l) \(Brand.accent.light.c) \(Brand.accent.light.h)   \(Brand.accent.dark.l) \(Brand.accent.dark.c) \(Brand.accent.dark.h)
        """

    static let onionskin = Theme("Onionskin", "Gray paper, near-black ink, a green accent.", neutral)

    static let nightwatch = Theme("Nightwatch", "Green-black paper, cream ink, a green accent.", brand)

    static let carbon = Theme("Carbon", "Charcoal paper, near-white ink, a green accent.", neutral)
}
