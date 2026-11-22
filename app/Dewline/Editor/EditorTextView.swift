import AppKit

/// The markdown editor: hides syntax through `MarkdownStyler` and defers styling while an input method composes.
final class EditorTextView: CaretTextView {
    let styler = MarkdownStyler()
    /// The change engine's marks, painted under the text.
    let marks = ChangeMarks()
    /// Your edits' undo history, which landings move instead of clearing.
    lazy var history = UndoHistory(undoManager: styler.undoManager)
    private let fragments = Fragments()
    private var composing = false
    private var toggleWaits = false
    private var held: (anchor: Int, offset: CGFloat)?
    private weak var snapshot: NSView?
    /// When the last toggle committed its first frame and started the fade.
    private(set) var fadeStarted: ContinuousClock.Instant?
    /// Where images in the document resolve from, and where pasted images go; nil until the document is saved.
    var documentFolder: URL?
    /// Pixels per point of the note's images: the window's, or 2 before the view is in one.
    private(set) var pictureScale: CGFloat = 2
    /// Vim's keys, while Vim mode is on.
    var vim: VimEngine? {
        didSet {
            vimStatus?.isHidden = vim == nil
            vimDidRun()
        }
    }
    private var vimStatus: NSTextField?
    /// The foldable block under the pointer, by its location.
    private(set) var hoveredFold: Int?
    /// The hovered code block's language and Copy button.
    let codeBar = CodeBar()
    private var centering = false
    private var dimmed = false
    /// Focus dims every block but the caret's.
    var focusMode = false {
        didSet { updateFocus() }
    }
    /// Typewriter keeps the caret's line in the middle of the view.
    var typewriterMode = false {
        didSet {
            fitColumn(to: frame.width)
            centerCaretSoon()
        }
    }
    /// Where wikilinks resolve: the window's folder, else the document's.
    var noteFolder: URL?
    /// The notes `[[` offers, listed when it opens.
    var wikilinkNames: [String] = []
    /// Opens a note a link points to, at a heading.
    var openNote: ((URL, String?) -> Void)?
    /// Runs Find in Files for a tag; a window without a folder has none, and Cmd-clicking a tag beeps.
    var findInFiles: ((String) -> Void)?
    var footnotePopover: NSPopover?
    /// Counts the storage's character edits; the change engine stamps landings and saves with it.
    private(set) var version: UInt64 = 0
    /// Called after each character edit with its range and change in length.
    var edited: ((NSRange, Int) -> Void)?
    /// Called when a composition or a Writing Tools session ends.
    var inputEnded: (() -> Void)?
    /// The mono line over the text, in `ink3`, such as the file's path and word count; nil leaves the room to the text.
    var metaLine: String? {
        didSet {
            guard metaLine != oldValue else { return }
            if metaLine != nil, meta == nil {
                let label = NSTextField(labelWithString: "")
                label.font = Chrome.mono(11.5)
                label.lineBreakMode = .byTruncatingMiddle
                addSubview(label)
                meta = label
            }
            meta?.stringValue = metaLine ?? ""
            meta?.isHidden = metaLine == nil
            if (metaLine == nil) != (oldValue == nil) { fitColumn(to: frame.width) }
            placeMeta()
        }
    }
    private var meta: NSTextField?
    /// What Tab inserts in a code file, its own indentation; nil in a note, or a code file that indents nothing yet.
    private var codeIndent: String?
    /// The room the meta line takes over the text.
    private static let metaRoom: CGFloat = 36

    var defersStyling: Bool {
        composing || hasMarkedText()
    }

    // The root of the TextKit object graph, which a text view built on a given container does not retain.
    private let content: NSObject

    init() {
        let container = MeasureContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        let layout = NSTextLayoutManager()
        layout.textContainer = container
        let storage = NSTextContentStorage()
        storage.addTextLayoutManager(layout)
        content = storage
        super.init(frame: .zero, textContainer: container)
        textLayoutManager?.delegate = fragments
        styler.textView = self
        styler.blocks.textView = self
        styler.highlights.textView = self
        styler.math.textView = self
        textLayoutManager?.renderingAttributesValidator = { [weak self] layout, fragment in
            MainActor.assumeIsolated { self?.styler.highlights.validate(layout, fragment) }
        }
        history.textView = self
        delegate = styler
        textStorage?.delegate = styler
        isRichText = false
        // The history records edits itself, so a landing can move them.
        allowsUndo = false
        isAutomaticTextReplacementEnabled = false
        usesFindBar = true
        marks.textView = self
        marks.autoresizingMask = [.width, .height]
        marks.wantsLayer = true
        addSubview(marks, positioned: .below, relativeTo: nil)
        addSubview(codeBar)
        applyTheme()
        // The product's own name is not a misspelling, in any document.
        for word in ["Dewline", "dewline"] {
            NSSpellChecker.shared.ignoreWord(word, inSpellDocumentWithTag: spellCheckerDocumentTag)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(themeDidChange(_:)), name: ThemeStore.didChange, object: ThemeStore.shared)
    }

    required init?(coder: NSCoder) {
        fatalError("EditorTextView is built in code")
    }

