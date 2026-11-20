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

/// The tab strip in the title row: one 26 pt pill per tab, SF Pro body, radius 6, at most 200 pt, its file name with
/// the extension in `ink2`. The selected tab is the brightest pill; a tab with unsaved edits shows a dot 3 pt into it,
/// which turns into the close x under the pointer. Other tabs sit on the chrome with 16 pt padding and a 1 px divider at
/// 10%, hidden beside the selected or hovered tab. Tabs keep their width; those past the strip's end go into a "+N"
/// pop-up, and the selected tab always shows. Dragging a tab along the strip moves it, its neighbors sliding aside as it
/// passes; dragging it out of the strip drags its file. Command-click shows the note's path. A tab whose note has
/// changes waiting carries the sidebar's writer badge after its name: a 3 x 10 rule in the ink of the writer with the
/// most of them and the count of all of them, on that ink at 14%. Tabs whose notes share a name add the shortest parent
/// path that tells them apart ("spec.md · api"). A window whose one tab has no note shows no tab. A tab's tooltip says
/// what is waiting, when its note was saved, how many words it has and its Option-Command key; its context menu renames
/// or moves the note, or copies its path. Under Full Keyboard Access the strip takes the focus: the arrow keys move the
/// system's focus ring between tabs and Space or Return selects one.
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
        let title: String
        var frame: NSRect
    }

    private var slots: [Slot] = []
    private var overflow: [(tab: MainWindowController, title: String)] = []
    private var more: NSRect?
    private var hovered: MainWindowController?
    private var dragging: (tab: MainWindowController, offset: CGFloat)?
    /// How far each other tab has slid aside for the dragged one, and how far it is going.
    private var shifts: [ObjectIdentifier: (now: CGFloat, target: CGFloat)] = [:]
    private var slide: Timer?
    /// The tab the keyboard is on.
    private var focused: MainWindowController?

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
        for name in [ThemeStore.didChange, LiveFile.changesDidChange] {
            NotificationCenter.default.addObserver(self, selector: #selector(reload), name: name, object: nil)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("TabStrip is built in code")
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

    /// The tab's file name, then " · " and the fewest trailing folders of its path that no other same-named tab's
    /// shares.
    private static func title(_ tab: MainWindowController, among all: [MainWindowController]) -> String {
        let name = tab.tabFileName
        guard let url = (tab.document as? NSDocument)?.fileURL else { return name }
        let parents = url.deletingLastPathComponent().pathComponents
        let twins = all.compactMap { ($0.document as? NSDocument)?.fileURL }.filter { $0.lastPathComponent == name && $0 != url }
            .map { $0.deletingLastPathComponent().pathComponents }
        guard !twins.isEmpty else { return name }
        for count in 1...max(parents.count, 1) {
            let tail = parents.suffix(count)
            if twins.allSatisfy({ $0.suffix(count) != tail }) { return name + " \u{00B7} " + tail.joined(separator: "/") }
        }
        return name
    }

    /// The title, its extension and parent path in `ink2`.
    private static func name(_ tab: MainWindowController, _ title: String) -> NSAttributedString {
        let file = tab.tabFileName as NSString
        let ext = file.pathExtension.isEmpty ? 0 : file.pathExtension.utf16.count + 1
        let line = NSMutableParagraphStyle()
        line.lineBreakMode = .byTruncatingMiddle
        let name = NSMutableAttributedString(
            string: title, attributes: [.font: Chrome.label, .foregroundColor: Chrome.color(.ink), .paragraphStyle: line])
        name.addAttribute(.foregroundColor, value: Chrome.color(.ink2), range: NSRange(location: file.length - ext, length: name.length - file.length + ext))
        return name
    }

    private static func edited(_ tab: MainWindowController) -> Bool {
        tab.window?.isDocumentEdited == true
    }

    /// The writer with the most changes waiting in the tab's note, and the count of all of them.
    private static func waiting(_ tab: MainWindowController) -> WaitingCount? {
        var counts: [String: (writer: MarkWriter, count: Int)] = [:]
        for change in (tab.document as? MarkdownDocument)?.live?.changes.values.filter(\.marked) ?? [] {
            let writer = MarkWriter(change.origin)
            counts[writer.name, default: (writer, 0)].count += 1
        }
        let total = counts.values.reduce(0) { $0 + $1.count }
        return counts.values.max { $0.count < $1.count }.map { WaitingCount(writer: $0.writer, count: total) }
    }

    private static let badgeFont = Chrome.mono(11, weight: .medium)

    /// The badge's width: 4 pt, the rule, 4 pt, the count, 5 pt.
    private static func badgeWidth(_ waiting: WaitingCount) -> CGFloat {
        11 + ceil(("\(waiting.count ?? 0)" as NSString).size(withAttributes: [.font: badgeFont]).width) + 5
    }

    /// Room after the name for the writer badge.
    private static func trailing(_ tab: MainWindowController) -> CGFloat {
        waiting(tab).map { badgeWidth($0) + 6 } ?? 0
    }

    private static func width(_ tab: MainWindowController, _ title: String) -> CGFloat {
        min(ceil(name(tab, title).size().width) + padding * 2 + trailing(tab), widest)
    }

    private static func moreWidth(_ count: Int) -> CGFloat {
        ceil(("+\(count)" as NSString).size(withAttributes: [.font: Chrome.mono(12, weight: .medium)]).width) + 20
    }

    /// Lays the tabs out from the leading edge. When they overflow, the leading ones that fit stay, the selected tab
    /// takes the last place if it is not among them, and the rest go into "+N".
    private func place() {
        var all = tabs?.tabs ?? []
        if all.count == 1, all[0].document == nil { all = [] }
        let titles = all.map { Self.title($0, among: all) }
        let widths = all.indices.map { Self.width(all[$0], titles[$0]) }
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
            return Slot(tab: all[index], title: titles[index], frame: NSRect(x: x, y: y, width: width, height: Self.height))
        }
        overflow = all.indices.filter { !shown.contains($0) }.map { (all[$0], titles[$0]) }
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
        for (index, var slot) in slots.enumerated() where slot.tab !== dragging?.tab {
            context.setAlpha(slot.tab === selected ? 1 : othersAlpha)
            slot.frame.origin.x += shifts[ObjectIdentifier(slot.tab)]?.now ?? 0
            draw(slot, selected: slot.tab === selected)
            guard index + 1 < slots.count, dragging == nil else { continue }
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
        let box = Self.close.offsetBy(dx: frame.minX, dy: frame.minY)
        if hovering {
            faint.setFill()
            NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4).fill()
            if let cross = Chrome.symbol("xmark", Chrome.color(.ink)) {
                let size = cross.size
                cross.draw(in: NSRect(x: box.midX - size.width / 2, y: box.midY - size.height / 2, width: size.width, height: size.height))
            }
        } else if Self.edited(slot.tab) {
            Chrome.color(.ink2).setFill()
            NSBezierPath(ovalIn: NSRect(x: box.midX - 3, y: box.midY - 3, width: 6, height: 6)).fill()
        }
        let name = NSMutableAttributedString(attributedString: Self.name(slot.tab, slot.title))
        if !selected, !hovering {
            name.addAttribute(.foregroundColor, value: Chrome.color(.ink2), range: NSRange(location: 0, length: name.length))
        }
        let height = ceil(name.size().height)
        let room = frame.width - Self.padding * 2 - Self.trailing(slot.tab)
        name.draw(
            with: NSRect(x: frame.minX + Self.padding, y: frame.midY - height / 2, width: max(room, 0), height: height),
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        if let waiting = Self.waiting(slot.tab) {
            let badge = NSRect(x: frame.minX + Self.padding + max(room, 0) + 6, y: frame.midY - 8, width: Self.badgeWidth(waiting), height: 16)
            let ink = waiting.writer.color
            ink.withAlphaComponent(0.14).setFill()
            NSBezierPath(roundedRect: badge, xRadius: 4, yRadius: 4).fill()
            ink.setFill()
            NSBezierPath(roundedRect: NSRect(x: badge.minX + 4, y: badge.midY - 5, width: 3, height: 10), xRadius: 1, yRadius: 1).fill()
            let count = NSAttributedString(string: "\(waiting.count ?? 0)", attributes: [.font: Self.badgeFont, .foregroundColor: Chrome.color(.ink)])
            count.draw(at: NSPoint(x: badge.minX + 11, y: badge.midY - count.size().height / 2))
        }
    }

    // MARK: Pointer

    /// Rename and Move To for the tab's note, as the File menu has them, and Copy Relative Path.
    override func menu(for event: NSEvent) -> NSMenu? {
        guard let tab = slot(at: convert(event.locationInWindow, from: nil))?.tab, let document = tab.document as? NSDocument else { return nil }
        let menu = NSMenu()
        menu.addItem(withTitle: "Rename\u{2026}", action: #selector(NSDocument.rename(_:)), keyEquivalent: "").target = document
        menu.addItem(withTitle: "Move To\u{2026}", action: #selector(NSDocument.move(_:)), keyEquivalent: "").target = document
        menu.addItem(.separator())
        menu.addItem(withTitle: "Copy Relative Path", action: #selector(MainWindowController.copyRelativePath(_:)), keyEquivalent: "").target = tab
        return menu
    }

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

    /// A click selects or closes a tab, or opens "+N", and a Command-click shows the note's path; a drag of more than
    /// 3 pt moves the tab along the strip, and out of it drags the note's file.
    override func mouseDown(with event: NSEvent) {
        let start = convert(event.locationInWindow, from: nil)
        if let more, more.contains(start), othersAlpha > 0 { return showMore() }
        // The layout as the press found it; a tab that comes or goes mid-drag lays the strip out again.
        let frames = slots
        guard let slot = slot(at: start), othersAlpha > 0 || slot.tab === tabs?.selected, let window else { return }
        if Self.close.insetBy(dx: -2, dy: -2).offsetBy(dx: slot.frame.minX, dy: slot.frame.minY).contains(start) {
            return close(slot.tab)
        }
        let url = (slot.tab.document as? NSDocument)?.fileURL
        if event.modifierFlags.contains(.command), let url { return showPath(url, under: slot.frame) }
        var moved = false
        defer {
            dragging = nil
            endSlide()
        }
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            let point = convert(next.locationInWindow, from: nil)
            let offset = point.x - start.x
            if next.type == .leftMouseUp { break }
            if let url, point.y < -12 || point.y > bounds.maxY + 12 {
                return export(url, from: next)
            }
            moved = moved || abs(offset) > 3
            guard moved else { continue }
            let low = -slot.frame.minX
            let high = (frames.last?.frame.maxX ?? 0) - slot.frame.maxX
            dragging = (slot.tab, min(max(offset, low), high))
            slideNeighbors(frames, around: slot, to: position(of: slot, in: frames))
            needsDisplay = true
        }
        guard moved, dragging != nil else { return slot.tab.showWindow(nil) }
        let others = frames.filter { $0.tab !== slot.tab }
        let before = position(of: slot, in: frames)
        tabs?.move(slot.tab, after: before == 0 ? nil : others[before - 1].tab)
    }

    /// How many of the other tabs sit before the dragged one's middle.
    private func position(of slot: Slot, in frames: [Slot]) -> Int {
        let middle = slot.frame.midX + (dragging?.offset ?? 0)
        return frames.filter { $0.tab !== slot.tab }.count { $0.frame.midX < middle }
    }

    /// Slides the tabs between the dragged one's place and `position` among the others aside by its width, over 0.2 s,
    /// at once under Reduce Motion.
    private func slideNeighbors(_ frames: [Slot], around slot: Slot, to position: Int) {
        let from = frames.firstIndex { $0.tab === slot.tab } ?? 0
        let width = slot.frame.width + Self.gap
        for (index, other) in frames.filter({ $0.tab !== slot.tab }).enumerated() {
            let target: CGFloat = index >= from && index < position ? -width : index < from && index >= position ? width : 0
            let id = ObjectIdentifier(other.tab)
            shifts[id] = (shifts[id]?.now ?? 0, target)
        }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            shifts = shifts.mapValues { ($0.target, $0.target) }
            return
        }
        guard slide == nil else { return }
        let step = width / 0.2 / 60
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.shifts = self.shifts.mapValues { shift in
                    let gap = shift.target - shift.now
                    return (abs(gap) <= step ? shift.target : shift.now + (gap > 0 ? step : -step), shift.target)
                }
                self.needsDisplay = true
            }
        }
        RunLoop.current.add(timer, forMode: .common)
        slide = timer
    }

    private func endSlide() {
        slide?.invalidate()
        slide = nil
        shifts = [:]
        needsDisplay = true
    }

    /// Drags the note's file out of the strip, as its icon.
    private func export(_ url: URL, from event: NSEvent) {
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        let point = convert(event.locationInWindow, from: nil)
        item.setDraggingFrame(NSRect(x: point.x - 16, y: point.y - 16, width: 32, height: 32), contents: NSWorkspace.shared.icon(forFile: url.path))
        beginDraggingSession(with: [item], event: event, source: self)
    }

    /// The note and each folder above it, as the title bar's path menu lists them; choosing one shows it in Finder.
    private func showPath(_ url: URL, under frame: NSRect) {
        let menu = NSMenu()
        var each = url
        while true {
            let item = menu.addItem(withTitle: FileManager.default.displayName(atPath: each.path), action: #selector(revealPath(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = each
            let icon = NSWorkspace.shared.icon(forFile: each.path)
            icon.size = NSSize(width: 16, height: 16)
            item.image = icon
            guard each.pathComponents.count > 1 else { break }
            each = each.deletingLastPathComponent()
        }
        menu.popUp(positioning: nil, at: NSPoint(x: frame.minX, y: frame.maxY + 4), in: self)
    }

    @objc private func revealPath(_ sender: NSMenuItem) {
        NSWorkspace.shared.activateFileViewerSelecting([sender.representedObject as! URL])
    }

    // MARK: Keyboard

    override var acceptsFirstResponder: Bool { takesKeyboardFocus && !slots.isEmpty }

    override func becomeFirstResponder() -> Bool {
        focused = tabs?.selected
        noteFocusRingMaskChanged()
        return true
    }

    private var focusedFrame: NSRect? {
        slots.first { $0.tab === focused }?.frame
    }

    override var focusRingMaskBounds: NSRect { focusedFrame ?? .zero }

    override func drawFocusRingMask() {
        guard let frame = focusedFrame else { return }
        NSBezierPath(roundedRect: frame, xRadius: 6, yRadius: 6).fill()
    }

    /// Left and Right Arrow move between the shown tabs; Space or Return selects the one the keyboard is on.
    override func keyDown(with event: NSEvent) {
        let shown = slots.filter { othersAlpha > 0 || $0.tab === tabs?.selected }.map(\.tab)
        let index = shown.firstIndex { $0 === focused }
        if pressesOnKey(event), let focused { return focused.showWindow(nil) }
        guard let index, [123, 124].contains(event.keyCode) else { return super.keyDown(with: event) }
        focused = shown[min(max(index + (event.keyCode == 123 ? -1 : 1), 0), shown.count - 1)]
        noteFocusRingMaskChanged()
    }

    private func close(_ tab: MainWindowController) {
        tab.showWindow(nil)
        tab.window?.performClose(nil)
    }

    /// The tabs past the strip's end, in a menu under "+N".
    private func showMore() {
        guard let more else { return }
        let menu = NSMenu()
        for (tab, title) in overflow {
            let item = menu.addItem(withTitle: title, action: #selector(NSWindowController.showWindow(_:)), keyEquivalent: "")
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
            let state = (Self.waiting(slot.tab).map { ", " + $0.spoken } ?? "") + (slot.tab.savedState.map { ", " + $0 } ?? "")
            let tab = TabElement(slot.tab) { $0.showWindow(nil) }
            tab.setAccessibilityRole(.radioButton)
            tab.setAccessibilityLabel("\(slot.title), tab \(index) of \(all.count)\(state)")
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
        if let more, let first = overflow.first?.tab, othersAlpha > 0 {
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
        let title = slots.first { $0.tab === tab }?.title ?? tab.tabFileName
        let key = (tabs?.tabs.firstIndex { $0 === tab }).flatMap { $0 < 9 ? "Show with \u{2325}\u{2318}\($0 + 1)" : nil }
        return ([title, Self.waiting(tab)?.tip, tab.savedState, tab.wordCount, key] as [String?]).compactMap { $0 }.filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}

extension TabStrip: NSDraggingSource {
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
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
