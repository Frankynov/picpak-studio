import SwiftUI
import UniformTypeIdentifiers

struct LeftSidebar: View {
    @EnvironmentObject var store: Store
    var body: some View {
        VStack(spacing: 0) {
            ToolStrip()
            Divider()
            LayersPanel()
        }
        .frame(minWidth: 210, idealWidth: 230)
    }
}

// MARK: - Tools

struct ToolStrip: View {
    @EnvironmentObject var store: Store

    private let tools: [ElementType] = [.rect, .ellipse, .triangle, .star, .line, .text, .symbol, .barcode]
    private let columns = [GridItem(.adaptive(minimum: 42, maximum: 60), spacing: 6)]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("ADD")
                .font(.system(size: 10, weight: .semibold)).kerning(0.6)
                .foregroundStyle(.secondary)

            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(tools, id: \.self) { type in
                    Button { store.addNew(type) } label: {
                        VStack(spacing: 3) {
                            Image(systemName: type.symbol).font(.system(size: 15))
                            Text(shortLabel(type)).font(.system(size: 9))
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 40)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
                    }
                    .buttonStyle(.plain)
                    .help("Add \(type.label.lowercased())")
                }
                Button { FileActions.importArtwork(into: store) } label: {
                    VStack(spacing: 3) {
                        Image(systemName: "square.and.arrow.down").font(.system(size: 15))
                        Text("Import").font(.system(size: 9))
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 40)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
                }
                .buttonStyle(.plain)
                .help("Place an SVG or image")
            }
        }
        .padding(10)
    }

    private func shortLabel(_ type: ElementType) -> String {
        switch type {
        case .rect: "Rect"
        case .ellipse: "Circle"
        case .triangle: "Tri"
        case .star: "Star"
        case .line: "Line"
        case .text: "Text"
        case .symbol: "Symbol"
        case .barcode: "Code"
        default: type.label
        }
    }
}

// MARK: - Layers

struct LayersPanel: View {
    @EnvironmentObject var store: Store
    @State private var renaming: UUID?
    @State private var draggingIDs: Set<UUID> = []
    /// A drop can reach us as either a move or an insert depending on how SwiftUI
    /// routes it; whichever arrives first handles it and the other becomes a no-op.
    @State private var dropHandled = false

    /// The list reads top-down, so it shows the draw order reversed.
    private var ordered: [Element] { store.doc.elements.reversed() }

    var body: some View {
        Perf.tick("layers")
        return VStack(spacing: 0) {
            HStack {
                Text("LAYERS")
                    .font(.system(size: 10, weight: .semibold)).kerning(0.6)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(store.doc.elements.count)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 6)

            if store.doc.elements.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "square.stack.3d.up.slash")
                        .font(.title2).foregroundStyle(.tertiary)
                    Text("Nothing on the panel yet")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $store.selection) {
                    ForEach(ordered) { element in
                        LayerRow(element: element, renaming: $renaming)
                            .tag(element.id)
                            .onDrag {
                                dropHandled = false
                                draggingIDs = store.selection.contains(element.id)
                                    ? store.selection : [element.id]
                                return NSItemProvider(object: element.id.uuidString as NSString)
                            }
                    }
                    .onMove { offsets, destination in
                        guard !dropHandled else { return }
                        dropHandled = true
                        store.moveLayers(fromOffsets: offsets, toOffset: destination)
                    }
                    .onInsert(of: [.text]) { index, _ in
                        guard !dropHandled, !draggingIDs.isEmpty else { return }
                        dropHandled = true
                        store.moveLayers(ids: draggingIDs, toTopDownOffset: index)
                        draggingIDs = []
                    }
                }
                .listStyle(.inset)
                .environment(\.defaultMinListRowHeight, 30)
            }

            Divider()
            HStack(spacing: 4) {
                Button { store.duplicateSelected() } label: { Image(systemName: "plus.square.on.square") }
                    .help("Duplicate")
                Button { store.deleteSelected() } label: { Image(systemName: "trash") }
                    .help("Delete")
                Spacer()
                Button { store.bringForward() } label: { Image(systemName: "chevron.up") }
                    .help("Bring forward")
                Button { store.sendBackward() } label: { Image(systemName: "chevron.down") }
                    .help("Send backward")
            }
            .buttonStyle(.borderless)
            .disabled(store.selection.isEmpty)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
    }
}

private struct LayerRow: View {
    @EnvironmentObject var store: Store
    let element: Element
    @Binding var renaming: UUID?
    @FocusState private var nameFocused: Bool
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 8))
                .foregroundStyle(.tertiary)
                .opacity(hovering ? 1 : 0)
                .frame(width: 7)
            LayerThumbnail(element: element,
                           asset: PosterView.ref(for: element, in: store.doc),
                           background: store.doc.canvas.background)
                .equatable()

            if renaming == element.id {
                TextField("Name", text: Binding(
                    get: { store.doc[element.id]?.name ?? "" },
                    set: { newName in store.update(element.id) { $0.name = newName } }))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))
                    .focused($nameFocused)
                    .onSubmit { renaming = nil }
                    .onAppear { nameFocused = true; store.begin() }
            } else {
                Text(element.displayName)
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(element.hidden ? .secondary : .primary)
                    .onTapGesture(count: 2) { renaming = element.id }
            }

            Spacer(minLength: 2)

            if element.locked {
                Image(systemName: "lock.fill").font(.system(size: 9)).foregroundStyle(.secondary)
            }
            Button {
                store.begin()
                store.update(element.id) { $0.hidden.toggle() }
            } label: {
                Image(systemName: element.hidden ? "eye.slash" : "eye")
                    .font(.system(size: 10))
                    .foregroundStyle(element.hidden ? Color.secondary : Color.primary.opacity(0.6))
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 1)
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Rename") { renaming = element.id }
            Button(element.locked ? "Unlock" : "Lock") {
                store.begin()
                store.update(element.id) { $0.locked.toggle() }
            }
            Button(element.hidden ? "Show" : "Hide") {
                store.begin()
                store.update(element.id) { $0.hidden.toggle() }
            }
            Divider()
            Button("Duplicate") { store.select(element.id); store.duplicateSelected() }
            Button("Delete") { store.select(element.id); store.deleteSelected() }
        }
    }
}

/// A live miniature of the layer, so the list is scannable at a glance.
private struct LayerThumbnail: View, Equatable {
    let element: Element
    let asset: AssetRef?
    let background: PPColor
    private let box: Double = 22

    nonisolated static func == (lhs: LayerThumbnail, rhs: LayerThumbnail) -> Bool {
        lhs.element == rhs.element && lhs.asset == rhs.asset && lhs.background == rhs.background
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 3)
                .fill(background.color)
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.secondary.opacity(0.3), lineWidth: 0.5))
            if element.type == .text {
                Image(systemName: "textformat")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle((element.fill ?? .black).color)
            } else {
                let scale = min(box / max(element.w, 1), box / max(element.h, 1)) * 0.86
                ZStack(alignment: .topLeading) {
                    Color.clear
                    ElementView(element: centred(scale: scale), asset: asset, scale: scale)
                }
                .frame(width: box, height: box)
                .clipped()
            }
        }
        .frame(width: box, height: box)
        .opacity(element.hidden ? 0.35 : 1)
    }

    private func centred(scale: Double) -> Element {
        var copy = element
        copy.rotation = 0
        copy.x = (box / scale - copy.w) / 2
        copy.y = (box / scale - copy.h) / 2
        return copy
    }
}