    static func scrollView() -> NSScrollView {
        let textView = EditorTextView()
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        let rail = Rail()
        scrollView.verticalScroller = rail
        scrollView.backgroundColor = textView.backgroundColor
        scrollView.documentView = textView
        rail.labels.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(rail.labels)
        NSLayoutConstraint.activate([
            rail.labels.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            rail.labels.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            rail.labels.topAnchor.constraint(equalTo: scrollView.topAnchor),
            rail.labels.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),
        ])
        rail.attach(textView)
        textView.showLineNumbers(textView.styler.showsSource)
        let status = NSTextField(labelWithString: "")
        status.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        status.textColor = ThemeStore.shared.color(.ink2)
        status.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(status)
        NSLayoutConstraint.activate([
            status.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor, constant: -16),
            status.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: -8),
        ])
        status.isHidden = textView.vim == nil
        textView.vimStatus = status
        textView.vimDidRun()
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.autoresizingMask = .width
        return scrollView
    }

    /// Shows a code file in `language`, before its text arrives: no Markdown, every line on one line with a number,
    /// the view scrolling sideways, and no smart punctuation or spelling. Tab inserts `indent` when given.
    func showCode(_ language: String, indent: String?) {
        styler.code = language
        codeIndent = indent
        smartInsertDeleteEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isHorizontallyResizable = true
        textContainer?.widthTracksTextView = false
        (textContainer as? MeasureContainer)?.prose = .greatestFiniteMagnitude
        textContainer?.size = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        enclosingScrollView?.hasHorizontalScroller = true
        showLineNumbers(true)
        applyTheme()
    }

    /// Line numbers left of the text, in a code file and in Source mode.
    private func showLineNumbers(_ shown: Bool) {
        guard let scrollView = enclosingScrollView, shown != scrollView.hasVerticalRuler else { return }
        if shown { scrollView.verticalRulerView = LineNumbers(textView: self, in: scrollView) }
        scrollView.hasVerticalRuler = shown
        scrollView.rulersVisible = shown
        // A ruler put away stops counting lines.
        if !shown { scrollView.verticalRulerView = nil }
    }

    /// Paper, selection and typing attributes from the theme, and the column at its measure.
    private func applyTheme() {
        let store = ThemeStore.shared
        backgroundColor = store.color(.paper)
        enclosingScrollView?.backgroundColor = backgroundColor
        selectedTextAttributes = [.backgroundColor: store.color(.selection)]
        typingAttributes = styler.baseAttributes
        vimStatus?.textColor = store.color(.ink2)
        meta?.textColor = store.color(.ink3)
        let prose = styler.code == nil
        isAutomaticQuoteSubstitutionEnabled = prose && store.smartPunctuation
        isAutomaticDashSubstitutionEnabled = prose && store.smartPunctuation
        if isContinuousSpellCheckingEnabled != (prose && store.spellCheck) { isContinuousSpellCheckingEnabled = prose && store.spellCheck }
        fitColumn(to: frame.width)
        if store.vimMode != (vim != nil) { vim = store.vimMode ? VimEngine() : nil }
        updateFocus()
    }

    @objc private func themeDidChange(_ notification: Notification) {
        applyTheme()
        styler.restyleDocument()
        styler.highlights.recolor()
    }

    override var string: String {
        didSet { redrawViewport() }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        let center = NotificationCenter.default
        center.removeObserver(self, name: NSWindow.didChangeOcclusionStateNotification, object: nil)
        guard let window else { return }
        center.addObserver(self, selector: #selector(redrawViewport), name: NSWindow.didChangeOcclusionStateNotification, object: window)
    }

    /// A note opened while its window is behind can lay its viewport out at TextKit 2's estimates and leave lines
    /// undrawn until a resize; laying the viewport out again after a load and as the window shows draws every line.
    @objc private func redrawViewport() {
        textLayoutManager?.textViewportLayoutController.layoutViewport()
        needsDisplay = true
    }

    /// Rendered diagrams and math take the colors of the appearance they were drawn in.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        styler.restyleDocument()
    }

    /// A window moved to a screen of another scale draws its pictures again at that scale.
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        guard let scale = window?.backingScaleFactor, scale != pictureScale else { return }
        pictureScale = scale
        styler.restyleDocument()
    }

    override func setFrameSize(_ newSize: NSSize) {
        fitColumn(to: newSize.width)
        // A folded stamp under the note's last block hangs below the text.
        super.setFrameSize(NSSize(width: newSize.width, height: max(newSize.height, marks.reach)))
    }

    /// Centers the column at the measure, with margins of at least 32 pt; a narrower view fills. Code blocks and tables
    /// run on to 32 pt from the right edge. Typewriter lets the first and last lines scroll to the middle.
    private func fitColumn(to width: CGFloat) {
        // Code starts at the line numbers, room left for the margin rules of changes.
        if styler.code != nil {
            if textContainerInset != NSSize(width: 24, height: 16) { textContainerInset = NSSize(width: 24, height: 16) }
            return
        }
        let padding = textContainer?.lineFragmentPadding ?? 0
        // The rail's width is kept out of the centering whether or not it takes the view's, overlay or legacy, so the
        // column stays put when the rail shows.
        let room = min(width, (enclosingScrollView?.frame.width ?? width) - Rail.width)
        let margin = max(32, ((room - ThemeStore.shared.measure) / 2 - padding).rounded(.down))
        let top: CGFloat = metaLine == nil ? 24 : 24 + Self.metaRoom
        let height = typewriterMode ? max(top, ((enclosingScrollView?.contentView.bounds.height ?? 0) / 2).rounded()) : top
        if textContainerInset != NSSize(width: margin, height: height) {
            textContainerInset = NSSize(width: margin, height: height)
        }
        if let container = textContainer as? MeasureContainer {
            let prose = max(room - 2 * margin, 0)
            let wide = max(width - margin - 32, prose)
            if container.prose != prose || container.size.width != wide {
                container.prose = prose
                container.size = NSSize(width: wide, height: .greatestFiniteMagnitude)
            }
        }
        placeMeta()
    }

    /// The meta line sits over the column's first line, as wide as the column.
    private func placeMeta() {
        guard let meta, metaLine != nil else { return }
        let padding = textContainer?.lineFragmentPadding ?? 0
        let size = meta.fittingSize
        let width = max((textContainer?.column ?? 0) - 2 * padding, 0)
        meta.frame = NSRect(x: textContainerInset.width + padding, y: textContainerInset.height - Self.metaRoom + 4, width: min(size.width, width), height: size.height)
    }

    /// Draws the fold disclosures, code wells, callouts, each quote's rule at the column's left edge (a callout's well
    /// stands alone), and inline math.
    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        drawDisclosures(in: rect)
        let storage = textStorage!
        guard !styler.showsSource, storage.length > 0, let window else { return }
        let first = characterIndexForInsertion(at: NSPoint(x: rect.minX, y: max(rect.minY, textContainerOrigin.y)))
        let last = characterIndexForInsertion(at: NSPoint(x: rect.maxX, y: max(rect.maxY, textContainerOrigin.y)))
        let visible = storage.mutableString.paragraphRange(for: NSRange(location: min(first, last), length: abs(last - first)))
        func line(at index: Int) -> NSRect {
            convert(window.convertFromScreen(firstRect(forCharacterRange: NSRange(location: index, length: 0), actualRange: nil)), from: nil)
        }
        drawCodeWells(in: visible, line: line(at:))
        drawCodeChips(in: visible)
        drawCallouts(in: visible, line: line(at:))
        ThemeStore.shared.color(.quoteRule).setFill()
        storage.enumerateAttribute(.dewlineQuote, in: visible) { value, range, _ in
            guard value != nil, storage.attribute(.dewlineCallout, at: range.location, effectiveRange: nil) == nil else { return }
            let top = line(at: range.location)
            let bottom = line(at: max(NSMaxRange(range) - 1, range.location))
            NSRect(x: textContainerOrigin.x + (textContainer?.lineFragmentPadding ?? 0), y: top.minY, width: 2, height: bottom.maxY - top.minY).fill()
        }
        drawInlineMath(in: visible, line: line(at:))
    }

    /// Fills a rounded chip behind each code span in `visible`, line by line, under the change marks so a change's
    /// wash and underline run on across it; a `dewline:` link alone in its paragraph gets a button, the accent at 14%
    /// with a 6 pt radius, over the room its kerning leaves each side.
    private func drawCodeChips(in visible: NSRange) {
        let storage = textStorage!
        guard let layout = textLayoutManager, let content = layout.textContentManager else { return }
        let accent = ThemeStore.shared.color(.accent)
        storage.enumerateAttribute(.dewlineCodeChip, in: visible) { value, range, _ in
            guard value != nil, let font = storage.attribute(.font, at: NSMaxRange(range) - 1, effectiveRange: nil) as? NSFont,
                let start = content.location(content.documentRange.location, offsetBy: range.location),
                let end = content.location(start, offsetBy: range.length), let text = NSTextRange(location: start, end: end)
            else { return }
            let button = value as? String == LinkCards.button
            (button ? accent.withAlphaComponent(0.14) : ThemeStore.shared.color(.codeBackground)).setFill()
            layout.enumerateTextSegments(in: text, type: .standard, options: []) { _, frame, baseline, _ in
                guard frame.width >= 0.5 else { return true }
                let (pad, rise, radius): (CGFloat, CGFloat, CGFloat) = button ? (LinkCards.buttonPad, 5, 6) : (1, 2, 3)
                let chip = NSRect(
                    x: frame.minX - pad, y: frame.minY + baseline - font.ascender - rise, width: frame.width + (button ? pad : 2),
                    height: font.ascender - font.descender + 2 * rise
                )
                NSBezierPath(roundedRect: chip.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y), xRadius: radius, yRadius: radius).fill()
                return true
            }
        }
    }

    /// The text's children plus one image per rendered block, labeled with its source, one checkbox per task box, and
    /// the change stamp, removed text and conflict cards over the text.
    override func accessibilityChildren() -> [Any]? {
        var children = (super.accessibilityChildren() ?? []) + subviews.filter { ($0 is ChangeStamp || $0 is Hanging) && !$0.isHidden }
        let storage = textStorage!
        storage.enumerateAttribute(.dewlineBlock, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            switch (value as? BlockLine)?.role {
            case .picture(let picture, let label)?:
                let line = firstRect(forCharacterRange: NSRange(location: range.location, length: 0), actualRange: nil)
                let x = line.minX + picture.x(in: textContainer?.column ?? 0)
                let frame = NSRect(x: x, y: line.maxY - picture.size.height, width: picture.size.width, height: picture.size.height)
                children.append(NSAccessibilityElement.element(withRole: .image, frame: frame, label: label, parent: self))
            case .task(let task)?:
                let box = range.location + task.at
                let frame = firstRect(forCharacterRange: NSRange(location: box, length: 3), actualRange: nil)
                children.append(TaskBoxElement(frame: frame, label: task.label, checked: task.checked, parent: self) { [weak self] in
                    self?.toggleTask(at: box + 1)
                })
            default:
                break
            }
        }
        return children
    }

    /// With Vim on, keys outside insert mode go to Vim and never to the input method; marked text keeps its keys.
    override func keyDown(with event: NSEvent) {
        // ⌘↩ is Keep Change; with no change to keep it does nothing rather than break the line.
        if event.modifierFlags.contains(.command), [36, 76].contains(event.keyCode) { return }
        guard let vim, !hasMarkedText(), !event.modifierFlags.contains(.command) else { return super.keyDown(with: event) }
        let key = Self.vimKey(event)
        if vim.mode == .insert, key != "<Esc>" { return super.keyDown(with: event) }
        if let key { vim.handle(key, in: self) }
        vimDidRun()
    }

    private static func vimKey(_ event: NSEvent) -> String? {
        switch event.keyCode {
        case 53: return "<Esc>"
        case 36, 76: return "<CR>"
        case 51: return "<BS>"
        case 123: return "<Left>"
        case 124: return "<Right>"
        case 125: return "<Down>"
        case 126: return "<Up>"
        default: break
        }
        if event.modifierFlags.contains(.control) {
            switch event.charactersIgnoringModifiers {
            case "r": return "<C-r>"
            case "[": return "<Esc>"
            default: return nil
            }
        }
        guard let characters = event.characters, characters.count == 1, let scalar = characters.unicodeScalars.first,
            scalar.value >= 32, scalar.value != 127, !(0xF700...0xF8FF).contains(scalar.value)
        else { return nil }
        return characters
    }

    func vimDidRun() {
        blockCaret = vim?.mode == .normal
        vimStatus?.stringValue = vim?.status ?? ""
    }

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        // A composition is one undo entry, from its first marked text to its commit.
        if !hasMarkedText() { history.breakCoalescing() }
        composing = true
        history.composing = true
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        composing = false
        if !hasMarkedText() { compositionEnded() }
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        let commits = hasMarkedText()
        composing = commits
        history.typing = true
        super.insertText(string, replacementRange: replacementRange)
        history.typing = false
        composing = false
        if commits { compositionEnded() }
        completeWikilink(after: string)
    }

    override func unmarkText() {
        composing = true
        super.unmarkText()
        composing = false
        compositionEnded()
    }

    /// Keys that edit, such as Delete, coalesce with typing.
    override func doCommand(by selector: Selector) {
        let before = version
        history.typing = true
        super.doCommand(by: selector)
        history.typing = false
        // A key that moves the caret ends the typing.
        if version == before { history.breakCoalescing() }
    }

    override func breakUndoCoalescing() {
        super.breakUndoCoalescing()
        history.breakCoalescing()
    }

    override func cut(_ sender: Any?) {
        history.perform("Cut") { super.cut(sender) }
    }

    override func paste(_ sender: Any?) {
        history.perform("Paste") {
            if styler.code != nil || !pasteHTMLAsMarkdown(from: .general) { super.paste(sender) }
        }
    }

    override func pasteAsPlainText(_ sender: Any?) {
        history.perform("Paste") { super.pasteAsPlainText(sender) }
    }

    override func layout() {
        super.layout()
        let painted = marks.painted
        marks.layoutIfDirty()
        // A change inside hidden markers shows them, after the layout that painted it.
        guard marks.painted != painted else { return }
        RunLoop.main.perform(inModes: [.common]) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.defersStyling else { return }
                self.styler.updateReveal()
            }
        }
    }

    /// The change Keep Change and Revert Change decide: the one under the caret, else the one the stamp shows.
    var changeToDecide: UInt64? {
        marks.changeAtCaret ?? marks.stamped
    }

    /// Cmd-Return.
    @objc func keepChange(_ sender: Any?) {
        if let id = changeToDecide { decide(id, keep: true) }
    }

    /// Option-Cmd-Delete.
    @objc func revertChange(_ sender: Any?) {
        if let id = changeToDecide { decide(id, keep: false) }
    }

    /// Keeps or reverts the one change, then moves to the next one waiting.
    func decide(_ id: UInt64, keep: Bool) {
        guard let live = marks.live, let at = live.changes[id]?.range.location else { return }
        live.decide([id], keep: keep)
        if live.changes[id] == nil { Review.step(from: self, forward: true, at: at) }
    }

    /// Keep and Revert for the change at the caret, as VoiceOver custom actions.
    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        guard let id = changeToDecide, let change = marks.live?.changes[id] else { return super.accessibilityCustomActions() }
        let writer = MarkWriter(change.origin).possessive
        return (super.accessibilityCustomActions() ?? []) + [
            NSAccessibilityCustomAction(name: "Keep \(writer) change") { [weak self] in
                MainActor.assumeIsolated { self?.keepChange(nil) }
                return true
            },
            NSAccessibilityCustomAction(name: "Revert \(writer) change") { [weak self] in
                MainActor.assumeIsolated { self?.revertChange(nil) }
                return true
            },
        ]
    }

    /// Shift-Cmd-Return: keeps every marked change in this file.
    @objc func keepAllChanges(_ sender: Any?) {
        marks.live?.decideAll(keep: true)
    }

    /// Option-Shift-Cmd-Delete: reverts every marked change in this file.
    @objc func revertAllChanges(_ sender: Any?) {
        marks.live?.decideAll(keep: false)
    }

    /// Control-Cmd-Down.
    @objc func nextChange(_ sender: Any?) {
        Review.step(from: self, forward: true)
    }

    /// Control-Cmd-Up.
    @objc func previousChange(_ sender: Any?) {
        Review.step(from: self, forward: false)
    }

    func storageDidEdit(_ range: NSRange, delta: Int) {
        version += 1
        history.didEdit(range, delta: delta)
        edited?(range, delta)
    }

    private func compositionEnded() {
        history.composing = false
        history.breakCoalescing()
        styler.flush()
        inputEnded?()
        if toggleWaits {
            toggleWaits = false
            toggleSource(nil)
        }
    }

    /// Switches between the rendered document and its source, holding the caret's line (or the first visible line) in place.
    @objc func toggleSource(_ sender: Any?) {
        // A code file has no rendering to switch from.
        guard styler.code == nil else { return }
        guard !defersStyling else {
            toggleWaits.toggle()
            return
        }
        snapshot?.removeFromSuperview()
        let storage = textStorage!
        let visible = visibleRect
        // TextKit 2 answers a point in the top inset with an index near the end of the text, so probes stay below the inset.
        func index(_ x: CGFloat, _ y: CGFloat) -> Int {
            characterIndexForInsertion(at: NSPoint(x: x, y: max(y, textContainerOrigin.y)))
        }
        let first = index(visible.minX, visible.minY)
        let last = index(visible.maxX, visible.maxY)
        let caret = selectedRange().location
        let anchor = min(first <= caret && caret <= last ? caret : first, storage.length - 1)
        var offset = baseline(at: anchor).map { $0 - visible.minY }
        // The clip view snaps each landing to the pixel grid, so a line left where the last toggle put it aims for that toggle's offset.
        if let held, let measured = offset, held.anchor == anchor, abs(held.offset - measured) <= 0.5 {
            offset = held.offset
        }
        held = offset.map { (anchor, $0) }
        // The line numbers come and go after the anchor is read and before the picture, so the fade doesn't stretch it.
        showLineNumbers(!styler.showsSource)

        let caretView = subviews.first { $0 is NSTextInsertionIndicator }
        let caretWasHidden = caretView?.isHidden ?? true
        caretView?.isHidden = true
        let picture = bitmapImageRepForCachingDisplay(in: visibleRect)
        if let picture { cacheDisplay(in: visibleRect, to: picture) }
        caretView?.isHidden = caretWasHidden

        // The visible text and as much again on either side change first, so the fade starts before the rest restyles. TextKit 2
        // has no index for a point outside its laid-out viewport, so the margin counts characters, not points.
        let margin = max(last - first, 0)
        let lower = max(first - margin, 0)
        let upper = min(max(first, last) + margin, storage.length)
        styler.toggleSource(restyling: NSRange(location: lower, length: upper - lower))
        if let offset { hold(anchor, at: offset) }
        if let picture {
            let cover = Snapshot(frame: visibleRect)
            cover.wantsLayer = true
            cover.layer?.contents = picture.cgImage
            if let caretView { addSubview(cover, positioned: .below, relativeTo: caretView) } else { addSubview(cover) }
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 1
            fade.toValue = 0
            fade.duration = Motion.current == .off ? 0.15 : 0.3
            fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            CATransaction.setCompletionBlock { MainActor.assumeIsolated { cover.removeFromSuperview() } }
            cover.layer?.opacity = 0
            cover.layer?.add(fade, forKey: nil)
            CATransaction.commit()
            snapshot = cover
        }
        window?.layoutIfNeeded()
        window?.displayIfNeeded()
        CATransaction.flush()
        fadeStarted = .now

        styler.restyleDocument()
        if let offset { hold(anchor, at: offset) }
        snapshot?.frame = visibleRect
        // Typing attributes follow the selection only when it moves, and marked text draws with them before any restyle.
        let neighbor = storage.length > 0 ? storage.attributes(at: max(caret - 1, 0), effectiveRange: nil) : styler.baseAttributes
        for key in [NSAttributedString.Key.font, .foregroundColor, .paragraphStyle] {
            typingAttributes[key] = neighbor[key]
        }
    }

    /// Scrolls so the baseline of the line holding `anchor` sits `offset` below the top of the visible rect.
    func hold(_ anchor: Int, at offset: CGFloat) {
        guard let layout = textLayoutManager else { return }
        let visible = visibleRect
        // TextKit 2 sizes the view and stacks the viewport from estimates it refreshes as it lays the viewport out:
        // lay out, scroll to the line, lay out again, correct. A refresh can leave the clip view a fraction of a pixel
        // off the grid, where a scroll to a point lands up to a pixel from it, so the scroll moves by whole pixels and
        // lands within half of one.
        let pixel = 1 / (window?.backingScaleFactor ?? 1)
        for _ in 0..<2 {
            layout.textViewportLayoutController.layoutViewport()
            guard let now = baseline(at: anchor) else { return }
            let top = visibleRect.minY
            scroll(NSPoint(x: visible.minX, y: top + ((now - offset - top) / pixel).rounded() * pixel))
        }
    }

    /// The one-range form calls this one, and Find's replace calls only this one.
    override func shouldChangeText(inRanges affectedRanges: [NSValue], replacementStrings: [String]?) -> Bool {
        let changes = super.shouldChangeText(inRanges: affectedRanges, replacementStrings: replacementStrings)
        if changes, let replacementStrings {
            history.willEdit(affectedRanges.map(\.rangeValue), with: replacementStrings)
        }
        if changes, affectedRanges.count == 1, let string = replacementStrings?.first {
            styler.landing = affectedRanges[0].rangeValue.location + string.utf16.count
        } else {
            styler.landing = nil
        }
        return changes
    }

    override func didChangeText() {
        history.didChangeText()
        snapshot?.removeFromSuperview()
        codeBar.show(block: nil)
        super.didChangeText()
        updateFocus()
    }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        guard !stillSelecting else { return }
        marks.caretMoved()
        updateFocus()
        centerCaretSoon()
    }

    /// Return breaks the line with CRLF in a note whose lines end that way.
    override func insertNewline(_ sender: Any?) {
        guard hasMarkedText() || !continueList() else { return }
        if !hasMarkedText(), lineBreak == "\r\n" {
            insertText("\r\n", replacementRange: selectedRange())
        } else {
            super.insertNewline(sender)
        }
    }

    /// `text` with each LF as CRLF in a note whose lines end that way.
    func withLineBreaks(_ text: String) -> String {
        guard lineBreak == "\r\n" else { return text }
        var scalars = String.UnicodeScalarView()
        var last: Unicode.Scalar?
        for scalar in text.unicodeScalars {
            if scalar == "\n", last != "\r" { scalars.append("\r") }
            scalars.append(scalar)
            last = scalar
        }
        return String(scalars)
    }

    /// The break that ends the caret's line, or the line above on the last line; empty when neither has one.
    private var lineBreak: String {
        let text = textStorage!.mutableString
        var (start, end, contentsEnd) = (0, 0, 0)
        text.getLineStart(&start, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: selectedRange().location, length: 0))
        if end == contentsEnd, start > 0 {
            text.getLineStart(nil, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: start - 1, length: 0))
        }
        return text.substring(with: NSRange(location: contentsEnd, length: end - contentsEnd))
    }

    override func insertTab(_ sender: Any?) {
        if let codeIndent, !hasMarkedText() { return insertText(codeIndent, replacementRange: selectedRange()) }
        guard hasMarkedText() || !(editTable(.nextCell) || indentItems(outdent: false)) else { return }
        let width = ThemeStore.shared.tabWidth
        if width > 0, !hasMarkedText() {
            insertText(String(repeating: " ", count: width), replacementRange: selectedRange())
        } else {
            super.insertTab(sender)
        }
    }

    override func insertBacktab(_ sender: Any?) {
        guard hasMarkedText() || !(editTable(.previousCell) || indentItems(outdent: true)) else { return }
        super.insertBacktab(sender)
    }

    /// Dims, by color alone, the text outside the caret's block, without touching the storage.
    private func updateFocus() {
        guard focusMode || dimmed, let layout = textLayoutManager, let content = layout.textContentManager else { return }
        layout.removeRenderingAttribute(.foregroundColor, for: content.documentRange)
        dimmed = false
        let length = textStorage?.length ?? 0
        guard focusMode, length > 0 else { return }
        dimmed = true
        let caret = selectedRange().location
        let focus = styler.map.blocks(in: NSRange(location: caret, length: 0)).first?.range
            ?? textStorage!.mutableString.paragraphRange(for: NSRange(location: min(caret, length), length: 0))
        let dim = ThemeStore.shared.color(.syntax)
        for part in [NSRange(location: 0, length: focus.location), NSRange(location: NSMaxRange(focus), length: length - NSMaxRange(focus))] where part.length > 0 {
            guard let start = content.location(content.documentRange.location, offsetBy: part.location),
                let end = content.location(start, offsetBy: part.length), let range = NSTextRange(location: start, end: end)
            else { continue }
            layout.addRenderingAttribute(.foregroundColor, value: dim, for: range)
        }
    }

    /// Centers the caret's line after the event in hand has laid the text out. The view snaps there: edits and caret
    /// moves never animate, so Reduce Motion needs no other path.
    private func centerCaretSoon() {
        guard typewriterMode, !centering else { return }
        centering = true
        RunLoop.main.perform(inModes: [.common]) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.centering = false
                let length = self.textStorage!.length
                guard self.typewriterMode, length > 0 else { return }
                self.hold(min(self.selectedRange().location, length - 1), at: self.visibleRect.height / 2 + MarkdownStyler.bodyFont.capHeight / 2)
            }
        }
    }

    @objc func toggleFocusMode(_ sender: Any?) {
        focusMode.toggle()
    }

    @objc func toggleTypewriterMode(_ sender: Any?) {
        typewriterMode.toggle()
    }

    @objc func toggleSmartPunctuation(_ sender: Any?) {
        ThemeStore.shared.smartPunctuation.toggle()
    }

    /// Cmd-click follows a link, wikilink, embed, footnote or tag; a plain click follows a dewline: link. A click in the margin beside a foldable block folds or
    /// unfolds it; a click on a task box toggles it and leaves the caret where it was.
    override func mouseDown(with event: NSEvent) {
        history.breakCoalescing()
        let point = convert(event.locationInWindow, from: nil)
        if event.modifierFlags.contains(.command) || link(at: point)?.url?.scheme?.lowercased() == "dewline", follow(at: point) { return }
        if let box = taskBox(at: point) { return toggleTask(at: box) }
        guard point.x < textContainerOrigin.x, let (block, _) = foldable(at: point) else { return super.mouseDown(with: event) }
        let anchor = NSMaxRange(textStorage!.mutableString.lineRange(for: NSRange(location: block.range.location, length: 0)))
        if styler.folds.contains(where: { $0.location == anchor }) {
            styler.setFolds(styler.folds.filter { $0.location != anchor })
        } else {
            fold(block)
        }
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self && area.userInfo?["fold"] != nil { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: ["fold": true]))
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        let point = convert(event.locationInWindow, from: nil)
        hoverFootnote(at: point)
        hoverCode(at: point)
        if link(at: point)?.url?.scheme?.lowercased() == "dewline" { NSCursor.pointingHand.set() }
        let hovered = point.x < textContainerOrigin.x + (textContainer?.size.width ?? 0) ? foldable(at: point)?.block.range.location : nil
        guard hovered != hoveredFold else { return }
        hoveredFold = hovered
        setNeedsDisplay(NSRect(x: 0, y: visibleRect.minY, width: textContainerOrigin.x, height: visibleRect.height))
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        hoverCode(at: nil)
        guard hoveredFold != nil else { return }
        hoveredFold = nil
        setNeedsDisplay(NSRect(x: 0, y: visibleRect.minY, width: textContainerOrigin.x, height: visibleRect.height))
    }

    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        super.readablePasteboardTypes + (Self.kept.map { NSPasteboard.PasteboardType($0.identifier) } + [.tiff, .fileURL]).filter { !super.readablePasteboardTypes.contains($0) }
    }

    /// Text pasted or dropped into a note whose lines end in CRLF takes CRLF.
    override func readSelection(from pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        if insertImages(from: pboard) { return true }
        guard type == .string, lineBreak == "\r\n", let text = pboard.string(forType: .string) else {
            return super.readSelection(from: pboard, type: type)
        }
        replace(selectedRange(), with: withLineBreaks(text))
        return true
    }

    /// Replaces `range` with `text` as one undoable edit of its own, named `name` in the Edit menu.
    func replaceAsOneEdit(_ range: NSRange, with text: String, named name: String = "") {
        history.perform(name) {
            guard shouldChangeText(in: range, replacementString: text) else { return }
            textStorage!.replaceCharacters(in: range, with: text)
            didChangeText()
        }
    }

    /// The baseline of the line holding the character at `index`, in this view's coordinates.
    func baseline(at index: Int) -> CGFloat? {
        guard index >= 0, index < textStorage!.length, let layout = textLayoutManager, let content = layout.textContentManager,
            let location = content.location(content.documentRange.location, offsetBy: index)
        else { return nil }
        layout.ensureLayout(for: NSTextRange(location: location))
        guard let fragment = layout.textLayoutFragment(for: location) else { return nil }
        let offset = content.offset(from: fragment.rangeInElement.location, to: location)
        guard let line = fragment.textLineFragments.first(where: { NSLocationInRange(offset, $0.characterRange) }) else { return nil }
        return textContainerOrigin.y + fragment.layoutFragmentFrame.minY + line.typographicBounds.minY + line.glyphOrigin.y
    }

    /// Runs the `MarkdownFormat` command in the sender's tag as one undoable edit named for it.
    @objc func format(_ sender: Any?) {
        guard !hasMarkedText(), let command = (sender as? NSMenuItem).flatMap({ MarkdownFormat(rawValue: $0.tag) }),
            let edit = command.edit(in: textStorage!.mutableString, selection: selectedRange())
        else { return }
        history.perform(command.name) {
            guard shouldChangeText(in: edit.range, replacementString: edit.replacement) else { return }
            textStorage!.replaceCharacters(in: edit.range, with: edit.replacement)
            setSelectedRange(edit.selection)
            didChangeText()
        }
    }

    /// Runs `command` in the table holding the caret, moving to a cell or editing as one undoable edit named for it.
    /// False outside a table.
    func editTable(_ command: TableEditing) -> Bool {
        let selection = selectedRange()
        guard let table = styler.tables.range(at: selection.location),
            let edit = command.edit(in: textStorage!.mutableString, table: table, selection: selection)
        else { return false }
        if edit.range.length == 0, edit.replacement.isEmpty {
            setSelectedRange(edit.selection)
            scrollRangeToVisible(edit.selection)
            return true
        }
        history.perform(command.name) {
            guard shouldChangeText(in: edit.range, replacementString: edit.replacement) else { return }
            textStorage!.replaceCharacters(in: edit.range, with: edit.replacement)
            setSelectedRange(edit.selection)
            didChangeText()
        }
        return true
    }

    /// Format > Insert Row Above, Row Below, Column Left and Column Right, by the `TableEditing` in the sender's tag.
    @objc func editTableItem(_ sender: Any?) {
        guard !hasMarkedText(), let command = (sender as? NSMenuItem).flatMap({ TableEditing(rawValue: $0.tag) }), editTable(command) else {
            return NSSound.beep()
        }
    }

    override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(format(_:)) { return isEditable }
        if menuItem.action == #selector(editTableItem(_:)) { return isEditable && styler.tables.range(at: selectedRange().location) != nil }
        if menuItem.action == #selector(keepChange(_:)) || menuItem.action == #selector(revertChange(_:)) {
            return changeToDecide != nil
        }
        switch menuItem.action {
        case #selector(keepAllChanges(_:)), #selector(revertAllChanges(_:)):
            return marks.live?.changes.values.contains(where: \.marked) == true
        case #selector(nextChange(_:)), #selector(previousChange(_:)):
            return Review.hasMarked(in: window)
        case #selector(toggleSource(_:)): menuItem.state = styler.showsSource ? .on : .off
        case #selector(toggleFocusMode(_:)): menuItem.state = focusMode ? .on : .off
        case #selector(toggleTypewriterMode(_:)): menuItem.state = typewriterMode ? .on : .off
        case #selector(toggleSmartPunctuation(_:)): menuItem.state = ThemeStore.shared.smartPunctuation ? .on : .off
        case #selector(unfoldBlock(_:)), #selector(unfoldAll(_:)): return !styler.folds.isEmpty
        default: return super.validateMenuItem(menuItem)
        }
        return true
    }
}

