import AppKit
import MdCore

/// Making, naming, moving and trashing notes and folders on disk, each one undoable. An open note follows its file.
@MainActor
enum FileActions {
    /// Where a new note goes when no window shows a folder: the folder picked for that, while it is there.
    static var notesFolder: URL? {
        Preferences.shared.notesFolder.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
    }

    /// An empty "Untitled.md" in `folder` (or "Untitled 2.md"), created at once so it autosaves like any note.
    @discardableResult
    static func newNote(in folder: URL, undo: UndoManager? = nil) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = free("Untitled", extension: "md", in: folder)
        try Data().write(to: url, options: .withoutOverwriting)
        undo?.registerUndo(withTarget: Undo.shared) { _ in _ = try? trash(url) }
        undo?.setActionName("New Note")
        return url
    }

    /// "New Folder" in `folder` (or "New Folder 2").
    @discardableResult
    static func newFolder(in folder: URL, undo: UndoManager? = nil) throws -> URL {
        let url = free("New Folder", extension: nil, in: folder)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        undo?.registerUndo(withTarget: Undo.shared) { _ in _ = try? trash(url) }
        undo?.setActionName("New Folder")
        return url
    }

    /// Renames `url` to `name`, keeping a note's extension when `name` has none. An open note follows, and the links to
    /// it, or to what a renamed folder holds, from the notes in `folder` follow too.
    @discardableResult
    static func rename(_ url: URL, to name: String, relinkingIn folder: URL? = nil, undo: UndoManager? = nil) throws -> URL {
        let clean = cleaned(name)
        guard !clean.isEmpty else { throw CocoaError(.fileWriteInvalidFileName, userInfo: [NSURLErrorKey: url]) }
        let isFolder = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        let keepsExtension = !isFolder && (clean as NSString).pathExtension.isEmpty && !url.pathExtension.isEmpty
        let target = url.deletingLastPathComponent().appending(path: keepsExtension ? clean + "." + url.pathExtension : clean)
        guard target.lastPathComponent != url.lastPathComponent else { return url }
        let renamed = try relocate(url, to: target, named: "Rename", undo: undo)
        if let folder { relink(from: url, to: renamed, in: folder, undo: undo) }
        return renamed
    }

    /// The last relink, which the next one waits for.
    private static var relinking: Task<Void, Never>?

    /// Points the links in `folder`'s notes to the file or folder moved from `old` at `new`: open notes through their
    /// editors, as a landing that undo steps over, closed notes on disk as your change. Undo points them back. The
    /// folder is walked off the main thread, one relink after another; an open note typed into meanwhile is read again.
    static func relink(from old: URL, to new: URL, in folder: URL, undo: UndoManager?) {
        let (old, new, folder) = (old.standardizedFileURL, new.standardizedFileURL, folder.standardizedFileURL)
        let previous = relinking
        relinking = Task {
            await previous?.value
            var stale = true
            while stale {
                let open = NSDocumentController.shared.documents.compactMap { document -> (url: URL, textView: EditorTextView)? in
                    guard let document = document as? MarkdownDocument, let url = document.fileURL, let textView = document.textView else { return nil }
                    return (url.standardizedFileURL, textView)
                }
                let texts = open.map { (url: $0.url, text: $0.textView.string) }
                let engine = MarkdownDocument.sharedEngine
                let edits = await Task.detached { NoteLinks.relink(from: old, to: new, in: folder, open: texts, engine: engine) }.value
                stale = false
                for ((note, text), edits) in zip(zip(open, texts), edits) where !edits.isEmpty {
                    guard note.textView.string == text.text else {
                        stale = true
                        continue
                    }
                    let storage = note.textView.textStorage!
                    note.textView.history.land(edits) {
                        storage.beginEditing()
                        for edit in edits.reversed() {
                            storage.replaceCharacters(in: edit.range, with: edit.text)
                        }
                        storage.endEditing()
                    }
                }
            }
        }
        undo?.registerUndo(withTarget: Undo.shared) { _ in
            MainActor.assumeIsolated { relink(from: new, to: old, in: folder, undo: undo) }
        }
    }

    /// "Name copy.md" beside `url` (or "Name copy 2.md").
    @discardableResult
    static func duplicate(_ url: URL, undo: UndoManager? = nil) throws -> URL {
        let stem = url.deletingPathExtension().lastPathComponent + " copy"
        let copy = free(stem, extension: url.pathExtension.isEmpty ? nil : url.pathExtension, in: url.deletingLastPathComponent())
        try FileManager.default.copyItem(at: url, to: copy)
        undo?.registerUndo(withTarget: Undo.shared) { _ in _ = try? trash(copy) }
        undo?.setActionName("Duplicate")
        return copy
    }

    /// Moves `url` to the Trash, closing its note first, and returns where it went. Undo puts it back.
    @discardableResult
    static func trash(_ url: URL, undo: UndoManager? = nil) throws -> URL? {
        for document in documents(at: url) { document.close() }
        var trashed: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &trashed)
        guard let undo, let trashed = trashed as URL? else { return trashed as URL? }
        undo.registerUndo(withTarget: Undo.shared) { _ in
            MainActor.assumeIsolated { _ = try? relocate(trashed, to: url, named: "Move to Trash", undo: undo) }
        }
        undo.setActionName("Move to Trash")
        return trashed
    }

    /// Moves `url` into `folder`, keeping its name, or numbering it when the name is taken there. The links to it from
    /// the notes in `notes` follow.
    @discardableResult
    static func move(_ url: URL, to folder: URL, relinkingIn notes: URL? = nil, undo: UndoManager? = nil) throws -> URL {
        let name = url.lastPathComponent
        var target = folder.appending(path: name)
        if FileManager.default.fileExists(atPath: target.path) {
            let stem = (name as NSString).deletingPathExtension
            let ext = (name as NSString).pathExtension
            target = free(stem, extension: ext.isEmpty ? nil : ext, in: folder)
        }
        let moved = try relocate(url, to: target, named: "Move", undo: undo)
        if let notes { relink(from: url, to: moved, in: notes, undo: undo) }
        return moved
    }

    // MARK: Naming a new note

    /// New notes Dewline made: what watches each one, and the name it gave the note's file last.
    private static var naming: [ObjectIdentifier: (observers: [NSObjectProtocol], named: URL?)] = [:]

    /// Names `document`, a note Dewline just made, from its first line each time the note loses focus and as it
    /// closes, while its file has the name Dewline gave it: 60 characters at most, without `/` or `:`, numbered when
    /// the name is taken. Renaming it by hand ends that. Closing it empty removes the file Dewline made.
    static func nameFromFirstLine(_ document: MarkdownDocument) {
        let key = ObjectIdentifier(document)
        guard naming[key] == nil, let textView = document.textView else { return }
        let center = NotificationCenter.default
        let blur: @Sendable (Notification) -> Void = { [weak document] note in
            let window = (note.object as? NSWindow).map(ObjectIdentifier.init)
            MainActor.assumeIsolated {
                guard let document, window == nil || window == document.textView?.window.map(ObjectIdentifier.init) else { return }
                Task {
                    guard await document.flush(), !document.isDocumentEdited else { return }
                    nameIfUntitled(document)
                }
            }
        }
        naming[key] = (
            [
                center.addObserver(forName: NSText.didEndEditingNotification, object: textView, queue: .main, using: blur),
                center.addObserver(forName: NSWindow.didResignKeyNotification, object: nil, queue: .main, using: blur),
                center.addObserver(forName: MarkdownDocument.didCloseNotification, object: document, queue: .main) { [weak document] _ in
                    MainActor.assumeIsolated { if let document { stopNaming(document) } }
                },
            ], nil
        )
    }

    /// Renames `document` from its first line while its file has the name Dewline gave it: "Untitled" until the
    /// first naming, the name it took after.
    static func nameIfUntitled(_ document: MarkdownDocument) {
        let key = ObjectIdentifier(document)
        guard let state = naming[key], let url = document.fileURL,
            state.named.map({ $0.standardizedFileURL == url.standardizedFileURL }) ?? url.lastPathComponent.hasPrefix("Untitled"),
            let text = document.textView?.string ?? (try? String(contentsOf: url, encoding: .utf8)), let name = title(of: text)
        else { return }
        let target = free(name, extension: url.pathExtension.isEmpty ? "md" : url.pathExtension, in: url.deletingLastPathComponent(), except: url)
        guard target.lastPathComponent != url.lastPathComponent, (try? relocate(url, to: target, named: "Rename", undo: nil)) != nil else { return }
        naming[key]?.named = target
    }

    /// Names `document` once more as it closes and stops watching it. A file Dewline made that is still Untitled and
    /// holds only blanks goes instead: never one the user or another app wrote in.
    static func stopNaming(_ document: MarkdownDocument) {
        guard let state = naming[ObjectIdentifier(document)] else { return }
        if !document.isDocumentEdited, let url = document.fileURL {
            if state.named == nil, url.lastPathComponent.hasPrefix("Untitled"),
                let data = FileManager.default.contents(atPath: url.path), String(decoding: data, as: UTF8.self).allSatisfy(\.isWhitespace)
            {
                try? FileManager.default.removeItem(at: url)
            } else {
                nameIfUntitled(document)
            }
        }
        state.observers.forEach(NotificationCenter.default.removeObserver)
        naming[ObjectIdentifier(document)] = nil
    }

    /// A note's first line as a file name: Markdown's heading, list and quote marks dropped, then `cleaned`.
    static func title(of text: String) -> String? {
        guard let line = text.split(whereSeparator: \.isNewline).first(where: { $0.contains { !$0.isWhitespace } }) else { return nil }
        let words = line.drop { "#>-*+ \t".contains($0) }
        let name = cleaned(String(words))
        return name.isEmpty ? nil : name
    }

    // MARK: Helpers

    /// The undo target for file actions, which have no object of their own.
    @MainActor final class Undo: NSObject {
        static let shared = Undo()
    }

    /// Moves `url` to `target`, which must be free; an open note there, or inside a moved folder, follows.
    private static func relocate(_ url: URL, to target: URL, named action: String, undo: UndoManager?) throws -> URL {
        guard !FileManager.default.fileExists(atPath: target.path) || sameFile(url, target) else {
            throw CocoaError(.fileWriteFileExists, userInfo: [NSURLErrorKey: target])
        }
        let open = documents(at: url)
        try FileManager.default.moveItem(at: url, to: target)
        let from = url.standardizedFileURL.path
        for document in open {
            guard let old = document.fileURL?.standardizedFileURL.path else { continue }
            let moved = URL(filePath: target.path + old.dropFirst(from.count))
            document.fileURL = moved
            document.live?.moved(to: moved)
        }
        undo?.registerUndo(withTarget: Undo.shared) { _ in
            MainActor.assumeIsolated { _ = try? relocate(target, to: url, named: action, undo: undo) }
        }
        undo?.setActionName(action)
        return target
    }

    /// Open notes at `url`, or under it for a folder.
    private static func documents(at url: URL) -> [MarkdownDocument] {
        let path = url.standardizedFileURL.path
        return NSDocumentController.shared.documents.compactMap { $0 as? MarkdownDocument }.filter { document in
            guard let open = document.fileURL?.standardizedFileURL.path else { return false }
            return open == path || open.hasPrefix(path + "/")
        }
    }

    /// A case-only rename on a case-insensitive volume finds the same file at the target.
    private static func sameFile(_ a: URL, _ b: URL) -> Bool {
        let keys: Set<URLResourceKey> = [.fileResourceIdentifierKey]
        guard let one = try? a.resourceValues(forKeys: keys).fileResourceIdentifier,
            let two = try? b.resourceValues(forKeys: keys).fileResourceIdentifier
        else { return false }
        return one.isEqual(two)
    }

    /// `stem.ext` in `folder`, or `stem 2.ext`, `stem 3.ext` and on, whichever is free first or is `current`.
    static func free(_ stem: String, extension ext: String?, in folder: URL, except current: URL? = nil) -> URL {
        func named(_ name: String) -> URL {
            folder.appending(path: ext.map { name + "." + $0 } ?? name)
        }
        var url = named(stem)
        var number = 2
        while FileManager.default.fileExists(atPath: url.path), url.lastPathComponent.caseInsensitiveCompare(current?.lastPathComponent ?? "") != .orderedSame {
            url = named("\(stem) \(number)")
            number += 1
        }
        return url
    }

    /// A name with `/` and `:` dropped, blanks trimmed, no leading dot, at most 60 characters.
    static func cleaned(_ name: String) -> String {
        var clean = String(name.filter { $0 != "/" && $0 != ":" && !$0.isNewline }).trimmingCharacters(in: .whitespaces)
        while clean.hasPrefix(".") { clean.removeFirst() }
        return String(clean.prefix(60)).trimmingCharacters(in: .whitespaces)
    }
}

