import AppKit
import Observation

/// The owner's look, kept in user defaults: a theme for the light slot and one for the dark, which appearance windows
/// take, the page's faces, size, leading and measure, and Smart Punctuation. Posts `didChange` after
/// every change.
@MainActor @Observable
final class ThemeStore {
    enum Appearance: String, CaseIterable, Identifiable {
        case light, dark, auto
        var id: Self { self }
    }

    static let shared: ThemeStore = {
        let store = ThemeStore(defaults: .standard)
        store.applyAppearance()
        return store
    }()

    static let didChange = Notification.Name("DewlineThemeDidChange")
    /// The settings as a fresh install has them, for Restore Defaults.
    static var factory: ThemeStore { ThemeStore(defaults: .factory) }
    static let bodySizes = 12.0...28.0
    static let lineHeights = 1.25...1.8
    static let columnWidths = 50.0...120.0

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var colors: [Token: NSColor] = [:]
    @ObservationIgnored private var headings: [Int: Heading] = [:]
    @ObservationIgnored private var body: NSFont?
    @ObservationIgnored private var code: [CGFloat: NSFont] = [:]
    @ObservationIgnored private var traited: [NSFont: [UInt32: NSFont]] = [:]
    @ObservationIgnored private var lines: [CGFloat: NSParagraphStyle] = [:]
    @ObservationIgnored private var quote: NSParagraphStyle?

    var appearance: Appearance {
        didSet {
            save(appearance.rawValue, "Appearance")
            applyAppearance()
        }
    }
    var lightTheme: Theme { didSet { save(lightTheme.name, "LightTheme") } }
    var darkTheme: Theme { didSet { save(darkTheme.name, "DarkTheme") } }
    var bodyFace: String { didSet { save(bodyFace, "BodyFace") } }
    var headingFace: String { didSet { save(headingFace, "HeadingFace") } }
    var codeFace: String { didSet { save(codeFace, "CodeFace") } }
    var bodySize: Double { didSet { save(bodySize, "BodySize") } }
    var lineHeight: Double { didSet { save(lineHeight, "LineHeight") } }
    var columnWidth: Double { didSet { save(columnWidth, "ColumnWidth") } }
    var vimMode: Bool { didSet { save(vimMode, "VimMode") } }
    /// The system's smart quotes and dashes, outside code; off by default.
    var smartPunctuation: Bool { didSet { save(smartPunctuation, "SmartPunctuation") } }
    /// Spelling marked as you type; on by default.
    var spellCheck: Bool { didSet { save(spellCheck, "SpellCheck") } }
    /// The spaces Tab inserts outside a list, or 0 for a tab character.
    var tabWidth: Int { didSet { save(tabWidth, "TabWidth") } }

    init(defaults: UserDefaults) {
        self.defaults = defaults
        func string(_ key: String) -> String? { defaults.string(forKey: "Dewline" + key) }
        func face(_ key: String) -> String? { string(key).flatMap { Faces.exists($0) ? $0 : nil } }
        func number(_ key: String, in range: ClosedRange<Double>) -> Double? {
            (defaults.object(forKey: "Dewline" + key) as? Double).map { min(max($0, range.lowerBound), range.upperBound) }
        }
        appearance = string("Appearance").flatMap(Appearance.init) ?? .auto
        lightTheme = string("LightTheme").flatMap { Theme.named($0, dark: false) } ?? .tidewater
        darkTheme = string("DarkTheme").flatMap { Theme.named($0, dark: true) } ?? .nightwatch
        bodyFace = face("BodyFace") ?? Faces.body
        headingFace = face("HeadingFace") ?? Faces.heading
        codeFace = face("CodeFace") ?? Faces.code
        bodySize = number("BodySize", in: Self.bodySizes) ?? 16
        lineHeight = number("LineHeight", in: Self.lineHeights) ?? 1.5
        columnWidth = number("ColumnWidth", in: Self.columnWidths) ?? 68
        vimMode = defaults.bool(forKey: "DewlineVimMode")
        smartPunctuation = defaults.bool(forKey: "DewlineSmartPunctuation")
        spellCheck = defaults.object(forKey: "DewlineSpellCheck") as? Bool ?? true
        tabWidth = [2, 4].contains(defaults.integer(forKey: "DewlineTabWidth")) ? defaults.integer(forKey: "DewlineTabWidth") : 0
    }

    /// View > Zoom In and Zoom Out move the text size by `points` within its range; Actual Size (nil) restores the default.
    func zoom(by points: Double?) {
        bodySize = points.map { min(max(bodySize + $0, Self.bodySizes.lowerBound), Self.bodySizes.upperBound) } ?? Self.factory.bodySize
    }

