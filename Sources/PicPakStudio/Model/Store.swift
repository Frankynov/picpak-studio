import SwiftUI
import Combine
import UniformTypeIdentifiers

@MainActor
final class Store: ObservableObject {

    /// The app is single-window, and the app delegate needs to reach the document
    /// to guard a quit and to handle files opened from the Finder.
    static let shared = Store()

    @Published var doc = PicPakDocument() { didSet { revision &+= 1 } }

    /// Bumped on every document mutation. Not published — a view that reads it is
    /// already re-rendering because `doc` changed; it exists so `.task(id:)` can
    /// debounce costly work off it.
    private(set) var revision = 0
    @Published var selection: Set<UUID> = []

    // View state (not part of the document)
    @Published var zoom: Double = 2.0
    @Published var showGrid = false
    @Published var gridSize: Double = 10
    @Published var snapEnabled = true
    @Published var panelPreview = false      // show the quantised bitmap the panel would get
    @Published var showBleedGuides = true
    @Published var showRulers = true

    @Published var fileURL: URL?
    @Published var isDirty = false
    @Published var statusMessage: String?

    private var undoStack: [(PicPakDocument, Set<UUID>)] = []
    private var redoStack: [(PicPakDocument, Set<UUID>)] = []
    private var clipboard: [Element] = []
    private var clipboardAssets: [String: Asset] = [:]
    private let undoLimit = 200

    // MARK: - Undo

    /// Snapshot before a mutation. Call once per user-visible change; for a drag,
    /// call at drag start only.
    func begin() {
        undoStack.append((doc, selection))
        if undoStack.count > undoLimit { undoStack.removeFirst() }
        redoStack.removeAll()
        isDirty = true
    }

    /// Force the next `beginCoalesced` to start a fresh undo step.
    func breakCoalescing() { coalesceToken = nil }

    private var coalesceToken: String?
    private var coalesceStamp = Date.distantPast

    /// Snapshot once for a run of continuous edits on the same control
    /// (a slider drag, repeated typing in one field) instead of once per change.
    func beginCoalesced(_ token: String) {
        if coalesceToken == token, Date().timeIntervalSince(coalesceStamp) < 1.5 {
            coalesceStamp = Date()
            isDirty = true
            return
        }
        coalesceToken = token
        coalesceStamp = Date()
        begin()
    }

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    func undo() {
        guard let s = undoStack.popLast() else { return }
        redoStack.append((doc, selection))
        doc = s.0; selection = s.1; isDirty = true
    }

    func redo() {
        guard let s = redoStack.popLast() else { return }
        undoStack.append((doc, selection))
        doc = s.0; selection = s.1; isDirty = true
    }

    func touch() { isDirty = true }

    // MARK: - Selection

    var selectedElements: [Element] { doc.elements.filter { selection.contains($0.id) } }

    /// Front-most selected element in document order. The inspector reads this through
    /// every one of its bindings, so it avoids building the full selection array.
    var primarySelection: Element? { doc.elements.first { selection.contains($0.id) } }
    var singleSelection: Element? {
        guard selection.count == 1, let id = selection.first else { return nil }
        return doc[id]
    }

    func select(_ id: UUID?, additive: Bool = false) {
        guard let id else { if !additive { selection.removeAll() }; return }
        if additive {
            if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
        } else {
            selection = [id]
        }
    }

    func selectAll() { selection = Set(doc.elements.filter { !$0.locked && !$0.hidden }.map(\.id)) }

    /// Mutate every selected element that isn't locked.
    func updateSelected(_ transform: (inout Element) -> Void) {
        for id in selection {
            guard let i = doc.index(of: id), !doc.elements[i].locked else { continue }
            transform(&doc.elements[i])
        }
        isDirty = true
    }

    func update(_ id: UUID, _ transform: (inout Element) -> Void) {
        guard let i = doc.index(of: id) else { return }
        transform(&doc.elements[i])
        isDirty = true
    }

    // MARK: - Element lifecycle

    @discardableResult
    func add(_ element: Element, select: Bool = true) -> UUID {
        begin()
        doc.elements.append(element)
        if select { selection = [element.id] }
        return element.id
    }

