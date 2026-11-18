import AppKit

/// The pane on the window's right, 380 pt by default: one of its tabs under a segmented header. Changes shows once
/// its part of the app registers what it draws.
final class RightPane: NSViewController {
    enum Tab: Int, CaseIterable {
        case changes
        case backlinks

        var title: String {
            switch self {
            case .changes: "Changes"
            case .backlinks: "Backlinks"
            }
        }
    }

    static let width: CGFloat = 380
    static let widths: ClosedRange<CGFloat> = 300...560

    /// The Changes list for a window; nil leaves the Changes segment out.
    static var makeChanges: (@MainActor (NSWindow) -> NSViewController)?

    /// Shows `tab` in `window`'s pane, or the main window's, opening the pane.
    static func show(_ tab: Tab, in window: NSWindow? = nil) {
        ((window ?? NSApp.mainWindow)?.windowController as? MainWindowController)?.showPane(tab)
    }

    private(set) var tab: Tab = .changes
    /// The segment the user picked, to keep across this window's tabs.
    var picked: (Tab) -> Void = { _ in }
    /// The changes waiting for a decision, shown on the Changes segment when there are any.
    var changesCount = 0 {
        didSet { if changesCount != oldValue { labelSegments() } }
    }

    /// The tab's note, whose backlinks the Backlinks tab lists.
    var note: URL? {
        didSet { if note != oldValue, showsBacklinks { backlinks.show(note, in: folder) } }
    }
    let backlinks = BacklinksPane()

    private let folder: URL?
    private let segments = NSSegmentedControl()
    private let content = NSView()
    private var built: [Tab: NSViewController] = [:]

    init(folder: Folder?) {
        self.folder = folder?.url
        super.init(nibName: nil, bundle: nil)
        if let folder {
            NotificationCenter.default.addObserver(self, selector: #selector(folderChanged), name: FolderIndex.changed, object: FolderIndex.of(folder))
        }
    }

    required init?(coder: NSCoder) {
        fatalError("RightPane is built in code")
    }

    private var tabs: [Tab] {
        Tab.allCases.filter { tab in
            switch tab {
            case .changes: Self.makeChanges != nil
            case .backlinks: true
            }
        }
    }

    private var showsBacklinks: Bool {
        isViewLoaded && tab == .backlinks && built[.backlinks] != nil && !view.isHiddenOrHasHiddenAncestor
    }

    override func loadView() {
        let root = ChromeFill()
        segments.segmentStyle = .automatic
        segments.trackingMode = .selectOne
        segments.controlSize = .regular
        segments.target = self
        segments.action = #selector(segmentPicked)
        segments.setAccessibilityLabel("Pane")
        let rule = RuleLine()
        for view in [segments, rule, content] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            segments.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            segments.centerYAnchor.constraint(equalTo: root.topAnchor, constant: 18),
            segments.leadingAnchor.constraint(greaterThanOrEqualTo: root.leadingAnchor, constant: 12),
            rule.topAnchor.constraint(equalTo: root.topAnchor, constant: 36),
            rule.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            rule.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            content.topAnchor.constraint(equalTo: rule.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root
        labelSegments()
        select(tab)
    }

    private func labelSegments() {
        let tabs = tabs
        segments.segmentCount = tabs.count
        for (index, tab) in tabs.enumerated() {
            let count = tab == .changes && changesCount > 0 ? " \(changesCount)" : ""
            segments.setLabel(tab.title + count, forSegment: index)
            segments.setWidth(0, forSegment: index)
        }
        segments.selectedSegment = tabs.firstIndex(of: tab) ?? 0
    }

    @objc private func segmentPicked() {
        let tabs = tabs
        guard tabs.indices.contains(segments.selectedSegment) else { return }
        select(tabs[segments.selectedSegment])
        picked(tab)
    }

    /// Puts `tab`'s content in the pane; a tab this build has no content for falls back to the first.
    func select(_ tab: Tab) {
        let tab = tabs.contains(tab) ? tab : tabs.first ?? tab
        self.tab = tab
        guard isViewLoaded else { return }
        labelSegments()
        for child in content.subviews { child.removeFromSuperview() }
        guard let controller = controller(for: tab) else { return }
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(controller.view)
        NSLayoutConstraint.activate([
            controller.view.topAnchor.constraint(equalTo: content.topAnchor),
            controller.view.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            controller.view.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            controller.view.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        if tab == .backlinks { backlinks.show(note, in: folder) }
    }

    /// Lists the backlinks again when a note in the folder changes, in the window on screen.
    @objc private func folderChanged() {
        if showsBacklinks, view.window?.isVisible == true { backlinks.show(note, in: folder) }
    }

    private func controller(for tab: Tab) -> NSViewController? {
        if let built = built[tab] { return built }
        let made: NSViewController? = switch tab {
        case .changes: view.window.flatMap { window in Self.makeChanges?(window) }
        case .backlinks: backlinks
        }
        if let made {
            addChild(made)
            built[tab] = made
        }
        return made
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        // Tabs need the window to build.
        if built[tab] == nil {
            select(tab)
        } else if showsBacklinks {
            backlinks.show(note, in: folder)
        }
    }
}

/// A view filled with the theme's chrome, following the theme and the appearance.
final class ChromeFill: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        NotificationCenter.default.addObserver(self, selector: #selector(themeDidChange), name: ThemeStore.didChange, object: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("ChromeFill is built in code")
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = Chrome.color(.chrome).resolved(for: effectiveAppearance).cgColor
    }

    @objc private func themeDidChange() {
        needsDisplay = true
    }
}