    private func save(_ value: Any, _ key: String) {
        defaults.set(value, forKey: "Dewline" + key)
        colors = [:]
        headings = [:]
        body = nil
        code = [:]
        traited = [:]
        lines = [:]
        quote = nil
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    private func applyAppearance() {
        NSApp.appearance = switch appearance {
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        case .auto: nil
        }
    }

    /// The token in the light slot's theme under a light appearance and the dark slot's under a dark one, raised under
    /// Increase Contrast.
    func color(_ token: Token) -> NSColor {
        if let color = colors[token] { return color }
        func pick(_ colors: [Token: NSColor]) -> NSColor {
            colors[token] ?? colors[.sidebarTint]!
        }
        let light = pick(lightTheme.lightColors)
        let dark = pick(darkTheme.darkColors)
        let increasedLight = pick(lightTheme.increasedLightColors)
        let increasedDark = pick(darkTheme.increasedDarkColors)
        let color = NSColor(name: nil) {
            switch $0.bestMatch(from: [.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua]) {
            case .darkAqua?: dark
            case .accessibilityHighContrastAqua?: increasedLight
            case .accessibilityHighContrastDarkAqua?: increasedDark
            default: light
            }
        }
        colors[token] = color
        return color
    }

    /// The writer's ink: each named agent's, git's (its modified word), ink2 for you, your other Mac and collaborators,
    /// and the other-app gray for everyone else.
    func writerColor(_ writer: Writer) -> NSColor {
        let token: Token = switch writer {
        case .claude: .writerClaude
        case .codex: .writerCodex
        case .cursor: .writerCursor
        case .gemini: .writerGemini
        case .copilot: .writerCopilot
        case .git: .gitModified
        case .you, .otherMac, .collaborator: .ink2
        case .unknown, .demo: .writerApp
        }
        return color(token)
    }

    var bodyFont: NSFont {
        // Read on a cache hit too, so a view that shows the font observes them.
        let face = bodyFace, size = bodySize
        if let body { return body }
        let font = Faces.font(face, size: size)
        body = font
        return font
    }

    /// The body's line height, on the half-point grid.
    var bodyLineHeight: CGFloat {
        (bodySize * lineHeight * 2).rounded() / 2
    }

    /// A paragraph style whose lines are all `height` tall.
    func paragraphStyle(lineHeight height: CGFloat) -> NSParagraphStyle {
        if let style = lines[height] { return style }
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = height
        style.maximumLineHeight = height
        lines[height] = style
        return style
    }

    /// The body's paragraph style, indented for a quote.
    var quoteParagraphStyle: NSParagraphStyle {
        if let quote { return quote }
        let style = paragraphStyle(lineHeight: bodyLineHeight).mutableCopy() as! NSMutableParagraphStyle
        style.firstLineHeadIndent = (18 * bodySize / 17).rounded()
        style.headIndent = style.firstLineHeadIndent
        quote = style
        return style
    }

    /// The text column's width: `columnWidth` times the body font's average advance over the lowercase alphabet and
    /// the space.
    var measure: CGFloat {
        let sample = "abcdefghijklmnopqrstuvwxyz "
        let width = NSAttributedString(string: sample, attributes: [.font: bodyFont]).size().width
        return (width / CGFloat(sample.count) * columnWidth).rounded()
    }

    func codeFont(size: CGFloat) -> NSFont {
        // Read on a cache hit too, so a view that shows the font observes it.
        let face = codeFace
        if let font = code[size] { return font }
        let font = Faces.font(face, size: size)
        code[size] = font
        return font
    }

    func font(_ font: NSFont, adding traits: NSFontDescriptor.SymbolicTraits) -> NSFont {
        if let derived = traited[font]?[traits.rawValue] { return derived }
        let descriptor = font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(traits))
        let derived = NSFont(descriptor: descriptor, size: font.pointSize)!
        traited[font, default: [:]][traits.rawValue] = derived
        return derived
    }

    struct Heading {
        let font: NSFont
        let lineHeight: CGFloat
        let kern: CGFloat
    }

    /// Heading levels 1 to 6 (synthesis 2.3), scaled with the body size, as the site sets them: H1 34 / 620 with
    /// -0.025 em tracking, H2 22 / 600, H3 17 / 600; those weights and the optical size axis apply to Bricolage, and
    /// other faces set semibold.
    func heading(_ level: Int) -> Heading {
        if let heading = headings[level] { return heading }
        let scale = bodySize / 17
        func display(_ size: CGFloat, _ weight: CGFloat, opticalSize: CGFloat? = nil) -> NSFont {
            guard headingFace == "Bricolage Grotesque" else { return Faces.font(headingFace, size: size, weight: .semibold) }
            // The variable font's default instance is 96 pt ExtraBold, so every axis is set.
            let axes: [String: CGFloat] = ["wght": weight, "opsz": min(max(opticalSize ?? size, 12), 96), "wdth": 100]
            let variation = Dictionary(uniqueKeysWithValues: axes.map { (NSNumber(value: $0.key.utf8.reduce(0) { $0 << 8 | Int($1) }), $0.value) })
            return NSFont(descriptor: NSFontDescriptor(fontAttributes: [.family: headingFace, .variation: variation]), size: size)
                ?? Faces.font(headingFace, size: size, weight: .semibold)
        }
        let heading = switch level {
        case 1:
            Heading(font: display(34 * scale, 620, opticalSize: 48), lineHeight: 40 * scale, kern: -0.85 * scale)
        case 2:
            Heading(font: display(22 * scale, 600), lineHeight: 28 * scale, kern: 0)
        case 3:
            Heading(font: display(17 * scale, 600), lineHeight: 24 * scale, kern: 0)
        default:
            Heading(font: Faces.font(bodyFace, size: bodySize, weight: .semibold), lineHeight: bodyLineHeight, kern: 0)
        }
        headings[level] = heading
        return heading
    }
}