    /// Place a new element centred on the canvas, sized sensibly for it.
    /// `configure` lets a tool preset fields before the element lands, so e.g. the QR
    /// tool can be a real tool rather than a barcode you have to convert afterwards.
    @discardableResult
    func addNew(_ type: ElementType, size explicitSize: CGSize? = nil,
                configure: (inout Element) -> Void = { _ in }) -> UUID {
        let size = explicitSize ?? {
            switch type {
            case .text: CGSize(width: 200, height: 60)
            case .line: CGSize(width: 160, height: 0)
            case .symbol: CGSize(width: 64, height: 64)
            case .barcode: CGSize(width: 140, height: 50)
            case .arrow: CGSize(width: 140, height: 70)
            default: CGSize(width: 120, height: 90)
            }
        }()
        let rect = CGRect(x: (doc.canvas.w - size.width) / 2,
                          y: (doc.canvas.h - size.height) / 2,
                          width: size.width, height: size.height)
        var element = Element.make(type, at: rect.integral)
        configure(&element)
        return add(element)
    }

    func deleteSelected() {
        guard !selection.isEmpty else { return }
        begin()
        doc.elements.removeAll { selection.contains($0.id) && !$0.locked }
        selection.removeAll()
        doc.vacuum()
    }

    func duplicateSelected() {
        guard !selection.isEmpty else { return }
        begin()
        var newIDs: Set<UUID> = []
        for element in selectedElements {
            var copy = element
            copy.id = UUID()
            copy.x += 8; copy.y += 8
            copy.locked = false
            doc.elements.append(copy)
            newIDs.insert(copy.id)
        }
        selection = newIDs
    }

    func copySelected() {
        guard !selection.isEmpty else { return }
        clipboard = selectedElements
        clipboardAssets = [:]
        for e in clipboard {
            if let aid = e.assetID, let asset = doc.assets[aid] { clipboardAssets[aid] = asset }
        }
    }

    func cutSelected() { copySelected(); deleteSelected() }

    func paste() {
        guard !clipboard.isEmpty else { return }
        begin()
        var newIDs: Set<UUID> = []
        for (aid, asset) in clipboardAssets where doc.assets[aid] == nil {
            doc.assets[aid] = asset
        }
        for element in clipboard {
            var copy = element
            copy.id = UUID()
            copy.x += 12; copy.y += 12
            doc.elements.append(copy)
            newIDs.insert(copy.id)
        }
        selection = newIDs
    }

    // MARK: - Ordering (array order is draw order: last = front)

    func bringToFront() {
        begin()
        let moving = doc.elements.filter { selection.contains($0.id) }
        doc.elements.removeAll { selection.contains($0.id) }
        doc.elements.append(contentsOf: moving)
    }

    func sendToBack() {
        begin()
        let moving = doc.elements.filter { selection.contains($0.id) }
        doc.elements.removeAll { selection.contains($0.id) }
        doc.elements.insert(contentsOf: moving, at: 0)
    }

    func bringForward() {
        begin()
        for i in stride(from: doc.elements.count - 2, through: 0, by: -1)
        where selection.contains(doc.elements[i].id) && !selection.contains(doc.elements[i + 1].id) {
            doc.elements.swapAt(i, i + 1)
        }
    }

    func sendBackward() {
        begin()
        for i in 1..<max(doc.elements.count, 1)
        where selection.contains(doc.elements[i].id) && !selection.contains(doc.elements[i - 1].id) {
            doc.elements.swapAt(i, i - 1)
        }
    }

    /// Drop `ids` at an insertion point expressed in the layers panel's own top-down
    /// order (front-most first), which is the reverse of the document's draw order.
    func moveLayers(ids: Set<UUID>, toTopDownOffset offset: Int) {
        guard !ids.isEmpty else { return }
        var reversed = Array(doc.elements.reversed())
        let moving = reversed.filter { ids.contains($0.id) }
        guard !moving.isEmpty else { return }

        // Rows above the insertion point that are themselves moving shift it up.
        let liftedAbove = reversed.prefix(offset).count { ids.contains($0.id) }
        reversed.removeAll { ids.contains($0.id) }
        let target = min(max(offset - liftedAbove, 0), reversed.count)
        reversed.insert(contentsOf: moving, at: target)

        let reordered = Array(reversed.reversed())
        guard reordered.map(\.id) != doc.elements.map(\.id) else { return }
        begin()
        doc.elements = reordered
    }

