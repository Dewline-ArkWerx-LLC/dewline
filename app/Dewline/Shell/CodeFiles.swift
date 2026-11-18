import AppKit

/// Source and config files, which open as highlighted code while Settings > Editor's "Open code files" is on. Off,
/// they list and open as they always did.
enum CodeFile {
    static let key = "DewlineOpenCodeFiles"

    /// The highlighting pack's 50 languages by extension, Markdown aside, with JSON, YAML, TOML and INI. Launch
    /// Services gets the same list from project.yml.
    static let extensions: Set<String> = [
        "py", "pyi", "pyw", "js", "jsx", "mjs", "cjs", "ts", "tsx", "cts", "java", "c", "h", "cpp", "cc", "cxx", "c++",
        "hpp", "hh", "hxx", "cs", "go", "rs", "php", "rb", "swift", "kt", "kts", "scala", "sc", "r", "dart", "lua", "pl",
        "pm", "hs", "ex", "exs", "erl", "hrl", "clj", "cljs", "cljc", "fs", "fsx", "fsi", "ml", "mli", "jl", "m", "mm",
        "groovy", "gradle", "ps1", "psm1", "sh", "bash", "zsh", "fish", "sql", "html", "htm", "css", "scss", "sass",
        "json", "jsonc", "json5", "yaml", "yml", "toml", "xml", "mk", "cmake", "graphql", "gql", "proto", "tf", "hcl",
        "nix", "zig", "diff", "patch", "tex", "asm", "s", "ini", "dockerfile",
    ]

    /// Files known by their whole name, lowercased, and the language each is highlighted as.
    private static let names = [
        "dockerfile": "dockerfile", "containerfile": "dockerfile", "makefile": "makefile", "gnumakefile": "makefile",
        "cmakelists.txt": "cmake",
    ]

    /// Whether code files open, read from the defaults so a listing off the main thread can ask.
    static var isOn: Bool {
        UserDefaults.standard.bool(forKey: key)
    }

    /// The language `url` is highlighted as: its extension, or "dockerfile" for a Dockerfile; nil when it isn't code.
    static func language(of url: URL) -> String? {
        let name = url.lastPathComponent.lowercased()
        if let language = names[name] { return language }
        let ext = url.pathExtension.lowercased()
        return extensions.contains(ext) ? ext : nil
    }

    /// The language of a code file that opens as code now; nil for a note, or for any file while the setting is off.
    static func opened(_ url: URL) -> String? {
        isOn ? language(of: url) : nil
    }

    /// Why `url` doesn't open: it is code and the setting is off.
    static func refusal(_ url: URL) -> CocoaError? {
        guard !isOn, !FolderEntry(url: url, isFolder: false).isMarkdown, let language = language(of: url) else { return nil }
        return CocoaError(.fileReadUnknown, userInfo: [
            NSURLErrorKey: url,
            NSLocalizedDescriptionKey: "Dewline didn\u{2019}t open \u{201C}\(url.lastPathComponent)\u{201D}.",
            NSLocalizedRecoverySuggestionErrorKey: "Turn on Open code files in Settings to open \(language) files.",
        ])
    }

    /// What Tab inserts in `text`: a tab when more lines start with a tab than with spaces, else the step its
    /// space-indented lines most often deepen by. Nil when no line is indented.
    static func indentation(of text: String) -> String? {
        var tabs = 0
        var steps: [Int: Int] = [:]
        var last = 0
        for line in text.split(whereSeparator: \.isNewline) where !line.allSatisfy(\.isWhitespace) {
            if line.first == "\t" {
                tabs += 1
                continue
            }
            let spaces = line.prefix { $0 == " " }.count
            if spaces > last { steps[spaces - last, default: 0] += 1 }
            last = spaces
        }
        let spaced = steps.values.reduce(0, +)
        guard tabs > 0 || spaced > 0 else { return nil }
        if tabs > spaced { return "\t" }
        let step = steps.max { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }!.key
        return String(repeating: " ", count: min(step, 8))
    }

