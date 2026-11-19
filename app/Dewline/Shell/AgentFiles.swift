import AppKit
import MdCore

/// The front matter's top-level fields on one line, "name: reviewer · description: Reviews diffs", or nil when
/// `text` opens with none. Read as text, never re-serialized.
func frontMatterLine(of text: String) -> String? {
    var lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
    guard lines.first == "---" else { return nil }
    lines.removeFirst()
    guard let end = lines.firstIndex(where: { $0 == "---" || $0 == "..." }) else { return nil }
    let fields = lines[..<end].compactMap { line -> String? in
        guard let first = line.first, !" \t-#".contains(first), let colon = line.firstIndex(of: ":") else { return nil }
        let key = line[..<colon].trimmingCharacters(in: .whitespaces)
        let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        return value.isEmpty || value == "|" || value == ">" ? key : "\(key): \(value)"
    }
    return fields.isEmpty ? nil : fields.joined(separator: " · ")
}

/// A page for a file with front matter: its fields on one read-only line above the editor.
@MainActor
func frontMatterPage(_ line: String, above scrollView: NSScrollView) -> NSView {
    let page = PaperView()
    let label = NSTextField(labelWithString: line)
    label.font = .systemFont(ofSize: 11)
    label.textColor = .secondaryLabelColor
    label.lineBreakMode = .byTruncatingTail
    label.isSelectable = true
    label.toolTip = line
    label.setAccessibilityLabel("Front matter, read-only: " + line)
    label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    let rule = NSBox()
    rule.boxType = .separator
    for view in [label, rule, scrollView] {
        view.translatesAutoresizingMaskIntoConstraints = false
        page.addSubview(view)
    }
    NSLayoutConstraint.activate([
        label.topAnchor.constraint(equalTo: page.topAnchor, constant: 8),
        label.leadingAnchor.constraint(equalTo: page.leadingAnchor, constant: 16),
        label.trailingAnchor.constraint(lessThanOrEqualTo: page.trailingAnchor, constant: -16),
        rule.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 8),
        rule.leadingAnchor.constraint(equalTo: page.leadingAnchor),
        rule.trailingAnchor.constraint(equalTo: page.trailingAnchor),
        scrollView.topAnchor.constraint(equalTo: rule.bottomAnchor),
        scrollView.leadingAnchor.constraint(equalTo: page.leadingAnchor),
        scrollView.trailingAnchor.constraint(equalTo: page.trailingAnchor),
        scrollView.bottomAnchor.constraint(equalTo: page.bottomAnchor),
    ])
    return page
}
