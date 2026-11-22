import AppKit

/// The neutral colors the Changes tab and the conflict card draw with, from the theme's paper and ink.
@MainActor
enum FlowColors {
    /// Panels and bars: paper with 2% ink.
    static var chrome: NSColor {
        let (paper, ink) = (ThemeStore.shared.color(.paper), ThemeStore.shared.color(.ink))
        return NSColor(name: nil) { appearance in
            let paper = paper.resolved(for: appearance)
            return paper.blended(withFraction: 0.02, of: ink.resolved(for: appearance)) ?? paper
        }
    }

    /// Hairlines: ink at 10%.
    static var rule: NSColor {
        let ink = ThemeStore.shared.color(.ink)
        return NSColor(name: nil) { ink.resolved(for: $0).withAlphaComponent($0.isDark ? 0.16 : 0.10) }
    }

    /// A selected or hovered row: ink at 8%.
    static var selection: NSColor {
        let ink = ThemeStore.shared.color(.ink)
        return NSColor(name: nil) { ink.resolved(for: $0).withAlphaComponent(0.08) }
    }
}
