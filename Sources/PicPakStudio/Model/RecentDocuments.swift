import AppKit
import Combine

/// Wraps the system recents list, so opened projects also show up under the app's
/// Dock menu and in Finder — not just in our own File menu.
@MainActor
final class RecentDocuments: ObservableObject {
    static let shared = RecentDocuments()

    @Published private(set) var urls: [URL] = []

    private init() { refresh() }

    func note(_ url: URL) {
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        refresh()
    }

    func clear() {
        NSDocumentController.shared.clearRecentDocuments(nil)
        refresh()
    }

    /// Entries whose file has since been moved or deleted are dropped from the menu
    /// rather than offered as a dead end.
    func refresh() {
        urls = NSDocumentController.shared.recentDocumentURLs
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Disambiguates same-named files by showing the parent folder.
    func label(for url: URL) -> String {
        let name = url.deletingPathExtension().lastPathComponent
        let clashes = urls.filter { $0.deletingPathExtension().lastPathComponent == name }
        guard clashes.count > 1 else { return name }
        return "\(name) — \(url.deletingLastPathComponent().lastPathComponent)"
    }
}
