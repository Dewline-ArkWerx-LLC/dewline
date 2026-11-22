import AppKit
import SwiftUI

/// Dewline > Settings: a standard preferences window, 640 wide, with one toolbar button per pane. Each pane is as tall
/// as its content, so none scrolls on a screen that holds it, and the window resizes to it as panes change. It opens on
/// the pane last shown.
final class SettingsWindowController: NSWindowController {
    private static var shared: SettingsWindowController?
    static let paneKey = "DewlineSettingsPane"
    static let width: CGFloat = 640
    /// The screen's height less the title bar and toolbar, where a pane taller than the screen scrolls.
    static var maxHeight: CGFloat {
        max((NSScreen.main?.visibleFrame.height ?? 800) - 80, 480)
    }

    @objc static func showSettings(_ sender: Any?) {
        let controller = shared ?? SettingsWindowController()
        shared = controller
        controller.showWindow(sender)
    }

    private convenience init() {
        let last = UserDefaults.standard.string(forKey: Self.paneKey).flatMap(SettingsPane.init) ?? .general
        let tabs = SettingsTabs()
        tabs.tabStyle = .toolbar
        for pane in SettingsPane.allCases {
            let host = NSHostingController(rootView: SettingsPaneView(pane: pane))
            // The tab view controller sizes the window to the selected pane's preferred size.
            host.sizingOptions = .preferredContentSize
            // The tab view controller titles the window from the selected pane's controller.
            host.title = pane.rawValue
            let item = NSTabViewItem(viewController: host)
            item.label = pane.rawValue
            item.image = NSImage(systemSymbolName: pane.symbol, accessibilityDescription: pane.rawValue)
            item.identifier = pane.rawValue
            tabs.addTabViewItem(item)
        }
        tabs.selectedTabViewItemIndex = SettingsPane.allCases.firstIndex(of: last) ?? 0
        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.title = last.rawValue
        window.isRestorable = false
        tabs.fit(animate: false)
        window.center()
        self.init(window: window)
    }
}

/// Remembers the pane each time one is picked, and fits the window to it.
private final class SettingsTabs: NSTabViewController {
    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        if let name = tabViewItem?.identifier as? String {
            UserDefaults.standard.set(name, forKey: SettingsWindowController.paneKey)
        }
        fit(animate: true)
    }

    /// Sizes the window to the selected pane, keeping its top edge where it is.
    func fit(animate: Bool) {
        guard let window = view.window, tabViewItems.indices.contains(selectedTabViewItemIndex),
            let pane = tabViewItems[selectedTabViewItemIndex].viewController
        else { return }
        let size = window.frameRect(forContentRect: NSRect(origin: .zero, size: pane.view.fittingSize)).size
        guard size != window.frame.size else { return }
        let frame = NSRect(x: window.frame.minX, y: window.frame.maxY - size.height, width: size.width, height: size.height)
        window.setFrame(frame, display: true, animate: animate && window.isVisible)
    }
}

enum SettingsPane: String, CaseIterable, Identifiable {
    case general = "General", editor = "Editor", appearance = "Appearance", agents = "Agents"
    #if COLLAB
    case sharing = "Sharing"
    #endif

    var id: Self { self }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .editor: "text.cursor"
        case .appearance: "paintpalette"
        case .agents: "terminal"
        #if COLLAB
        case .sharing: "person.2"
        #endif
        }
    }
}

/// One pane's settings as a grouped form, as tall as they are up to the window's limit, where they scroll.
struct SettingsPaneView: View {
    let pane: SettingsPane

    var body: some View {
        content
            .formStyle(.grouped)
            .toggleStyle(.switch)
            .frame(width: SettingsWindowController.width, alignment: .top)
            .frame(maxHeight: SettingsWindowController.maxHeight)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var content: some View {
        let store = ThemeStore.shared
        switch pane {
        case .general: GeneralPane(preferences: .shared, updates: .shared)
        case .appearance: AppearancePane(store: store)
        case .editor: EditorPane(store: store)
        case .agents: AgentsPane(store: store)
        #if COLLAB
        case .sharing: CollaborationPane(preferences: .shared, store: store)
        #endif
        }
    }
}