extension EditorTextView: VimHost {
    var vimText: NSString { textStorage!.mutableString }

    var vimSelection: NSRange {
        get { selectedRange() }
        set {
            setSelectedRange(newValue)
            scrollRangeToVisible(newValue)
        }
    }

    var vimClipboard: String? {
        get { NSPasteboard.general.string(forType: .string) }
        set {
            NSPasteboard.general.clearContents()
            if let newValue { NSPasteboard.general.setString(newValue, forType: .string) }
        }
    }

    /// Through shouldChangeText and didChangeText, as typing goes, so the styler, the change engine and undo see it.
    func vimReplace(_ range: NSRange, with string: String) {
        breakUndoCoalescing()
        guard shouldChangeText(in: range, replacementString: string) else { return }
        textStorage!.replaceCharacters(in: range, with: NSAttributedString(string: string, attributes: styler.baseAttributes))
        didChangeText()
    }

    func vimUndo() {
        history.undoManager.undo()
    }

    func vimRedo() {
        history.undoManager.redo()
    }

    func vimSave() {
        NSApp.sendAction(#selector(NSDocument.save(_:)), to: nil, from: self)
    }

    func vimClose() {
        window?.performClose(nil)
    }
}

/// The frame before a toggle, fading out over the new one; clicks go through to the text.
private final class Snapshot: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

/// The text container, as wide as the view less its margins on the left and 32 pt on the right. A fenced code
/// block's lines and a laid-out table's rows take its width; every other paragraph wraps at the measure, so it keeps
/// to `prose`, the column the margins center.
final class MeasureContainer: NSTextContainer {
    var prose = CGFloat.greatestFiniteMagnitude

