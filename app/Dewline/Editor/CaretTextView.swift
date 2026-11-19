import AppKit

/// The system caret in the cursor orange and solid after five seconds without input, with the streak or landing mark a
/// jump shows. Edits, arrows, clicks and key repeat always snap.
class CaretTextView: NSTextView {
    let effects = CaretEffectsView()
    private var monitor: Any?
    private var idleTimer: DispatchSourceTimer?
    private var lastInput = DispatchTime.now()
    private var solid = false

    /// The theme's cursor orange, light and dark.
    static var cursor: NSColor {
        ThemeStore.shared.color(.cursor)
    }

    /// Vim's normal mode: a block over the character the caret sits on, in the cursor orange, instead of the bar.
    var blockCaret = false {
        didSet {
            guard blockCaret != oldValue else { return }
            if !blockCaret { indicator?.displayMode = .automatic }
            holdSolid()
        }
    }

    var indicator: NSTextInsertionIndicator? {
        subviews.lazy.compactMap { $0 as? NSTextInsertionIndicator }.first
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        let center = NotificationCenter.default
        center.removeObserver(self, name: NSWindow.didBecomeKeyNotification, object: nil)
        center.removeObserver(self, name: NSWindow.didResignKeyNotification, object: nil)
        center.removeObserver(self, name: NSTextStorage.didProcessEditingNotification, object: nil)
        center.removeObserver(self, name: ThemeStore.didChange, object: ThemeStore.shared)
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        idleTimer?.cancel()
        idleTimer = nil
        solid = false
        guard let window else { return }
        insertionPointColor = Self.cursor
        if effects.superview == nil {
            effects.frame = bounds
            effects.autoresizingMask = [.width, .height]
            addSubview(effects)
        }
        center.addObserver(self, selector: #selector(keyStateDidChange(_:)), name: NSWindow.didBecomeKeyNotification, object: window)
        center.addObserver(self, selector: #selector(keyStateDidChange(_:)), name: NSWindow.didResignKeyNotification, object: window)
        center.addObserver(self, selector: #selector(storageDidEdit(_:)), name: NSTextStorage.didProcessEditingNotification, object: textStorage)
        center.addObserver(self, selector: #selector(cursorDidChange(_:)), name: ThemeStore.didChange, object: ThemeStore.shared)
        let input: NSEvent.EventTypeMask = [.keyDown, .flagsChanged, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel, .magnify, .rotate, .swipe, .smartMagnify]
        monitor = NSEvent.addLocalMonitorForEvents(matching: input) { [weak self] event in
            if let self, event.window === self.window {
                effects.clearMark()
                restartIdleClock()
            }
            return event
        }
        if window.isKeyWindow { restartIdleClock() }
    }

    isolated deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
        idleTimer?.cancel()
    }

    @objc private func cursorDidChange(_ notification: Notification) {
        insertionPointColor = Self.cursor
    }

    /// The caret, bar or block, shows only while the window is key.
    @objc private func keyStateDidChange(_ notification: Notification) {
        if window?.isKeyWindow == true {
            if !blockCaret { indicator?.displayMode = .automatic }
            restartIdleClock()
        } else {
            idleTimer?.cancel()
            idleTimer = nil
            solid = false
        }
        holdSolid()
    }

    /// Any change to the characters, from any writer, ends a streak in the same transaction as the change.
    @objc private func storageDidEdit(_ notification: Notification) {
        guard (notification.object as? NSTextStorage)?.editedMask.contains(.editedCharacters) == true else { return }
        effects.removeStreak()
    }

    /// One timestamp and one one-shot timer: typing costs at most one wakeup per five seconds and idle costs none.
    private func restartIdleClock() {
        lastInput = .now()
        if solid {
            solid = false
            if !blockCaret { indicator?.displayMode = .automatic }
        }
        if idleTimer == nil { armIdleTimer() }
    }

    private func armIdleTimer() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: lastInput + 5, leeway: .milliseconds(500))
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.idleTimerFired() }
        }
        timer.activate()
        idleTimer = timer
    }

    private func idleTimerFired() {
        idleTimer?.cancel()
        idleTimer = nil
        if DispatchTime.now() < lastInput + 5 { return armIdleTimer() }
        solid = window?.isKeyWindow == true && window?.firstResponder === self
        holdSolid()
    }

    override func updateInsertionPointStateAndRestartTimer(_ restartFlag: Bool) {
        LatencyProbe.begin(.caret)
        defer { LatencyProbe.end(.caret) }
        super.updateInsertionPointStateAndRestartTimer(restartFlag)
        holdSolid()
        followMark()
    }

    override func layout() {
        super.layout()
        holdSolid()
        followMark()
    }

    /// NSTextView sets its indicator back to automatic whenever it updates it, and TextKit 2 does so on every
    /// layout pass; at idle the caret stays solid, and in a window that isn't key it stays hidden.
    private func holdSolid() {
        placeBlock()
        guard !blockCaret else { return }
        if window?.isKeyWindow != true {
            indicator?.displayMode = .hidden
        } else if solid, window?.firstResponder === self {
            indicator?.displayMode = .visible
        }
    }

    private enum Cause { case jump, find }

    /// Moves the selection as Go to Line does.
    func jump(to range: NSRange) {
        move(.jump) {
            setSelectedRange(range)
            scrollRangeToVisible(range)
        }
    }

    /// Lines and columns count from 1. A column counts characters as the reader sees them and stops at the line's end.
    func jump(toLine line: Int, column: Int = 1) {
        let text = textStorage!.mutableString
        var start = 0
        var remaining = line
        while remaining > 1, start < text.length {
            start = NSMaxRange(text.lineRange(for: NSRange(location: start, length: 0)))
            remaining -= 1
        }
        var end = 0
        text.getLineStart(nil, end: nil, contentsEnd: &end, for: NSRange(location: start, length: 0))
        var location = start
        remaining = column
        while remaining > 1, location < end {
            location = NSMaxRange(text.rangeOfComposedCharacterSequence(at: location))
            remaining -= 1
        }
        jump(to: NSRange(location: location, length: 0))
    }

    @objc func goToLine(_ sender: Any?) {
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        let alert = NSAlert()
        alert.messageText = "Go to Line"
        alert.accessoryView = field
        alert.addButton(withTitle: "Go")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window!) { [weak self] response in
            if response == .alertFirstButtonReturn, let line = Int(field.stringValue) { self?.jump(toLine: line) }
        }
    }

    override func performFindPanelAction(_ sender: Any?) {
        let tag = (sender as? NSMenuItem)?.tag
        guard tag == NSTextFinder.Action.nextMatch.rawValue || tag == NSTextFinder.Action.previousMatch.rawValue else {
            return super.performFindPanelAction(sender)
        }
        move(.find) { super.performFindPanelAction(sender) }
    }

    /// Runs a jump the user asked for, then shows what Motion allows: the streak when the view did not scroll and both
    /// caret rects are visible, otherwise the landing mark. A key repeat snaps. Find has no landing mark because its
    /// selected match marks the target.
    private func move(_ cause: Cause, _ body: () -> Void) {
        let level = Motion.current
        let repeating = NSApp.currentEvent.map { $0.type == .keyDown && $0.isARepeat } ?? false
        guard let window, !repeating, !hasMarkedText() else { return body() }
        let old = caretRect(at: selectedRange().location, in: window)
        let visible = visibleRect
        body()
        // TextKit 2 corrects its estimated layout around the new selection now instead of at the next display.
        layoutSubtreeIfNeeded()
        effects.removeStreak()
        let new = caretRect(at: selectedRange().location, in: window)
        let streaks = level != .off && new != old && visibleRect.origin == visible.origin && visible.contains(old) && visibleRect.contains(new)
        if streaks {
            effects.streak(from: old, to: new, color: cursorColor)
        } else if cause == .jump {
            effects.mark(line(around: new), color: cursorColor, fades: level != .off)
        }
    }

    /// The landing mark stays on the caret's line while the layout above it settles, which on a document opened
    /// moments earlier moves the line by hundreds of points.
    private func followMark() {
        guard effects.marking, let window else { return }
        let caret = caretRect(at: selectedRange().location, in: window)
        if visibleRect.intersects(caret) { effects.moveMark(to: line(around: caret)) }
    }

    /// The caret at a character index in view coordinates, 2 pt wide like the system bar; `firstRect` is empty for
    /// a caret outside the visible rect.
    private func caretRect(at location: Int, in window: NSWindow) -> NSRect {
        let rect = convert(window.convertFromScreen(firstRect(forCharacterRange: NSRange(location: location, length: 0), actualRange: nil)), from: nil)
        return NSRect(x: rect.minX - 1, y: rect.minY, width: 2, height: rect.height)
    }

    private func placeBlock() {
        guard blockCaret, let window, window.isKeyWindow else { return effects.showBlock(nil, color: nil) }
        indicator?.displayMode = .hidden
        let text = textStorage!.mutableString
        let location = selectedRange().location
        let caret = caretRect(at: location, in: window)
        var block = NSRect(x: caret.midX, y: caret.minY, width: max(caret.height * 0.45, 4), height: caret.height)
        if location < text.length, text.character(at: location) != 10 {
            let range = text.rangeOfComposedCharacterSequence(at: location)
            let glyph = convert(window.convertFromScreen(firstRect(forCharacterRange: range, actualRange: nil)), from: nil)
            if glyph.width > 0 { block = NSRect(x: glyph.minX, y: caret.minY, width: glyph.width, height: caret.height) }
        }
        effects.showBlock(block, color: cursorColor.copy(alpha: 0.4))
    }

    private func line(around caret: NSRect) -> NSRect {
        NSRect(x: textContainerOrigin.x, y: caret.minY, width: textContainer!.size.width, height: caret.height)
    }

    private var cursorColor: CGColor {
        var color: CGColor?
        effectiveAppearance.performAsCurrentDrawingAppearance { color = Self.cursor.cgColor }
        return color!
    }
}
