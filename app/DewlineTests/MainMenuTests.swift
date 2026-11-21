import AppKit
import Testing
@testable import Dewline

/// The menu bar is the one table of Dewline's shortcuts: these tests check it and write docs/keyboard.md from it.
@MainActor
struct MainMenuTests {
    /// Shortcuts macOS and AppKit keep for themselves, from Apple's "Mac keyboard shortcuts"
    /// (https://support.apple.com/en-us/102650, published 14 September 2026), and ⌘F5, which turns VoiceOver on and off
    /// (https://support.apple.com/guide/voiceover/general-commands-cpvokys01/mac). The page's other app shortcuts (⌘C,
    /// ⌘Q, Help's ⇧⌘?…) belong to the standard items that use them, so they are not here.
    private static let reserved: Set<String> = [
        "⌘Space", "⌥⌘Space", "⇧⌘Space", "⌃⌘Space", "⌃Space",  // Spotlight, Siri, Character Viewer, input sources
        "⌘⇥", "⌘`", "⇧⌘`", "⌥⌘`", "⌃⇥", "⌃⇧⇥",  // switching apps, windows and controls
        "⇧⌘3", "⇧⌘4", "⇧⌘5", "⇧⌘6",  // screenshots, Siri
        "⌥⌘⎋", "⌃⌘Q", "⇧⌘Q", "⌥⇧⌘Q",  // Force Quit, lock, log out
        "⌃⌘F", "⌥⌘W", "⌥⌘M",  // full screen, close all windows, minimize all windows
        "⌃⌘D", "⌥⌘D", "F11",  // Look Up, the Dock, the desktop
        "⌃↑", "⌃↓", "⌃←", "⌃→",  // Mission Control, keyboard focus
        "⌃F2", "⌃F3", "⌃F4", "⌃F5", "⌃F6", "⌃⇧F6", "⌃F7", "⌃F8",  // keyboard focus
        "⌘F5", "⌥⌘F5",  // VoiceOver, Accessibility Shortcuts
    ]

    /// The items with a shortcut in the menu bar MainMenu builds, in menu order. AppKit's own additions, such as
    /// Emoji & Symbols, and hidden alternates such as Zoom In's ⌘= are not in it.
    private func shortcuts() -> [(path: String, title: String, key: KeyEquivalent)] {
        var found: [(path: String, title: String, key: KeyEquivalent)] = []
        func walk(_ menu: NSMenu, _ menus: [String]) {
            for item in menu.items {
                if let submenu = item.submenu {
                    walk(submenu, menus + [submenu.title])
                } else if !item.keyEquivalent.isEmpty, !item.isHidden {
                    let key = KeyEquivalent(item.keyEquivalent, item.keyEquivalentModifierMask)
                    found.append((menus.joined(separator: " › "), item.title, key))
                }
            }
        }
        // MainMenu.build() hands its Window menu to the app; the app keeps the one in its menu bar.
        let windows = NSApp.windowsMenu
        walk(MainMenu.build(), [])
        NSApp.windowsMenu = windows
        return found
    }

    @Test func shortcutsAreUniqueAndClearOfMacOSAndVoiceOver() {
        let all = shortcuts()
        for (glyphs, items) in Dictionary(grouping: all, by: \.key.glyphs) {
            #expect(items.count == 1, "\(glyphs) is on \(items.map { "\($0.path) › \($0.title)" })")
        }
        for shortcut in all {
            let item = "\(shortcut.path) › \(shortcut.title)"
            #expect(!Self.reserved.contains(shortcut.key.glyphs), "\(item) takes \(shortcut.key.glyphs) from macOS")
            // VoiceOver's VO key is ⌃⌥, so every ⌃⌥ shortcut is a VoiceOver command. Revert Session's ⌃⌥⌘⌫ is the one
            // exception (decision 0013): VoiceOver has no VO-Command-Delete command, and VO-Tab passes it through.
            let voiceOver = shortcut.key.modifiers.isSuperset(of: [.control, .option]) && shortcut.key.glyphs != "⌃⌥⌘⌫"
            #expect(!voiceOver, "\(item) takes \(shortcut.key.glyphs) from VoiceOver")
        }
    }