    /// Sets each paragraph of `styled` but a fenced code block's and a laid-out table row's to wrap `measure` points
    /// from the column's start; a narrower container wraps it at its own width.
    static func keepProse(_ styled: NSMutableAttributedString, to measure: CGFloat) {
        let text = styled.mutableString
        var narrowed: [NSParagraphStyle: NSParagraphStyle] = [:]
        var at = 0
        while at < styled.length {
            let paragraph = text.paragraphRange(for: NSRange(location: at, length: 0))
            at = NSMaxRange(paragraph)
            if styled.attribute(.dewlineCode, at: paragraph.location, effectiveRange: nil) != nil { continue }
            if case .table = (styled.attribute(.dewlineBlock, at: paragraph.location, effectiveRange: nil) as? BlockLine)?.role { continue }
            styled.enumerateAttribute(.paragraphStyle, in: paragraph) { value, run, _ in
                let style = value as? NSParagraphStyle ?? .default
                let narrow = narrowed[style] ?? {
                    let copy = style.mutableCopy() as! NSMutableParagraphStyle
                    copy.tailIndent = measure
                    narrowed[style] = copy
                    return copy
                }()
                styled.addAttribute(.paragraphStyle, value: narrow, range: run)
            }
        }
    }
}

extension NSTextContainer {
    /// The width prose lays out in: the measure's column, which code blocks and tables may run past.
    var column: CGFloat {
        min((self as? MeasureContainer)?.prose ?? size.width, size.width)
    }
}

extension NSAttributedString.Key {
    /// Marks a block quote's paragraph, which draws a rule at the column's left edge.
    static let dewlineQuote = NSAttributedString.Key("DewlineQuote")
}

/// The layout manager's delegate: `BlockFragments` lays out drawn blocks, a list item with a hidden bullet draws its
/// dot with its own line, so the dot moves whenever the line does, and no line breaks between a hidden marker and the
/// text it closes, such as a code span's closing backtick and the period after it.
private final class Fragments: NSObject, NSTextLayoutManagerDelegate {
    private let blocks = BlockFragments()

