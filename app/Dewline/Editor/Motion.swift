import AppKit

/// How much the editor animates: Calm, or Off while Reduce Motion is on in System Settings.
enum Motion {
    case off, calm

    /// Read when an effect starts, so turning Reduce Motion on or off applies without a relaunch.
    @MainActor
    static var current: Motion {
        reduced() ? .off : .calm
    }

    /// Reduce Motion in System Settings; tests stand in their own.
    @MainActor
    static var reduced: () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
}
