import AppKit

/// One window's tabs, which Dewline draws itself. Each tab keeps its own controller and window, so its document,
/// sheets and undo stay as they are; only the selected tab's window is on screen, and the others wait ordered out at
/// the same frame. Posts `changed` when a tab comes, goes, moves, is selected, or its name or saved state changes.
@MainActor
final class TabSet {
    static let changed = Notification.Name("DewlineTabsChanged")

    private(set) var tabs: [MainWindowController] = []
    private(set) weak var selected: MainWindowController?
    /// What the window owns rather than a tab, handed from the tab going out to the tab coming in.
    let shared = WindowState()

    init(_ first: MainWindowController) {
        tabs = [first]
        selected = first
    }

    /// Adds `tab` after `neighbor`, or last.
    func insert(_ tab: MainWindowController, after neighbor: MainWindowController?) {
        let index = neighbor.flatMap { tabs.firstIndex(of: $0) }.map { $0 + 1 } ?? tabs.count
        tabs.insert(tab, at: index)
        post()
    }

    /// Puts `tab`'s window where the selected one is and orders the selected one out. The caller brings `tab` front.
    func select(_ tab: MainWindowController) {
        guard let old = selected, old !== tab, tabs.contains(tab), let window = tab.window, let leaving = old.window else {
            selected = tab
            return
        }
        // A full-screen frame is the screen's; the tab keeps its own windowed frame, which the tabs share.
        if leaving.isVisible || leaving.isMiniaturized, !leaving.styleMask.contains(.fullScreen) {
            window.setFrame(leaving.frame, display: false)
        }
        old.saveWindowState()
        selected = tab
        tab.adoptWindowState()
        tab.adoptPane(from: old)
        window.isExcludedFromWindowsMenu = false
        leaving.isExcludedFromWindowsMenu = true
        // The window goes after the new one is in front, so the screen never shows neither. A full-screen window
        // leaves full screen first; once it has, it goes and the new tab enters full screen
        // (`MainWindowController.windowDidExitFullScreen`).
        Task { @MainActor in
            guard self.selected !== old else { return }
            if leaving.styleMask.contains(.fullScreen) {
                leaving.toggleFullScreen(nil)
            } else {
                leaving.orderOut(nil)
            }
        }
        post()
    }

    /// Moves `tab` to just after `neighbor`, or first.
    func move(_ tab: MainWindowController, after neighbor: MainWindowController?) {
        guard tab !== neighbor, let from = tabs.firstIndex(of: tab) else { return }
        tabs.remove(at: from)
        let index = neighbor.flatMap { tabs.firstIndex(of: $0) }.map { $0 + 1 } ?? 0
        tabs.insert(tab, at: index)
        post()
    }

    /// Takes a closing tab out; when it was the selected one, its neighbor takes its place.
    func remove(_ tab: MainWindowController) {
        guard let index = tabs.firstIndex(of: tab) else { return }
        tabs.remove(at: index)
        if selected === tab || selected == nil, !tabs.isEmpty {
            let next = tabs[min(index, tabs.count - 1)]
            tab.saveWindowState()
            selected = next
            next.adoptWindowState()
            next.adoptPane(from: tab)
            if let frame = tab.window?.frame { next.window?.setFrame(frame, display: false) }
            next.window?.isExcludedFromWindowsMenu = false
            next.showWindow(nil)
        }
        post()
    }

    /// The tab `offset` places from the selected one, wrapping around.
    func tab(_ offset: Int) -> MainWindowController? {
        guard let selected, let index = tabs.firstIndex(of: selected), tabs.count > 1 else { return nil }
        return tabs[((index + offset) % tabs.count + tabs.count) % tabs.count]
    }

    func post() {
        NotificationCenter.default.post(name: Self.changed, object: self)
    }
}


/// What the spec gives the window rather than a tab: the sidebar shown or collapsed and its width, the Find in Files
/// query, the right pane's hold on the sidebar, and full screen. Expanded folders are kept per folder in user defaults,
/// which the tab coming in reads again.
@MainActor
final class WindowState {
    var sidebarCollapsed = false
    var sidebarWidth: CGFloat = 264
    /// Find in Files' query while it shows in place of the tree.
    var search: String?
    var paneHidSidebar = false
    var fullScreen = false
}