    /// Layers panel shows front-to-back, so it moves in the reversed index space.
    func moveLayers(fromOffsets: IndexSet, toOffset: Int) {
        begin()
        var reversed = Array(doc.elements.reversed())
        reversed.move(fromOffsets: fromOffsets, toOffset: toOffset)
        doc.elements = reversed.reversed()
    }

    // MARK: - Alignment

    enum AlignEdge { case left, hCenter, right, top, vCenter, bottom }

    func align(_ edge: AlignEdge) {
        let items = selectedElements.filter { !$0.locked }
        guard !items.isEmpty else { return }
        begin()
        // One element aligns to the canvas; several align to each other's bounds.
        let bounds: CGRect = items.count == 1 ? doc.canvas.rect
            : items.dropFirst().reduce(items[0].frame) { $0.union($1.frame) }
        updateSelected { e in
            switch edge {
            case .left: e.x = bounds.minX
            case .hCenter: e.x = bounds.midX - e.w / 2
            case .right: e.x = bounds.maxX - e.w
            case .top: e.y = bounds.minY
            case .vCenter: e.y = bounds.midY - e.h / 2
            case .bottom: e.y = bounds.maxY - e.h
            }
        }
    }

    func distribute(horizontal: Bool) {
        var items = selectedElements.filter { !$0.locked }
        guard items.count > 2 else { return }
        begin()
        items.sort { horizontal ? $0.center.x < $1.center.x : $0.center.y < $1.center.y }
        let first = items.first!.center, last = items.last!.center
        let step = (horizontal ? last.x - first.x : last.y - first.y) / Double(items.count - 1)
        for (i, item) in items.enumerated() where i > 0 && i < items.count - 1 {
            update(item.id) { e in
                if horizontal { e.x = first.x + step * Double(i) - e.w / 2 }
                else { e.y = first.y + step * Double(i) - e.h / 2 }
            }
        }
    }

    func fitSelectedToCanvas() {
        guard !selection.isEmpty else { return }
        begin()
        updateSelected { e in
            e.x = 0; e.y = 0; e.w = doc.canvas.w; e.h = doc.canvas.h; e.rotation = 0
        }
    }

    // MARK: - Assets

    @discardableResult
    func registerAsset(kind: Asset.Kind, filename: String, data: Data) -> String {
        let id = UUID().uuidString
        doc.assets[id] = Asset(kind: kind, filename: filename, data: data)
        return id
    }

    // MARK: - Hit testing

    /// Front-most unlocked, visible element containing `point` (canvas coordinates).
    func hitTest(_ point: CGPoint, includeLocked: Bool = false) -> Element? {
        for element in doc.elements.reversed() {
            guard !element.hidden, includeLocked || !element.locked else { continue }
            if Geometry.contains(element: element, point: point) { return element }
        }
        return nil
    }

    func elements(intersecting rect: CGRect) -> [Element] {
        doc.elements.filter { !$0.hidden && !$0.locked && $0.frame.intersects(rect) }
    }

    var selectionBounds: CGRect? {
        let frames = selectedElements.map(\.frame)
        guard let first = frames.first else { return nil }
        return frames.dropFirst().reduce(first) { $0.union($1) }
    }

    // MARK: - Document lifecycle

    func newDocument(_ template: Template = .blank) {
        doc = template.build()
        selection = []
        undoStack.removeAll(); redoStack.removeAll()
        fileURL = nil
        isDirty = false
    }

    func load(_ document: PicPakDocument, url: URL?) {
        doc = document
        selection = []
        undoStack.removeAll(); redoStack.removeAll()
        fileURL = url
        isDirty = false
    }

    var windowTitle: String {
        let name = fileURL?.deletingPathExtension().lastPathComponent ?? doc.meta.title
        return name + (isDirty ? " — Edited" : "")
    }

    func flash(_ message: String) {
        statusMessage = message
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            if self?.statusMessage == message { self?.statusMessage = nil }
        }
    }
}