    func textLayoutManager(
        _ textLayoutManager: NSTextLayoutManager,
        textLayoutFragmentFor location: any NSTextLocation,
        in textElement: NSTextElement
    ) -> NSTextLayoutFragment {
        guard let paragraph = textElement as? NSTextParagraph, paragraph.attributedString.length > 0,
            paragraph.attributedString.attribute(.dewlineBlock, at: 0, effectiveRange: nil) == nil
        else { return blocks.textLayoutManager(textLayoutManager, textLayoutFragmentFor: location, in: textElement) }
        guard let bullet = BulletFragment.bullet(in: paragraph.attributedString) else {
            return NSTextLayoutFragment(textElement: textElement, range: textElement.elementRange)
        }
        return BulletFragment(bullet: bullet, textElement: textElement)
    }

    func textLayoutManager(_ textLayoutManager: NSTextLayoutManager, shouldBreakLineBefore location: any NSTextLocation, hyphenating: Bool) -> Bool {
        guard let content = textLayoutManager.textContentManager as? NSTextContentStorage, let storage = content.textStorage else { return true }
        let at = content.offset(from: content.documentRange.location, to: location)
        guard at > 0, at < storage.length, (storage.attribute(.font, at: at, effectiveRange: nil) as? NSFont)?.pointSize ?? 1 < 1 else { return true }
        return [0x20, 0x09, 0x0A, 0x0D, 0xA0].contains(storage.mutableString.character(at: at - 1))
    }
}

/// A list item's paragraph whose `-`, `*` or `+` marker is hidden: a dot in `ink2` centered over the marker.
private final class BulletFragment: NSTextLayoutFragment {
    /// The marker's offset in the paragraph.
    private let bullet: Int