    /// The name of a code file in the sidebar and Quick Open: a little dimmer than a note's, between `ink` and `ink2`,
    /// so it keeps `ink2`'s contrast.
    @MainActor static var ink: NSColor {
        Chrome.color(.ink).blended(withFraction: 0.5, of: Chrome.color(.ink2)) ?? Chrome.color(.ink2)
    }
}

/// A code file's line numbers, in SF Mono `ink3` left of the text, one per paragraph: code mode wraps no line.
final class LineNumbers: NSRulerView {
    private weak var textView: EditorTextView?
    /// The UTF-16 offset each line starts at, until the text changes.
    private var starts: [Int]?

    init(textView: EditorTextView, in scrollView: NSScrollView) {
        self.textView = textView
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = textView
        // Every edit, the text set on opening and an outside write's landing too.
        NotificationCenter.default.addObserver(self, selector: #selector(textChanged(_:)), name: NSTextStorage.didProcessEditingNotification, object: textView.textStorage)
        NotificationCenter.default.addObserver(self, selector: #selector(redraw), name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        scrollView.contentView.postsBoundsChangedNotifications = true
        fit()
    }

    required init(coder: NSCoder) {
        fatalError("LineNumbers is built in code")
    }

    override var isFlipped: Bool { true }

    private var font: NSFont {
        Chrome.mono(11)
    }

    @objc private func textChanged(_ notification: Notification) {
        guard (notification.object as? NSTextStorage)?.editedMask.contains(.editedCharacters) == true else { return }
        starts = nil
        fit()
        needsDisplay = true
    }

    @objc private func redraw() {
        needsDisplay = true
    }

    /// Wide enough for the last line's number and 8 pt either side.
    private func fit() {
        let digits = String(max(lineStarts().count, 100)).count
        let width = ceil(CGFloat(digits) * NSAttributedString(string: "0", attributes: [.font: font]).size().width) + 16
        if ruleThickness != width { ruleThickness = width }
    }

    /// Where each line starts, as TextKit splits paragraphs: after a line feed, a lone carriage return, CRLF or U+2029.
    func lineStarts() -> [Int] {
        if let starts { return starts }
        let text = textView?.textStorage?.mutableString ?? ""
        var found = [0]
        var buffer = [unichar](repeating: 0, count: 1 << 16)
        var at = 0
        var afterCR = false
        while at < text.length {
            let count = min(buffer.count, text.length - at)
            text.getCharacters(&buffer, range: NSRange(location: at, length: count))
            for index in 0..<count {
                let character = buffer[index]
                if afterCR, character != 0x0A { found.append(at + index) }
                afterCR = character == 0x0D
                if character == 0x0A || character == 0x2029 { found.append(at + index + 1) }
            }
            at += count
        }
        if afterCR { found.append(text.length) }
        starts = found
        return found
    }

    override func draw(_ dirtyRect: NSRect) {
        ThemeStore.shared.color(.paper).setFill()
        dirtyRect.fill()
        drawHashMarksAndLabels(in: dirtyRect)
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView, let layout = textView.textLayoutManager, let content = layout.textContentManager,
            let viewport = layout.textViewportLayoutController.viewportRange
        else { return }
        let starts = lineStarts()
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: ThemeStore.shared.color(.ink3)]
        let origin = textView.textContainerOrigin
        layout.enumerateTextLayoutFragments(from: viewport.location) { fragment in
            guard fragment.rangeInElement.location.compare(viewport.endLocation) == .orderedAscending else { return false }
            let offset = content.offset(from: content.documentRange.location, to: fragment.rangeInElement.location)
            var (low, high) = (0, starts.count)
            while low < high {
                let middle = (low + high) / 2
                if starts[middle] <= offset { low = middle + 1 } else { high = middle }
            }
            guard let line = fragment.textLineFragments.first else { return true }
            let baseline = origin.y + fragment.layoutFragmentFrame.minY + line.typographicBounds.minY + line.glyphOrigin.y
            let y = convert(NSPoint(x: 0, y: baseline), from: textView).y
            let number = NSAttributedString(string: "\(low)", attributes: attributes)
            number.draw(at: NSPoint(x: ruleThickness - 8 - number.size().width, y: y - font.ascender))
            return true
        }
    }
}
