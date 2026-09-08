import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject var store: Store
    @State private var showTemplates = false
    @State private var showPush = false
    @ObservedObject private var updates = UpdateChecker.shared

    var body: some View {
        NavigationSplitView {
            LeftSidebar()
        } detail: {
            VStack(spacing: 0) {
                CanvasEditor()
                Divider()
                StatusBar()
            }
            .inspector(isPresented: .constant(true)) {
                Inspector()
                    .inspectorColumnWidth(min: 250, ideal: 280, max: 340)
            }
        }
        .navigationTitle(store.windowTitle)
        .toolbar { toolbarContent }
        .sheet(isPresented: $showTemplates) {
            TemplateChooser { template in
                if FileActions.confirmDiscard(store) {
                    RenderCache.shared.clear()
                    store.newDocument(template)
                }
            }
        }
        .sheet(isPresented: $showPush) {
            PushSheet().environmentObject(store)
        }
        .sheet(item: Binding(
            get: { updates.available },
            set: { if $0 == nil { updates.dismiss() } })) { release in
            UpdateSheet(release: release)
        }
        .task { await updates.checkInBackground() }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            handleDrop(providers)
        }
        .background(WindowConfigurator())
        .focusedSceneValue(\.store, store)
        .focusedSceneValue(\.showTemplates, $showTemplates)
        .focusedSceneValue(\.showPush, $showPush)
    }

    // MARK: - Toolbar

    /// Every control is built from a `Label`, so the toolbar's "Icon and Text" and
    /// "Text Only" modes have something to show. Items are spread across the three
    /// placements rather than piled into one trailing group.
    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button { showTemplates = true } label: {
                Label("New", systemImage: "doc.badge.plus")
            }
            .help("New from template")

            Button { FileActions.open(into: store) } label: {
                Label("Open", systemImage: "folder")
            }
            .help("Open a project")

            Button { FileActions.save(store) } label: {
                Label("Save", systemImage: "square.and.arrow.down")
            }
            .help("Save project")
        }

        ToolbarItemGroup(placement: .principal) {
            Button { store.undo() } label: {
                Label("Undo", systemImage: "arrow.uturn.backward")
            }
            .disabled(!store.canUndo)

            Button { store.redo() } label: {
                Label("Redo", systemImage: "arrow.uturn.forward")
            }
            .disabled(!store.canRedo)

            Menu {
                Button("Zoom In") { store.zoom = min(CanvasZoom.range.upperBound, store.zoom + 0.5) }
                Button("Zoom Out") { store.zoom = max(CanvasZoom.range.lowerBound, store.zoom - 0.5) }
                Divider()
                ForEach([1.0, 1.5, 2.0, 3.0, 4.0], id: \.self) { level in
                    Button("\(Int(level * 100))%") { store.zoom = level }
                }
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "plus.magnifyingglass")
                    Text("\(Int(store.zoom * 100))%")
                        .font(.system(size: 11, design: .monospaced))
                }
            }
            .help("Zoom")
        }

        ToolbarItemGroup(placement: .primaryAction) {
            Menu {
                Toggle("Rulers", isOn: $store.showRulers)
                Toggle("Grid", isOn: $store.showGrid)
                Toggle("Snap to Guides", isOn: $store.snapEnabled)
                Toggle("Bezel Margin", isOn: $store.showBleedGuides)
            } label: {
                Label("Guides", systemImage: "ruler")
            }
            .help("Grid, snapping and bezel margin")

            Toggle(isOn: $store.panelPreview) {
                Label("Panel Preview", systemImage: "eye.square")
            }
            .help("Show the exact bitmap the panel will paint. Edges harden, "
                  + "because e-paper has no in-between shades to soften them with.")

            Menu {
                Button("Export PNG (400 × 300)") {
                    FileActions.exportPNG(store, options: .init(scale: 1, quantize: true,
                                                                dither: .none, embedProject: true))
                }
                Button("Export PNG @2x") {
                    FileActions.exportPNG(store, options: .init(scale: 2, quantize: true,
                                                                dither: .none, embedProject: true))
                }
                Button("Export PNG @4x") {
                    FileActions.exportPNG(store, options: .init(scale: 4, quantize: true,
                                                                dither: .none, embedProject: true))
                }
                Divider()
                Button("Export Flat PNG (no project inside)") {
                    FileActions.exportPNG(store, options: .init(scale: 1, quantize: true,
                                                                dither: .none, embedProject: false))
                }
                Button("Copy Panel Image") { FileActions.copyPNGToPasteboard(store) }
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .help("Export a PNG")

            Button { showPush = true } label: {
                Label("Push", systemImage: "dot.radiowaves.up.forward")
            }
            .help("Send to a PicPak panel via Tesserae")
        }
    }

    // MARK: - Drag and drop

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url else { return }
            Task { @MainActor in
                let ext = url.pathExtension.lowercased()
                if ext == "picpak" || ext == "png", ext == "picpak" || PNGChunks.extractProject(from: (try? Data(contentsOf: url)) ?? Data()) != nil {
                    FileActions.open(url: url, into: store)
                } else if let asset = AssetImporter.asset(from: url) {
                    FileActions.place(asset, into: store)
                }
            }
        }
        return true
    }
}