    init(bullet: Int, textElement: NSTextElement) {
        self.bullet = bullet
        super.init(textElement: textElement, range: textElement.elementRange)
    }

    required init?(coder: NSCoder) {
        fatalError("BulletFragment is built in code")
    }

    /// The hidden bullet in `paragraph`, past its indent and any quote markers, that keeps its room and is followed by
    /// a space: the styler hides an item's marker that way and no other text.
    static func bullet(in paragraph: NSAttributedString) -> Int? {
        let text = paragraph.string as NSString
        var at = 0
        while at < text.length, [0x20, 0x09, 0x3E].contains(text.character(at: at)) { at += 1 }
        guard at + 1 < text.length, [0x2D, 0x2A, 0x2B].contains(text.character(at: at)), [0x20, 0x09].contains(text.character(at: at + 1)),
            paragraph.attribute(.foregroundColor, at: at, effectiveRange: nil) as? NSColor == NSColor.clear,
            (paragraph.attribute(.font, at: at, effectiveRange: nil) as? NSFont)?.pointSize ?? 0 > 1
        else { return nil }
        return at
    }

    override func draw(at point: CGPoint, in context: CGContext) {
        super.draw(at: point, in: context)
        guard let line = textLineFragments.first(where: { NSLocationInRange(bullet, $0.characterRange) }),
            let font = line.attributedString.attribute(.font, at: bullet, effectiveRange: nil) as? NSFont
        else { return }
        let color = MainActor.assumeIsolated { ThemeStore.shared.color(.ink2) }
        let dot = NSAttributedString(string: "\u{2022}", attributes: [.font: font, .foregroundColor: color])
        let bounds = line.typographicBounds
        let left = line.locationForCharacter(at: bullet).x
        let right = line.locationForCharacter(at: bullet + 1).x
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        dot.draw(at: CGPoint(
            x: point.x + bounds.minX + left + ((right - left - dot.size().width) / 2).rounded(),
            y: point.y + bounds.minY + line.glyphOrigin.y - font.ascender))
        NSGraphicsContext.restoreGraphicsState()
    }
}