/// The sidebar's file commands (`FileCommand`), answered by the window that shows the sidebar. Each menu item's
/// represented object is the folder or file, or a request.
extension MainWindowController {
    @objc func newNoteInFolder(_ sender: Any?) {
        guard let folder = (sender as? NSMenuItem)?.representedObject as? URL else { return }
        perform { try self.openNew(FileActions.newNote(in: folder, undo: self.window?.undoManager)) }
    }

    @objc func newNoteNamed(_ sender: Any?) {
        guard let request = (sender as? NSMenuItem)?.representedObject as? NewNoteRequest else { return }
        perform {
            let url = FileActions.free((request.name as NSString).deletingPathExtension, extension: "md", in: request.folder)
            try Data().write(to: url, options: .withoutOverwriting)
            self.open(url, newTab: false)
        }
    }

    @objc func newFolderInFolder(_ sender: Any?) {
        guard let folder = (sender as? NSMenuItem)?.representedObject as? URL else { return }
        perform { try self.sidebar.renameNew(FileActions.newFolder(in: folder, undo: self.window?.undoManager)) }
    }

    @objc func renameItem(_ sender: Any?) {
        guard let request = (sender as? NSMenuItem)?.representedObject as? RenameRequest else { return }
        perform { try FileActions.rename(request.url, to: request.name, relinkingIn: self.folder?.url, undo: self.window?.undoManager) }
    }

