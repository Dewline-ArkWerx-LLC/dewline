import AppKit

/// Notes in iCloud Drive and File Provider folders: a coordinated write takes turns with the sync client, and a note
/// iCloud kept in two versions asks which one stays.
extension MarkdownDocument {
    /// Runs `write` as a coordinated replacement of the file at `url`, so a sync client finishes what it is doing to
    /// the file first and takes the result as one change. The document presents the file, so it hears nothing of it.
    nonisolated func coordinatedWrite<T>(at url: URL, _ write: (URL) throws -> T) throws -> T {
        var failure: NSError?
        var written: Result<T, any Error>?
        NSFileCoordinator(filePresenter: self).coordinate(writingItemAt: url, options: .forReplacing, error: &failure) { url in
            written = Result { try write(url) }
        }
        guard let written else { throw failure ?? CocoaError(.fileWriteUnknown) }
        return try written.get()
    }

    override nonisolated func presentedItemDidGain(_ version: NSFileVersion) {
        guard version.isConflict else { return }
        Task { @MainActor in askWhichVersion() }
    }

    /// Asks which version stays while iCloud holds another one from a second device, one version at a time. Using
    /// the other lands it as an outside change, marked, so Revert brings the text back; keeping this one puts the
    /// other in the note's snapshots first, or leaves it with iCloud when the note keeps none.
    func askWhichVersion() {
        guard let url = fileURL, (try? url.resourceValues(forKeys: [.isUbiquitousItemKey]))?.isUbiquitousItem == true,
            let window = windowControllers.first?.window, window.attachedSheet == nil,
            let other = NSFileVersion.unresolvedConflictVersionsOfItem(at: url)?.first
        else { return }
        let alert = NSAlert()
        alert.messageText = "iCloud has two versions of \u{201C}\(url.lastPathComponent)\u{201D}."
        let saved = other.modificationDate.map { ", \($0.formatted(date: .abbreviated, time: .shortened))" } ?? ""
        alert.informativeText = """
            The window shows one. The other was saved on \(other.localizedNameOfSavingComputer ?? "another device")\(saved). \
            If you use it, Dewline marks the switch as a change you can revert.
            """
        alert.addButton(withTitle: "Keep This Version")
        alert.addButton(withTitle: "Use the Other Version")
        Task {
            let useOther = await alert.beginSheetModal(for: window) == .alertSecondButtonReturn
            do {
                if useOther {
                    try coordinatedWrite(at: url) { url in _ = try other.replaceItem(at: url) }
                    live?.signal()
                } else {
                    guard let live else { return }
                    let (engine, doc, version) = (live.engine, live.doc, other.url)
                    let kept = try await Task.detached { try engine.snapshot(doc, bytes: Data(contentsOf: version)) }.value
                    guard kept else { return }
                    live.reloadSnapshots()
                }
                other.isResolved = true
                other.isDiscardable = true
            } catch {
                presentError(error)
                return
            }
            askWhichVersion()
        }
    }
}
