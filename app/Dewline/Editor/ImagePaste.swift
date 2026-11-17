import AppKit
import UniformTypeIdentifiers

extension EditorTextView {
    /// Saves pasted or dropped images beside the document, or in an "attachments" folder beside it when Settings >
    /// Files says so, and links them at the selection, as one edit. JPEG, GIF, WebP and PNG keep their bytes, and a
    /// file its extension; anything else, such as a screenshot's TIFF, is saved as PNG.
    /// Returns false for a pasteboard without images, or with text beside an image, which pastes as text.
    func insertImages(from pboard: NSPasteboard) -> Bool {
        let files = pboard.readObjects(forClasses: [NSURL.self], options: [
            .urlReadingFileURLsOnly: true, .urlReadingContentsConformToTypes: [UTType.image.identifier],
        ]) as? [URL] ?? []
        let types = pboard.types ?? []
        var images: [(data: Data, suffix: String)] = []
        if !files.isEmpty {
            images = files.compactMap { file in
                if let type = UTType(filenameExtension: file.pathExtension), Self.kept.contains(where: type.conforms(to:)),
                    let data = try? Data(contentsOf: file)
                {
                    return (data, file.pathExtension)
                }
                return NSImage(contentsOf: file).flatMap(Self.png).map { ($0, "png") }
            }
        } else if !types.contains(.fileURL), !types.contains(.string), !types.contains(.rtf) {
            let kept = Self.kept.lazy.compactMap { type in
                pboard.data(forType: NSPasteboard.PasteboardType(type.identifier)).map { ($0, type.preferredFilenameExtension!) }
            }.first
            images = (kept ?? NSImage(pasteboard: pboard).flatMap(Self.png).map { ($0, "png") }).map { [$0] } ?? []
        }
        guard !images.isEmpty else { return false }
        guard let folder = documentFolder else {
            askToSave()
            return true
        }
        let subfolder = Preferences.shared.attachments == .subfolder ? "attachments/" : ""
        let target = folder.appending(path: subfolder, directoryHint: .isDirectory)
        var links: [String] = []
        do {
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            for image in images { links.append("![](\(subfolder)\(try save(image.data, as: image.suffix, in: target)))") }
        } catch {
            window.map { presentError(error, modalFor: $0, delegate: nil, didPresent: nil, contextInfo: nil) }
            return true
        }
        replace(selectedRange(), with: links.joined(separator: "\n"))
        return true
    }

    /// Writes `data` to `image-<date>-<n>.<suffix>` in `folder`, at the first `n` no file has, and returns the name.
    private func save(_ data: Data, as suffix: String, in folder: URL) throws -> String {
        let date = Date().formatted(Date.ISO8601FormatStyle(timeZone: .current).year().month().day())
        var number = 1
        while true {
            let name = "image-\(date)-\(number).\(suffix)"
            do {
                try data.write(to: folder.appending(path: name), options: .withoutOverwriting)
                return name
            } catch CocoaError.fileWriteFileExists {
                number += 1
            }
        }
    }

    /// The image types saved as they come, in the order a pasteboard is read for them.
    static let kept: [UTType] = [.jpeg, .gif, .webP, .png]

    private static func png(_ image: NSImage) -> Data? {
        image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:))?.representation(using: .png, properties: [:])
    }

    /// An untitled document has no folder for its images.
    private func askToSave() {
        guard let window, let document = window.windowController?.document as? NSDocument else { return }
        let alert = NSAlert()
        alert.messageText = "Save this document to add images"
        alert.informativeText = "Dewline saves a pasted image beside the document, so the document needs a folder first."
        alert.addButton(withTitle: "Save…")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn { document.saveAs(nil) }
        }
    }
}