    @objc func duplicateItem(_ sender: Any?) {
        guard let url = (sender as? NSMenuItem)?.representedObject as? URL else { return }
        perform { _ = try FileActions.duplicate(url, undo: self.window?.undoManager) }
    }

    @objc func trashItem(_ sender: Any?) {
        guard let url = (sender as? NSMenuItem)?.representedObject as? URL else { return }
        perform { _ = try FileActions.trash(url, undo: self.window?.undoManager) }
    }

    @objc func moveItems(_ sender: Any?) {
        guard let request = (sender as? NSMenuItem)?.representedObject as? MoveRequest else { return }
        perform {
            for url in request.urls {
                _ = try FileActions.move(url, to: request.folder, relinkingIn: self.folder?.url, undo: self.window?.undoManager)
            }
        }
    }

    private func openNew(_ url: URL) {
        open(url, newTab: true)
        if let document = NSDocumentController.shared.document(for: url) as? MarkdownDocument {
            FileActions.nameFromFirstLine(document)
        }
    }

    private func perform(_ action: () throws -> Void) {
        do {
            try action()
        } catch {
            if let window { presentError(error, modalFor: window, delegate: nil, didPresent: nil, contextInfo: nil) }
        }
    }
}

extension MarkdownDocument {
    /// File > Rename moves the note through here; the links to it from the notes in its window's folder follow. Undo
    /// moves it back, and the links with it.
    override func move(to url: URL, completionHandler: (((any Error)?) -> Void)? = nil) {
        let old = fileURL
        let folder = (windowControllers.first as? MainWindowController)?.folder?.url
        super.move(to: url) { error in
            if error == nil, let old {
                MainActor.assumeIsolated {
                    if let folder { FileActions.relink(from: old, to: url, in: folder, undo: nil) }
                    self.undoManager?.registerUndo(withTarget: self) { document in
                        MainActor.assumeIsolated { document.move(to: old) }
                    }
                    self.undoManager?.setActionName("Rename")
                }
            }
            completionHandler?(error)
        }
    }
}