/// SwiftUI builds the window's `NSToolbar` but leaves autosaving off, so a switch to
/// "Icon and Text" was forgotten at quit. This turns autosaving on and restores the
/// mode we recorded ourselves, which survives even when the toolbar's generated
/// identifier changes between builds.
struct WindowConfigurator: NSViewRepresentable {
    static let displayModeKey = "toolbar.displayMode"
    /// Stamped so the delegate can tell editor windows apart from the Settings window.
    static let editorWindowID = NSUserInterfaceItemIdentifier("picpak.editor")

    func makeNSView(context: Context) -> NSView {
        let probe = NSView(frame: .zero)
        DispatchQueue.main.async {
            probe.window?.identifier = Self.editorWindowID
            guard let toolbar = probe.window?.toolbar else { return }
            toolbar.autosavesConfiguration = true
            if let stored = UserDefaults.standard.object(forKey: Self.displayModeKey) as? UInt,
               let mode = NSToolbar.DisplayMode(rawValue: stored) {
                toolbar.displayMode = mode
            }
        }
        return probe
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

// MARK: - Status bar

private struct StatusBar: View {
    @EnvironmentObject var store: Store

    var body: some View {
        HStack(spacing: 12) {
            Label("\(Int(store.doc.canvas.w)) × \(Int(store.doc.canvas.h))", systemImage: "rectangle.dashed")
            if let element = store.singleSelection {
                Text("\(element.type.label)  ·  \(Int(element.x)), \(Int(element.y))  ·  \(Int(element.w)) × \(Int(element.h))")
            } else if store.selection.count > 1 {
                Text("\(store.selection.count) selected")
            }
            Spacer()
            if let message = store.statusMessage {
                Text(message).foregroundStyle(Color.accentColor)
            }
            if store.panelPreview {
                Label("Panel preview", systemImage: "eye.square").foregroundStyle(PPColor.red.color)
            }
        }
        .font(.system(size: 10, design: .monospaced))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .frame(height: 24)
    }
}

// MARK: - Templates

struct TemplateChooser: View {
    @Environment(\.dismiss) private var dismiss
    let onPick: (Template) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Start from")
                .font(.title3.weight(.semibold))
                .padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 10)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 168), spacing: 12)], spacing: 12) {
                ForEach(Template.allCases) { template in
                    Button {
                        onPick(template)
                        dismiss()
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            TemplatePreview(template: template)
                            Text(template.title).font(.system(size: 12, weight: .semibold))
                            Text(template.subtitle)
                                .font(.caption2).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(height: 26, alignment: .top)
                        }
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(16)

            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(12)
        }
        .frame(width: 600)
    }
}

private struct TemplatePreview: View {
    let template: Template
    var body: some View {
        let doc = template.build()
        let scale = 152.0 / doc.canvas.w
        PosterView(doc: doc, scale: scale)
            .frame(width: doc.canvas.w * scale, height: doc.canvas.h * scale)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
    }
}

// MARK: - Focused values so menu commands reach the scene

struct StoreFocusKey: FocusedValueKey { typealias Value = Store }
struct TemplatesFocusKey: FocusedValueKey { typealias Value = Binding<Bool> }
struct PushFocusKey: FocusedValueKey { typealias Value = Binding<Bool> }

extension FocusedValues {
    var store: Store? {
        get { self[StoreFocusKey.self] }
        set { self[StoreFocusKey.self] = newValue }
    }
    var showTemplates: Binding<Bool>? {
        get { self[TemplatesFocusKey.self] }
        set { self[TemplatesFocusKey.self] = newValue }
    }
    var showPush: Binding<Bool>? {
        get { self[PushFocusKey.self] }
        set { self[PushFocusKey.self] = newValue }
    }
}
