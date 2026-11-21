import AppKit

/// The hovered code block's language and a Copy button, at the well's top right in Live: the label in SF Mono `ink2`,
/// the button filled `Chrome.hover` under the pointer. Copy puts the code between the fences on the pasteboard.
@MainActor
final class CodeBar: NSView {
    private let label = NSTextField(labelWithString: "")
    private let copy = CopyButton()
    /// The code between the hovered block's fences.
    private var code = ""
    /// The hovered block's fenced span start, nil while the pointer is off every block.
    private(set) var block: Int?
    var pasteboard = NSPasteboard.general
    var language: String { label.stringValue }

    init() {
        super.init(frame: .zero)
        label.font = Chrome.mono(11)
        copy.target = self
        copy.action = #selector(copyCode)
        let row = NSStackView(views: [label, copy])
        row.spacing = 6
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        alphaValue = 0
        isHidden = true
        NotificationCenter.default.addObserver(self, selector: #selector(themeDidChange), name: ThemeStore.didChange, object: ThemeStore.shared)
        themeDidChange()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Shows the bar for the block at `block` in `language` at the top right of `well`, or hides it for nil.
    func show(block: Int?, language: String = "", code: String = "", well: NSRect = .zero) {
        guard block != self.block else { return }
        self.block = block
        guard block != nil else { return fade(in: false) }
        self.code = code
        label.stringValue = language
        label.isHidden = language.isEmpty
        copy.title = "Copy"
        let size = fittingSize
        frame = NSRect(x: well.maxX - size.width - 8, y: well.minY + 4, width: size.width, height: 20)
        fade(in: true)
    }

    private func fade(in shown: Bool) {
        if shown { isHidden = false }
        guard Motion.current != .off else {
            alphaValue = shown ? 1 : 0
            isHidden = !shown
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            animator().alphaValue = shown ? 1 : 0
        } completionHandler: {
            MainActor.assumeIsolated {
                if self.block == nil { self.isHidden = true }
            }
        }
    }

    @objc func copyCode() {
        pasteboard.clearContents()
        pasteboard.setString(code, forType: .string)
        copy.title = "Copied"
    }

    @objc private func themeDidChange() {
        label.textColor = Chrome.color(.ink2)
        copy.needsDisplay = true
    }

    override var isFlipped: Bool { true }
}

/// "Copy" in SF Mono `ink2` on a 4 pt rounded `Chrome.hover` fill while the pointer is on it.
private final class CopyButton: NSButton {
    private var hovering = false {
        didSet { needsDisplay = true }
    }

    init() {
        super.init(frame: .zero)
        isBordered = false
        setAccessibilityLabel("Copy code")
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var title: String {
        didSet { invalidateIntrinsicContentSize() }
    }

    private var attributes: [NSAttributedString.Key: Any] {
        [.font: Chrome.mono(11), .foregroundColor: Chrome.color(.ink2)]
    }

    override var intrinsicContentSize: NSSize {
        let size = (title as NSString).size(withAttributes: attributes)
        return NSSize(width: ceil(size.width) + 12, height: 20)
    }

    override func draw(_ dirtyRect: NSRect) {
        if hovering {
            Chrome.hover.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4).fill()
        }
        let size = (title as NSString).size(withAttributes: attributes)
        (title as NSString).draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2), withAttributes: attributes)
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
    }
}

extension EditorTextView {
    /// Shows the code bar over the fenced block under `point` in Live, or hides it.
    func hoverCode(at point: NSPoint?) {
        guard let point, !styler.showsSource, let storage = textStorage, storage.length > 0, let window else { return codeBar.show(block: nil) }
        let index = min(characterIndexForInsertion(at: point), storage.length - 1)
        var whole = NSRange()
        guard let start = storage.attribute(.dewlineCode, at: index, longestEffectiveRange: &whole, in: NSRange(location: 0, length: storage.length)) as? Int,
            let fence = styler.map.blocks(touching: NSRange(location: start, length: 0)).lazy
                .flatMap({ block in block.spans.map { $0.shifted(by: block.range.location) } })
                .first(where: { $0.kind == .fencedCode && $0.range.location == start })
        else { return codeBar.show(block: nil) }
        func line(_ at: Int) -> NSRect {
            convert(window.convertFromScreen(firstRect(forCharacterRange: NSRange(location: at, length: 0), actualRange: nil)), from: nil)
        }
        let padding = textContainer?.lineFragmentPadding ?? 0
        let (top, bottom) = (line(whole.location), line(max(NSMaxRange(whole) - 1, whole.location)))
        let well = NSRect(x: textContainerOrigin.x + padding, y: top.minY, width: (textContainer?.size.width ?? 0) - 2 * padding, height: bottom.maxY - top.minY)
        guard well.contains(point) else { return codeBar.show(block: nil) }
        let text = storage.mutableString
        let opening = text.lineRange(for: NSRange(location: fence.range.location, length: 0))
        codeBar.show(
            block: start, language: CodeHighlights.language(text.substring(with: opening).trimmingCharacters(in: .newlines)),
            code: text.substring(with: fence.content), well: well
        )
    }
}