/// The tab strip in the title row: one 26 pt pill per tab, SF Pro 13, radius 6, at most 200 pt, its file name with the
/// extension in `ink2`. The selected tab is the brightest pill with the 2 x 12 cursor bar 8 pt into it; under the
/// pointer the bar becomes the close x. Other tabs sit on the chrome with 16 pt padding and a 1 px divider at 10%,
/// hidden beside the selected or hovered tab. Tabs keep their width; those past the strip's end go into a "+N" pop-up,
/// and the selected tab always shows. Dragging a tab along the strip moves it. The cursor bar shows only while the
/// window is key. A tab's tooltip says when its note was saved and how many words it has.
final class TabStrip: NSView {
    private static let height: CGFloat = 26
    private static let padding: CGFloat = 16
    private static let gap: CGFloat = 4
    private static let widest: CGFloat = 200
    private static let close = NSRect(x: 3, y: 7, width: 12, height: 12)

    weak var tabs: TabSet? {
        didSet {
            NotificationCenter.default.removeObserver(self, name: TabSet.changed, object: nil)
            if let tabs { NotificationCenter.default.addObserver(self, selector: #selector(reload), name: TabSet.changed, object: tabs) }
            reload()
        }
    }

    private struct Slot {
        let tab: MainWindowController
        var frame: NSRect
    }

    private var slots: [Slot] = []
    private var overflow: [MainWindowController] = []
    private var more: NSRect?
    private var hovered: MainWindowController?
    private var dragging: (tab: MainWindowController, offset: CGFloat)?

    /// The opacity of everything but the selected tab; at 0 those tabs and "+N" take no clicks and leave VoiceOver.
    @objc dynamic var othersAlpha: CGFloat = 1 {
        didSet {
            needsDisplay = true
            guard (oldValue == 0) != (othersAlpha == 0) else { return }
            updateAccessibility()
            NSAccessibility.post(element: self, notification: .layoutChanged)
        }
    }

    override class func defaultAnimation(forKey key: NSAnimatablePropertyKey) -> Any? {
        key == "othersAlpha" ? CABasicAnimation() : super.defaultAnimation(forKey: key)
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.tabGroup)
        setAccessibilityLabel("Tabs")
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeInActiveApp, .inVisibleRect], owner: self))
        NotificationCenter.default.addObserver(self, selector: #selector(reload), name: ThemeStore.didChange, object: nil)
        // A full-screen title row sits in a window of its own, so the strip hears every window's key state.
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(keyChanged), name: name, object: nil)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("TabStrip is built in code")
    }

    @objc private func keyChanged() {
        needsDisplay = true
    }

    override var mouseDownCanMoveWindow: Bool { false }
    override var isFlipped: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        place()
    }

    @objc func reload() {
        place()
    }

    // MARK: Layout

    private static func name(_ tab: MainWindowController) -> NSAttributedString {
        let file = tab.tabFileName as NSString
        let ext = file.pathExtension.isEmpty ? "" : "." + file.pathExtension
        let line = NSMutableParagraphStyle()
        line.lineBreakMode = .byTruncatingMiddle
        let name = NSMutableAttributedString(
            string: file as String, attributes: [.font: Chrome.label, .foregroundColor: Chrome.color(.ink), .paragraphStyle: line])
        name.addAttribute(.foregroundColor, value: Chrome.color(.ink2), range: NSRange(location: file.length - (ext as NSString).length, length: (ext as NSString).length))
        return name
    }

    private static func edited(_ tab: MainWindowController) -> Bool {
        tab.window?.isDocumentEdited == true
    }

    private static func width(_ tab: MainWindowController) -> CGFloat {
        min(ceil(name(tab).size().width) + padding * 2 + (edited(tab) ? 8 : 0), widest)
    }

    private static func moreWidth(_ count: Int) -> CGFloat {
        ceil(("+\(count)" as NSString).size(withAttributes: [.font: Chrome.mono(12, weight: .medium)]).width) + 20
    }

    /// Lays the tabs out from the leading edge. When they overflow, the leading ones that fit stay, the selected tab
    /// takes the last place if it is not among them, and the rest go into "+N".
    private func place() {
        let all = tabs?.tabs ?? []
        let widths = all.map(Self.width)
        let y = floor((bounds.height - Self.height) / 2)
        var shown = Array(all.indices)
        if widths.reduce(0, +) + Self.gap * CGFloat(max(all.count - 1, 0)) > bounds.width {
            let selected = all.firstIndex { $0 === tabs?.selected }
            var room = bounds.width - Self.moreWidth(all.count) - Self.gap
            if let selected { room -= widths[selected] + Self.gap }
            shown = []
            for index in all.indices where index != selected {
                guard widths[index] + Self.gap <= room else { break }
                room -= widths[index] + Self.gap
                shown.append(index)
            }
            if let selected { shown = (shown + [selected]).sorted() }
        }
        var x: CGFloat = 0
        slots = shown.map { index in
            let width = min(widths[index], max(bounds.width - x, 0))
            defer { x += width + Self.gap }
            return Slot(tab: all[index], frame: NSRect(x: x, y: y, width: width, height: Self.height))
        }
        overflow = all.indices.filter { !shown.contains($0) }.map { all[$0] }
        more = overflow.isEmpty ? nil : NSRect(x: x, y: y, width: min(Self.moreWidth(overflow.count), max(bounds.width - x, 0)), height: Self.height)
        if let hovered, !slots.contains(where: { $0.tab === hovered }) { self.hovered = nil }
        removeAllToolTips()
        for slot in slots { addToolTip(slot.frame, owner: self, userData: nil) }
        updateAccessibility()
        needsDisplay = true
    }

    // MARK: Drawing

    private var selectedFill: NSColor {
        let (paper, ink) = (Chrome.color(.paper), Chrome.color(.ink))
        return NSColor(name: nil) { $0.isDark ? ink.resolved(for: $0).withAlphaComponent(0.14) : paper.resolved(for: $0) }
    }

    /// Ink at 10%, 30% under Increase Contrast: the dividers and the close x's tile.
    private var faint: NSColor {
        let ink = Chrome.color(.ink)
        return NSColor(name: nil) { ink.resolved(for: $0).withAlphaComponent($0.isHighContrast ? 0.30 : 0.10) }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let selected = tabs?.selected
        for (index, slot) in slots.enumerated() where slot.tab !== dragging?.tab {
            context.setAlpha(slot.tab === selected ? 1 : othersAlpha)
            draw(slot, selected: slot.tab === selected)
            guard index + 1 < slots.count else { continue }
            let next = slots[index + 1].tab
            let quiet = [slot.tab, next].allSatisfy { $0 !== selected && $0 !== hovered && $0 !== dragging?.tab }
            if quiet {
                context.setAlpha(othersAlpha)
                faint.setFill()
                NSRect(x: slot.frame.maxX + Self.gap / 2 - 0.5, y: slot.frame.midY - 7, width: 1, height: 14).fill()
            }
        }
        if let more {
            context.setAlpha(othersAlpha)
            let path = NSBezierPath(roundedRect: more.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
            Chrome.color(.rule).setStroke()
            path.stroke()
            let label = NSAttributedString(string: "+\(overflow.count)", attributes: [.font: Chrome.mono(12, weight: .medium), .foregroundColor: Chrome.color(.ink2)])
            let size = label.size()
            label.draw(at: NSPoint(x: more.midX - size.width / 2, y: more.midY - size.height / 2))
        }
        context.setAlpha(1)
        if let dragging, var slot = slots.first(where: { $0.tab === dragging.tab }) {
            slot.frame.origin.x += dragging.offset
            draw(slot, selected: slot.tab === selected)
        }
    }

    private func draw(_ slot: Slot, selected: Bool) {
        let frame = slot.frame
        let hovering = slot.tab === hovered
        let pill = NSBezierPath(roundedRect: frame, xRadius: 6, yRadius: 6)
        if selected {
            selectedFill.setFill()
            pill.fill()
            Chrome.strokeSubtle.setStroke()
            NSBezierPath(roundedRect: frame.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6).stroke()
        } else if hovering || slot.tab === dragging?.tab {
            Chrome.hover.setFill()
            pill.fill()
        }
        if hovering {
            let box = Self.close.offsetBy(dx: frame.minX, dy: frame.minY)
            faint.setFill()
            NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4).fill()
            Chrome.color(.ink).setStroke()
            let cross = NSBezierPath()
            cross.lineWidth = 1.2
            cross.lineCapStyle = .round
            let glyph = box.insetBy(dx: 3.5, dy: 3.5)
            cross.move(to: NSPoint(x: glyph.minX, y: glyph.minY))
            cross.line(to: NSPoint(x: glyph.maxX, y: glyph.maxY))
            cross.move(to: NSPoint(x: glyph.minX, y: glyph.maxY))
            cross.line(to: NSPoint(x: glyph.maxX, y: glyph.minY))
            cross.stroke()
        } else if selected, tabs?.selected?.window?.isKeyWindow == true {
            Chrome.color(.cursor).setFill()
            NSBezierPath(roundedRect: NSRect(x: frame.minX + 8, y: frame.midY - 6, width: 2, height: 12), xRadius: 1, yRadius: 1).fill()
        }
        let name = NSMutableAttributedString(attributedString: Self.name(slot.tab))
        if !selected, !hovering {
            let ext = (slot.tab.tabFileName as NSString).pathExtension
            let stem = name.length - (ext.isEmpty ? 0 : ext.utf16.count + 1)
            name.addAttribute(.foregroundColor, value: Chrome.color(.ink2), range: NSRange(location: 0, length: stem))
        }
        let edited = Self.edited(slot.tab)
        let height = ceil(name.size().height)
        let room = frame.width - Self.padding * 2 - (edited ? 8 : 0)
        name.draw(
            with: NSRect(x: frame.minX + Self.padding, y: frame.midY - height / 2, width: max(room, 0), height: height),
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        if edited {
            Chrome.color(.ink2).setFill()
            NSBezierPath(ovalIn: NSRect(x: frame.maxX - Self.padding - 4, y: frame.midY - 3, width: 6, height: 6)).fill()
        }
    }

    // MARK: Pointer

    private func slot(at point: NSPoint) -> Slot? {
        slots.first { $0.frame.contains(point) }
    }

    override func mouseMoved(with event: NSEvent) {
        hover(slot(at: convert(event.locationInWindow, from: nil))?.tab)
    }

    override func mouseEntered(with event: NSEvent) {
        mouseMoved(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        hover(nil)
    }

    private func hover(_ tab: MainWindowController?) {
        guard hovered !== tab else { return }
        hovered = tab
        needsDisplay = true
    }

    /// A click selects or closes a tab, or opens "+N"; a drag of more than 3 pt moves the tab along the strip.
    override func mouseDown(with event: NSEvent) {
        let start = convert(event.locationInWindow, from: nil)
        if let more, more.contains(start), othersAlpha > 0 { return showMore() }
        // The layout as the press found it; a tab that comes or goes mid-drag lays the strip out again.
        let frames = slots
        guard let slot = slot(at: start), othersAlpha > 0 || slot.tab === tabs?.selected, let window else { return }
        if Self.close.insetBy(dx: -2, dy: -2).offsetBy(dx: slot.frame.minX, dy: slot.frame.minY).contains(start) {
            return close(slot.tab)
        }
        var moved = false
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            let offset = convert(next.locationInWindow, from: nil).x - start.x
            if next.type == .leftMouseUp { break }
            moved = moved || abs(offset) > 3
            guard moved else { continue }
            let low = -slot.frame.minX
            let high = (frames.last?.frame.maxX ?? 0) - slot.frame.maxX
            dragging = (slot.tab, min(max(offset, low), high))
            needsDisplay = true
        }
        guard moved, let dragging else { return slot.tab.showWindow(nil) }
        self.dragging = nil
        let middle = slot.frame.midX + dragging.offset
        let others = frames.filter { $0.tab !== slot.tab }
        let before = others.count { $0.frame.midX < middle }
        tabs?.move(slot.tab, after: before == 0 ? nil : others[before - 1].tab)
    }

    private func close(_ tab: MainWindowController) {
        tab.showWindow(nil)
        tab.window?.performClose(nil)
    }

    /// The tabs past the strip's end, in a menu under "+N".
    private func showMore() {
        guard let more else { return }
        let menu = NSMenu()
        for tab in overflow {
            let item = menu.addItem(withTitle: tab.tabFileName, action: #selector(NSWindowController.showWindow(_:)), keyEquivalent: "")
            item.target = tab
        }
        menu.popUp(positioning: nil, at: NSPoint(x: more.minX, y: more.maxY + 4), in: self)
    }

    // MARK: Accessibility

    private var elements: [NSAccessibilityElement] = []

    /// Each shown tab as a radio button, "spec.md, tab 1 of 3, saved 15:31", with its close button; then "+N". While
    /// the others are faded out, only the selected tab.
    private func updateAccessibility() {
        let all = tabs?.tabs ?? []
        elements = slots.filter { othersAlpha > 0 || $0.tab === tabs?.selected }.flatMap { slot -> [NSAccessibilityElement] in
            let index = (all.firstIndex { $0 === slot.tab } ?? 0) + 1
            let state = slot.tab.savedState.map { ", " + $0 } ?? ""
            let tab = TabElement(slot.tab) { $0.showWindow(nil) }
            tab.setAccessibilityRole(.radioButton)
            tab.setAccessibilityLabel("\(slot.tab.tabFileName), tab \(index) of \(all.count)\(state)")
            tab.setAccessibilityValue(slot.tab === tabs?.selected)
            tab.setAccessibilityFrameInParentSpace(slot.frame)
            tab.setAccessibilityParent(self)
            let close = TabElement(slot.tab) { [weak self] in self?.close($0) }
            close.setAccessibilityRole(.button)
            close.setAccessibilityLabel("Close \(slot.tab.tabFileName)")
            close.setAccessibilityFrameInParentSpace(Self.close.offsetBy(dx: slot.frame.minX, dy: slot.frame.minY))
            close.setAccessibilityParent(self)
            return [tab, close]
        }
        if let more, let first = overflow.first, othersAlpha > 0 {
            let element = TabElement(first) { [weak self] _ in self?.showMore() }
            element.setAccessibilityRole(.popUpButton)
            element.setAccessibilityLabel("\(overflow.count) more \(overflow.count == 1 ? "tab" : "tabs")")
            element.setAccessibilityFrameInParentSpace(more)
            element.setAccessibilityParent(self)
            elements.append(element)
        }
    }

    override func accessibilityChildren() -> [Any]? {
        elements
    }
}

extension TabStrip: NSViewToolTipOwner {
    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        guard let tab = slot(at: point)?.tab, othersAlpha > 0 || tab === tabs?.selected else { return "" }
        return ([tab.tabFileName, tab.savedState, tab.wordCount] as [String?]).compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
    }
}