extension NSAppearance {
    var isDark: Bool {
        bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    /// Increase Contrast is on.
    var isHighContrast: Bool {
        let names: [NSAppearance.Name] = [.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua]
        return [.accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua].contains(bestMatch(from: names))
    }
}

/// Faces by family name, where New York, SF Pro, SF Pro Rounded and SF Mono name the system designs.
enum Faces {
    static let body = "Seravek"
    static let heading = "Bricolage Grotesque"
    static let code = "SF Mono"
    static let system = ["New York", "SF Pro", "SF Pro Rounded", "SF Mono"]
    static let bundled = ["Bricolage Grotesque", "JetBrains Mono"]

    private static func design(_ family: String) -> NSFontDescriptor.SystemDesign? {
        switch family {
        case "New York": .serif
        case "SF Pro": .default
        case "SF Pro Rounded": .rounded
        case "SF Mono": .monospaced
        default: nil
        }
    }

    /// CoreText sees a font registered for the process at once; NSFontManager's lists catch up a run loop later.
    static func exists(_ family: String) -> Bool {
        design(family) != nil || !faces(of: family).isEmpty
    }

    static func faces(of family: String) -> [CTFontDescriptor] {
        let descriptor = CTFontDescriptorCreateWithAttributes([kCTFontFamilyNameAttribute: family] as CFDictionary)
        return CTFontDescriptorCreateMatchingFontDescriptors(descriptor, [kCTFontFamilyNameAttribute as String] as Set<String> as CFSet) as? [CTFontDescriptor] ?? []
    }

    /// Installed families other than the system's hidden ones, by name; `monospaced` keeps the fixed-pitch ones.
    static func installed(monospaced: Bool) -> [String] {
        let manager = NSFontManager.shared
        let families = monospaced
            ? Set(manager.availableFontNames(with: .fixedPitchFontMask)?.compactMap { NSFont(name: $0, size: 12)?.familyName } ?? [])
            : Set(manager.availableFontFamilies)
        return families.filter { !$0.hasPrefix(".") && !bundled.contains($0) }.sorted()
    }

    static func font(_ family: String, size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        if let design = design(family) {
            let descriptor = NSFont.systemFont(ofSize: size, weight: weight).fontDescriptor.withDesign(design)!
            return NSFont(descriptor: descriptor, size: size)!
        }
        if family == "Bricolage Grotesque" {
            // The variable font's default instance is 96 pt ExtraBold, so the weight and optical size axes are set.
            let wght: CGFloat = switch weight.rawValue {
            case ..<NSFont.Weight.medium.rawValue: 400
            case ..<NSFont.Weight.semibold.rawValue: 500
            case ..<NSFont.Weight.bold.rawValue: 600
            default: 700
            }
            let axes = ["wght": wght, "opsz": min(max(size, 12), 96), "wdth": 100]
            let variation = Dictionary(uniqueKeysWithValues: axes.map { (NSNumber(value: $0.key.utf8.reduce(0) { $0 << 8 | Int($1) }), $0.value) })
            return NSFont(descriptor: NSFontDescriptor(fontAttributes: [.family: family, .variation: variation]), size: size)!
        }
        let descriptor = NSFontDescriptor(fontAttributes: [.family: family, .traits: [NSFontDescriptor.TraitKey.weight: weight.rawValue]])
        return NSFont(descriptor: descriptor, size: size)!
    }
}

/// View > Zoom In, Zoom Out and Actual Size: Settings > Appearance > Text size, so every window zooms together and the
/// size persists.
@MainActor
final class TextZoom: NSObject {
    @objc static func zoomIn(_ sender: Any?) {
        ThemeStore.shared.zoom(by: 1)
    }

    @objc static func zoomOut(_ sender: Any?) {
        ThemeStore.shared.zoom(by: -1)
    }

    @objc static func actualSize(_ sender: Any?) {
        ThemeStore.shared.zoom(by: nil)
    }

    @objc static func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let size = ThemeStore.shared.bodySize
        return switch menuItem.action {
        case #selector(zoomIn(_:)): size < ThemeStore.bodySizes.upperBound
        case #selector(zoomOut(_:)): size > ThemeStore.bodySizes.lowerBound
        default: size != ThemeStore.factory.bodySize
        }
    }
}
