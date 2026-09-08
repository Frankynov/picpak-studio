import SwiftUI
import AppKit

@main
struct PicPakStudioApp: App {
    @StateObject private var store = Store.shared
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup("PicPak Studio") {
            ContentView()
                .environmentObject(store)
                .frame(minWidth: 1000, minHeight: 660)
        }
        .defaultSize(width: 1240, height: 800)
        .commands { AppCommands() }

        Settings {
            SettingsView()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// NSToolbar posts nothing when its display mode changes, so record it at the
    /// moments the setting could be about to be lost.
    @MainActor
    private func rememberToolbarMode() {
        guard let mode = NSApp.windows.compactMap({ $0.toolbar }).first?.displayMode else { return }
        UserDefaults.standard.set(mode.rawValue, forKey: WindowConfigurator.displayModeKey)
    }

    func applicationDidResignActive(_ notification: Notification) {
        MainActor.assumeIsolated { rememberToolbarMode() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { rememberToolbarMode() }
    }

    /// Don't let a quit throw away unsaved layers.
    @MainActor
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        FileActions.confirmDiscard(Store.shared) ? .terminateNow : .terminateCancel
    }

    @MainActor
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first, FileActions.confirmDiscard(Store.shared) else { return }
        FileActions.open(url: url, into: Store.shared)
        // SwiftUI opens a fresh WindowGroup window for a document handed to the app.
        // There is one shared document here, so that would be two windows showing the
        // same thing — keep the one the user already had, with its size and position.
        DispatchQueue.main.async { Self.closeDuplicateEditorWindows() }
    }

    @MainActor
    static func closeDuplicateEditorWindows() {
        let editors = NSApp.windows.filter {
            $0.identifier == WindowConfigurator.editorWindowID && $0.isVisible
        }
        guard editors.count > 1 else { return }
        let keep = editors.first { $0.isMainWindow } ?? editors[0]
        for window in editors where window !== keep { window.close() }
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct AppCommands: Commands {
    @ObservedObject private var recents = RecentDocuments.shared
    @FocusedValue(\.store) private var store: Store?
    @FocusedValue(\.showTemplates) private var showTemplates: Binding<Bool>?
    @FocusedValue(\.showPush) private var showPush: Binding<Bool>?

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") {
                Task { await UpdateChecker.shared.check(manual: true) }
            }
        }

        CommandGroup(replacing: .newItem) {
            Button("New from Template…") { showTemplates?.wrappedValue = true }
                .keyboardShortcut("n")
            Button("New Blank Panel") {
                guard let store, FileActions.confirmDiscard(store) else { return }
                RenderCache.shared.clear()
                store.newDocument(.blank)
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
            Divider()
            Button("Open…") { if let store { FileActions.open(into: store) } }
                .keyboardShortcut("o")
            Menu("Open Recent") {
                ForEach(recents.urls, id: \.self) { url in
                    Button(recents.label(for: url)) {
                        guard let store, FileActions.confirmDiscard(store) else { return }
                        FileActions.open(url: url, into: store)
                    }
                }
                if !recents.urls.isEmpty { Divider() }
                Button("Clear Menu") { recents.clear() }
                    .disabled(recents.urls.isEmpty)
            }
            .disabled(store == nil)
        }

        CommandGroup(replacing: .saveItem) {
            Button("Save") { if let store { FileActions.save(store) } }
                .keyboardShortcut("s")
                .disabled(store == nil)
            Button("Save As…") { if let store { FileActions.saveAs(store) } }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(store == nil)
            Divider()
            Button("Export PNG…") {
                if let store { FileActions.exportPNG(store, options: .init()) }
            }
            .keyboardShortcut("e")
            .disabled(store == nil)
            Button("Copy Panel Image") { if let store { FileActions.copyPNGToPasteboard(store) } }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(store == nil)
            Divider()
            Button("Place Artwork…") { if let store { FileActions.importArtwork(into: store) } }
                .keyboardShortcut("i")
                .disabled(store == nil)
            Divider()
            Button("Push to Panel…") { showPush?.wrappedValue = true }
                .keyboardShortcut("p")
        }

        CommandGroup(replacing: .undoRedo) {
            Button("Undo") { store?.undo() }
                .keyboardShortcut("z")
                .disabled(!(store?.canUndo ?? false))
            Button("Redo") { store?.redo() }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!(store?.canRedo ?? false))
        }

        CommandGroup(replacing: .pasteboard) {
            Button("Cut") { store?.cutSelected() }.keyboardShortcut("x")
            Button("Copy") { store?.copySelected() }.keyboardShortcut("c")
            Button("Paste") { store?.paste() }.keyboardShortcut("v")
            Button("Duplicate") { store?.duplicateSelected() }.keyboardShortcut("d")
            Button("Delete") { store?.deleteSelected() }
            Divider()
            Button("Select All") { store?.selectAll() }.keyboardShortcut("a")
            Button("Deselect") { store?.selection.removeAll() }
                .keyboardShortcut("a", modifiers: [.command, .shift])
        }

        CommandMenu("Arrange") {
            Button("Bring to Front") { store?.bringToFront() }
                .keyboardShortcut("]", modifiers: [.command, .shift])
            Button("Bring Forward") { store?.bringForward() }
                .keyboardShortcut("]")
            Button("Send Backward") { store?.sendBackward() }
                .keyboardShortcut("[")
            Button("Send to Back") { store?.sendToBack() }
                .keyboardShortcut("[", modifiers: [.command, .shift])
            Divider()
            Button("Align Left") { store?.align(.left) }
            Button("Align Centre") { store?.align(.hCenter) }
            Button("Align Right") { store?.align(.right) }
            Button("Align Top") { store?.align(.top) }
            Button("Align Middle") { store?.align(.vCenter) }
            Button("Align Bottom") { store?.align(.bottom) }
            Divider()
            Button("Fill Panel") { store?.fitSelectedToCanvas() }
        }

        CommandGroup(after: .toolbar) {
            Button("Zoom In") { if let store { store.zoom = min(CanvasZoom.range.upperBound, store.zoom + 0.5) } }
                .keyboardShortcut("+")
            Button("Zoom Out") { if let store { store.zoom = max(CanvasZoom.range.lowerBound, store.zoom - 0.5) } }
                .keyboardShortcut("-")
            Button("Actual Size") { store?.zoom = 1 }
                .keyboardShortcut("0")
            Divider()
            Toggle("Rulers", isOn: binding(\.showRulers))
                .keyboardShortcut("r", modifiers: [.command, .shift])
            Toggle("Grid", isOn: binding(\.showGrid))
                .keyboardShortcut("'")
            Toggle("Snap to Guides", isOn: binding(\.snapEnabled))
            Toggle("Bezel Margin", isOn: binding(\.showBleedGuides))
            Toggle("Panel Preview", isOn: binding(\.panelPreview))
                .keyboardShortcut("y")
        }
    }

    private func binding(_ keyPath: ReferenceWritableKeyPath<Store, Bool>) -> Binding<Bool> {
        Binding(
            get: { store?[keyPath: keyPath] ?? false },
            set: { store?[keyPath: keyPath] = $0 }
        )
    }
}