    /// Decision 0013: the base key acts on one change, Shift on the note, Control on the session, and Revert carries Option.
    @Test func reviewKeysFollowTheLadder() {
        let keys = Dictionary(shortcuts().map { ($0.title, $0.key.glyphs) }) { first, _ in first }
        #expect(["Keep Change", "Keep All Changes", "Keep Session"].map { keys[$0] } == ["⌘↩", "⇧⌘↩", "⌃⌘↩"])
        #expect(["Revert Change", "Revert All Changes", "Revert Session"].map { keys[$0] } == ["⌥⌘⌫", "⌥⇧⌘⌫", "⌃⌥⌘⌫"])
        #expect(keys["Quick Open…"] == "⌘P")
        #expect(keys["Print…"] == "⌥⌘P")
    }

    /// The Edit and Find items a Mac text app has, on the text view's own selectors and their standard keys.
    @Test func editAndFindCarryTheStandardItems() {
        let all = shortcuts()
        func item(_ title: String) -> (path: String, title: String, key: KeyEquivalent)? {
            all.first { $0.title == title }
        }
        #expect(item("Paste and Match Style")?.key.glyphs == "⌥⇧⌘V")
        #expect(item("Find and Replace…")?.key.glyphs == "⌥⌘F")
        #expect(item("Use Selection for Find")?.key.glyphs == "⌘E")
        #expect(item("Jump to Selection")?.key.glyphs == "⌘J")
        #expect(item("Duplicate")?.key.glyphs == "⇧⌘S")
        let windows = NSApp.windowsMenu
        let edit = MainMenu.build().items.first { $0.submenu?.title == "Edit" }?.submenu
        NSApp.windowsMenu = windows
        func action(_ title: String, in menu: NSMenu? = edit) -> Selector? {
            guard let menu else { return nil }
            for item in menu.items {
                if item.title == title { return item.action }
                if let found = action(title, in: item.submenu) { return found }
            }
            return nil
        }
        let expected: [(String, Selector)] = [
            ("Paste and Match Style", #selector(NSTextView.pasteAsPlainText(_:))), ("Delete", #selector(NSText.delete(_:))),
            ("Use Selection for Find", #selector(NSTextView.performFindPanelAction(_:))),
            ("Jump to Selection", #selector(NSResponder.centerSelectionInVisibleArea(_:))),
            ("Show Spelling and Grammar", #selector(NSText.showGuessPanel(_:))), ("Check Document Now", #selector(NSText.checkSpelling(_:))),
            ("Show Substitutions", #selector(NSTextView.orderFrontSubstitutionsPanel(_:))),
            ("Smart Punctuation", #selector(EditorTextView.toggleSmartPunctuation(_:))),
            ("Make Upper Case", #selector(NSResponder.uppercaseWord(_:))), ("Make Lower Case", #selector(NSResponder.lowercaseWord(_:))),
            ("Capitalize", #selector(NSResponder.capitalizeWord(_:))),
        ]
        for (title, selector) in expected {
            #expect(action(title) == selector, "\(title)")
        }
    }

    /// ⌘= and ⌘+ zoom in, ⌘- zooms out and ⌘0 is Actual Size, which Body Text gave up; the size is the one setting.
    @Test func zoomKeysStepTheTextSizeAndActualSizeRestoresIt() throws {
        let windows = NSApp.windowsMenu
        let menu = MainMenu.build()
        NSApp.windowsMenu = windows
        #expect(shortcuts().first { $0.key.glyphs == "⌘0" }?.title == "Actual Size")
        #expect(shortcuts().first { $0.title == "Body Text" } == nil)
        let store = ThemeStore.shared
        let saved = store.bodySize
        defer { store.bodySize = saved }
        store.bodySize = ThemeStore.factory.bodySize
        func press(_ characters: String, _ keyCode: UInt16, _ modifiers: NSEvent.ModifierFlags = .command) throws -> Bool {
            let event = try #require(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0, context: nil,
                characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode
            ))
            return menu.performKeyEquivalent(with: event)
        }
        #expect(try press("=", 24))
        #expect(store.bodySize == ThemeStore.factory.bodySize + 1)
        #expect(try press("+", 24, [.command, .shift]))
        #expect(store.bodySize == ThemeStore.factory.bodySize + 2)
        #expect(try press("-", 27))
        #expect(store.bodySize == ThemeStore.factory.bodySize + 1)
        #expect(try press("0", 29))
        #expect(store.bodySize == ThemeStore.factory.bodySize)
        #expect(UserDefaults.standard.double(forKey: "DewlineBodySize") == ThemeStore.factory.bodySize)
        store.bodySize = ThemeStore.bodySizes.upperBound
        store.zoom(by: 1)
        #expect(store.bodySize == ThemeStore.bodySizes.upperBound)
    }

    /// DEWLINE_KEYBOARD_DOC (TEST_RUNNER_DEWLINE_KEYBOARD_DOC through xcodebuild) writes both files before comparing.
    @Test func keyboardDocListsTheMenuBar() throws {
        let all = shortcuts()
        // The Window menu's tab items come and go with the tabs.
        let rows = all.map { "| \($0.title) | \($0.path) | \($0.key.glyphs) |" } + ["| Tabs 1 to 9 | Window | ⌥⌘1 to ⌥⌘9 |"]
        let text = ([
            "# Keyboard shortcuts", "",
            "The shortcuts `app/Dewline/MainMenu.swift` puts in the menu bar, written here by `MainMenuTests`.", "",
            "| Command | Menu | Shortcut |", "| --- | --- | --- |",
        ] + rows).joined(separator: "\n") + "\n"
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let doc = root.appending(path: "docs/keyboard.md")
        let page = root.appending(path: "site/docs/keyboard/index.html")
        let html = try String(contentsOf: page, encoding: .utf8)
        let start = try #require(html.range(of: "<!-- menu-bar: written by MainMenuTests -->\n"))
        let end = try #require(html.range(of: "<!-- /menu-bar -->", range: start.upperBound..<html.endIndex))
        let written = html.replacingCharacters(in: start.upperBound..<end.lowerBound, with: Self.tables(all))
        if ProcessInfo.processInfo.environment["DEWLINE_KEYBOARD_DOC"] != nil {
            try text.write(to: doc, atomically: true, encoding: .utf8)
            try written.write(to: page, atomically: true, encoding: .utf8)
        }
        let rewrite = """
            Rewrite it with
            TEST_RUNNER_DEWLINE_KEYBOARD_DOC=1 xcodebuild test -project app/Dewline.xcodeproj -scheme Dewline \
            -destination 'platform=macOS' -only-testing:DewlineTests/MainMenuTests CODE_SIGNING_ALLOWED=NO
            """
        #expect((try? String(contentsOf: doc, encoding: .utf8)) == text, "docs/keyboard.md differs from the menu bar. \(rewrite)")
        #expect((try? String(contentsOf: page, encoding: .utf8)) == written, "The site's keyboard page differs from the menu bar. \(rewrite)")
    }

    /// The site's keyboard page between its markers: a heading and a table per menu, one keycap per key.
    private static func tables(_ all: [(path: String, title: String, key: KeyEquivalent)]) -> String {
        func escape(_ text: String) -> String {
            text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        }
        var menus: [(name: String, rows: [String])] = []
        for item in all {
            let menu = String(item.path.split(separator: " › ").first ?? "")
            let keys = item.key.caps.map { "<kbd>\(escape($0))</kbd>" }.joined()
            let row = "            <tr><td>\(escape(item.title))</td><td>\(keys)</td></tr>"
            if menus.last?.name == menu { menus[menus.count - 1].rows.append(row) } else { menus.append((menu, [row])) }
        }
        return menus.map { menu in
            ([
                "      <h2 id=\"\(menu.name.lowercased())\">\(escape(menu.name))</h2>",
                "      <div class=\"table\" tabindex=\"0\" role=\"region\" aria-label=\"\(escape(menu.name)) menu\">",
                "        <table>",
                "          <thead><tr><th scope=\"col\">Command</th><th scope=\"col\">Shortcut</th></tr></thead>",
                "          <tbody>",
            ] + menu.rows + ["          </tbody>", "        </table>", "      </div>", ""]).joined(separator: "\n")
        }.joined() + "      "
    }
}
