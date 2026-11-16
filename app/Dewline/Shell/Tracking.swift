import AppKit
import os

/// Failures that switch change tracking off, said once in the status bar ("Change tracking is off · Details") instead
/// of only in the log.
@MainActor
enum Tracking {
    enum Problem: Equatable {
        /// The engine didn't start, so notes save without snapshots or marks.
        case noEngine(String)
        /// The control socket didn't start, so the dewline command and agent hooks can't reach the app.
        case noSocket(String)

        var details: String {
            switch self {
            case .noEngine(let error):
                "Notes still save, but Dewline can\u{2019}t mark outside changes or keep earlier versions. The engine reported: \(error)"
            case .noSocket(let error):
                "The dewline command and agent hooks can\u{2019}t reach the app, so agent edits aren\u{2019}t named. The system reported: \(error)"
            }
        }
    }

    static let didChange = Notification.Name("DewlineTrackingDidChange")
    private(set) static var problems: [Problem] = []

    static func report(_ problem: Problem) {
        Logger(subsystem: "dev.arkwerx.dewline", category: "tracking").error("\(problem.details, privacy: .public)")
        guard !problems.contains(problem) else { return }
        problems.append(problem)
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    /// The status bar's Details: what stopped and what still works.
    static func showDetails(in window: NSWindow?) {
        let alert = NSAlert()
        alert.messageText = "Change tracking is off"
        alert.informativeText = problems.map(\.details).joined(separator: "\n\n") + "\n\nQuit and reopen Dewline to try again."
        if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }
}

/// What the app says on its own: an export's result in a notice that goes after 4 s, and "Change tracking is off" in
/// every main window's status bar while a tracking problem stands.
@MainActor
enum FlowStatus {
    static func start() {
        let center = NotificationCenter.default
        center.addObserver(forName: Export.didExport, object: nil, queue: .main) { note in
            guard let url = note.object as? URL else { return }
            MainActor.assumeIsolated { exported(url) }
        }
        center.addObserver(forName: Tracking.didChange, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { NSApp.windows.forEach(postTracking) }
        }
        center.addObserver(forName: NSWindow.didBecomeMainNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { NSApp.mainWindow.map(postTracking) }
        }
    }

    /// "Exported “spec.pdf”  Show in Finder" in a popover under the title row's trailing end, gone after 4 s or at a
    /// click elsewhere.
    private static func exported(_ url: URL) {
        guard let content = NSApp.mainWindow?.contentView else { return }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = ExportNotice(url, closing: popover)
        let corner = NSRect(x: content.bounds.maxX - 60, y: content.bounds.maxY - content.safeAreaInsets.top - 1, width: 1, height: 1)
        popover.show(relativeTo: corner, of: content, preferredEdge: .minY)
        Task {
            try? await Task.sleep(for: .seconds(4))
            popover.performClose(nil)
        }
    }

    private static func postTracking(in window: NSWindow) {
        guard !Tracking.problems.isEmpty, window.windowController is MainWindowController else { return }
        StatusBar.post(.init(id: "tracking", kind: .problem, text: "Change tracking is off", actions: [
            .init(title: "Details") { view in Tracking.showDetails(in: view.window) }
        ]), in: window)
    }
}

/// An export's notice: the file's name and Show in Finder.
private final class ExportNotice: NSViewController {
    private let url: URL
    private weak var popover: NSPopover?

    init(_ url: URL, closing popover: NSPopover) {
        self.url = url
        self.popover = popover
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("ExportNotice is built in code")
    }

    override func loadView() {
        let label = NSTextField(labelWithString: "Exported \u{201C}\(url.lastPathComponent)\u{201D}")
        label.font = Chrome.label
        label.textColor = Chrome.color(.ink)
        let show = NSButton(title: "Show in Finder", target: self, action: #selector(reveal))
        show.bezelStyle = .push
        show.controlSize = .small
        let stack = NSStackView(views: [label, show])
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 10)
        view = stack
    }

    @objc private func reveal() {
        NSWorkspace.shared.activateFileViewerSelecting([url])
        popover?.performClose(nil)
    }
}