/// A tab, its close button or "+N" for VoiceOver; pressing it runs `press` on its tab.
private final class TabElement: NSAccessibilityElement {
    private weak var tab: MainWindowController?
    private let press: (MainWindowController) -> Void

    init(_ tab: MainWindowController, press: @escaping (MainWindowController) -> Void) {
        self.tab = tab
        self.press = press
        super.init()
    }

    override func accessibilityPerformPress() -> Bool {
        guard let tab else { return false }
        press(tab)
        return true
    }
}

/// The main window's tabs in the Window menu, the first nine on Option-Command-1 to 9.
@MainActor
final class TabMenu: NSObject {
    static let shared = TabMenu()
    private static let tag = 0x7AB5

    weak var menu: NSMenu? {
        didSet { update() }
    }

    override init() {
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(update), name: TabSet.changed, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(update), name: NSWindow.didBecomeMainNotification, object: nil)
    }

    @objc private func update() {
        guard let menu else { return }
        for item in menu.items where item.tag == Self.tag { menu.removeItem(item) }
        guard let tabs = (NSApp.mainWindow?.windowController as? MainWindowController)?.tabs else { return }
        // After Bring All to Front, so the system's list of windows stays below.
        let bring = menu.indexOfItem(withTitle: "Bring All to Front")
        var at = bring < 0 ? menu.numberOfItems : bring + 1
        let separator = NSMenuItem.separator()
        separator.tag = Self.tag
        menu.insertItem(separator, at: at)
        for (index, tab) in tabs.tabs.enumerated() {
            at += 1
            let item = NSMenuItem(title: tab.tabFileName, action: #selector(NSWindowController.showWindow(_:)), keyEquivalent: index < 9 ? "\(index + 1)" : "")
            menu.insertItem(item, at: at)
            item.keyEquivalentModifierMask = [.command, .option]
            item.target = tab
            item.tag = Self.tag
            item.state = tab === tabs.selected ? .on : .off
        }
    }
}
