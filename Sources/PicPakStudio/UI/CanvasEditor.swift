import SwiftUI
import AppKit

/// The canvas area: AppKit's magnifying scroll view hosting the SwiftUI board, with
/// pixel rulers pinned along its top and left edges.
///
/// Takes the store directly rather than observing it, so a drag or an edit never
/// re-renders this wrapper. It listens for exactly one setting — whether rulers show.
/// The viewport is held in view state, which keeps one instance without observing it:
/// only the rulers observe it, so a pan redraws two strips, not the board.
struct CanvasEditor: View {
    let store: Store
    @ViewState private var viewport = CanvasViewport()
    @ViewState private var showRulers: Bool

    init(store: Store) {
        self.store = store
        _showRulers = ViewState(initialValue: store.showRulers)
    }

    var body: some View {
        VStack(spacing: 0) {
            if showRulers {
                HStack(spacing: 0) {
                    RulerCorner()
                    ViewportRuler(viewport: viewport, horizontal: true)
                }
            }
            HStack(spacing: 0) {
                if showRulers {
                    ViewportRuler(viewport: viewport, horizontal: false)
                }
                CanvasScrollView(store: store, viewport: viewport,
                                 content: CanvasBoard(viewport: viewport).environmentObject(store))
            }
        }
        // Stop the artboard drawing up underneath the toolbar while it scrolls.
        .clipped()
        .onReceive(store.$showRulers) { showRulers = $0 }
    }
}

/// Everything inside the scroll view: artboard, selection, handles, gestures.
struct CanvasBoard: View {
    @EnvironmentObject var store: Store
    /// Written to, never observed: the board tells the rulers what is selected.
    let viewport: CanvasViewport
    @ViewState private var session: DragSession?
    /// Live values for whatever is being dragged. The store is only written once,
    /// on mouse-up, so a drag never re-renders the layers panel or the inspector.
    @ViewState private var draft: [UUID: Element] = [:]
    @ViewState private var guides: [SnapGuide] = []
    @ViewState private var marquee: CGRect?
    @ViewState private var hoverID: UUID?
    @ViewState private var editingText: UUID?
    @FocusState private var canvasFocused: Bool
    @FocusState private var textFieldFocused: Bool

    private var zoom: Double { store.zoom }
    private var canvas: CanvasSpec { store.doc.canvas }

    /// The element as the user currently sees it: mid-drag value if there is one.
    private func live(_ element: Element) -> Element { draft[element.id] ?? element }

    private var liveSelection: [Element] { store.selectedElements.map(live) }

    private var liveSingle: Element? { store.singleSelection.map(live) }

    private var liveBounds: CGRect? {
        let frames = liveSelection.map(\.frame)
        guard let first = frames.first else { return nil }
        return frames.dropFirst().reduce(first) { $0.union($1) }
    }

    var body: some View {
        Perf.tick("canvas")
        let size = CanvasZoom.documentSize(canvas: canvas.size, zoom: zoom)
        return board
            // Measured in panel pixels, so the whole document is a pure scale of the
            // artboard — which is what makes ending a pinch land exactly.
            .padding(CanvasZoom.margin * zoom)
            // Exactly the document size the scroll view was given, laid out from the
            // top-left, so AppKit's coordinates and SwiftUI's agree.
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .focusable()
        .focused($canvasFocused)
        .focusEffectDisabled()
        .onAppear { canvasFocused = true }
        .onKeyPress { press in handleKey(press) }
        .onChange(of: liveBounds, initial: true) { _, bounds in viewport.highlight = bounds }
        .onChange(of: store.selection) { _, new in
            if let editing = editingText, !new.contains(editing) { editingText = nil }
        }
    }

    // MARK: - Board

    private var board: some View {
        ZStack(alignment: .topLeading) {
            // The drop shadow lives on its own static rectangle. Hanging it off the
            // board meant re-rendering and re-blurring the whole canvas offscreen on
            // every frame of a drag; this way it is only invalidated by a zoom change.
            Rectangle()
                .fill(Color.white)
                .frame(width: canvas.w * zoom, height: canvas.h * zoom)
                .shadow(color: .black.opacity(0.28), radius: 12, y: 5)

            PosterView(doc: store.doc, scale: zoom, overrides: draft)
                .overlay { if store.panelPreview { PanelPreviewOverlay().environmentObject(store) } }

            if store.showGrid { GridOverlay(canvas: canvas, zoom: zoom, step: store.gridSize) }
            if store.showBleedGuides { SafeAreaOverlay(canvas: canvas, zoom: zoom) }

            overlays
            if let editing = editingText, let element = store.doc[editing] {
                inlineEditor(for: element)
            }
        }
        .frame(width: canvas.w * zoom, height: canvas.h * zoom, alignment: .topLeading)
        .contentShape(Rectangle())
        .gesture(dragGesture)
        .onTapGesture(count: 2) { location in
            let point = CGPoint(x: location.x / zoom, y: location.y / zoom)
            if let hit = store.hitTest(point), hit.type == .text {
                store.select(hit.id)
                editingText = hit.id
                textFieldFocused = true
            }
        }
        .onContinuousHover { phase in
            guard session == nil else { return }   // a drag already knows its target
            switch phase {
            case .active(let location):
                let hit = store.hitTest(CGPoint(x: location.x / zoom, y: location.y / zoom))?.id
                if hit != hoverID { hoverID = hit }
            case .ended:
                if hoverID != nil { hoverID = nil }
            }
        }
        .contextMenu { CanvasContextMenu() }
    }

    @ViewBuilder
    private var overlays: some View {
        Canvas { context, _ in
            // Hover hint
            if let hoverID, !store.selection.contains(hoverID), let e = store.doc[hoverID] {
                context.stroke(outlinePath(e), with: .color(.accentColor.opacity(0.5)), lineWidth: 1)
            }
            // Selected element outlines
            for e in liveSelection {
                context.stroke(outlinePath(e), with: .color(.accentColor), lineWidth: 1.5)
            }
            // Snap guides
            for guide in guides {
                var path = Path()
                if guide.vertical {
                    path.move(to: CGPoint(x: guide.position * zoom, y: guide.from * zoom))
                    path.addLine(to: CGPoint(x: guide.position * zoom, y: guide.to * zoom))
                } else {
                    path.move(to: CGPoint(x: guide.from * zoom, y: guide.position * zoom))
                    path.addLine(to: CGPoint(x: guide.to * zoom, y: guide.position * zoom))
                }
                context.stroke(path, with: .color(PPColor.red.color),
                               style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
            if let marquee {
                let r = CGRect(x: marquee.minX * zoom, y: marquee.minY * zoom,
                               width: marquee.width * zoom, height: marquee.height * zoom)
                context.fill(Path(r), with: .color(.accentColor.opacity(0.12)))
                context.stroke(Path(r), with: .color(.accentColor), lineWidth: 1)
            }
        }
        .allowsHitTesting(false)

        if let element = liveSingle, !element.locked, editingText == nil {
            handleLayer(for: element)
        }

        if let session, session.mode != .marquee, let bounds = liveBounds {
            SizeReadout(rect: bounds, rotation: liveSingle?.rotation ?? 0)
                .position(x: bounds.midX * zoom, y: max(bounds.minY * zoom - 16, 12))
                .allowsHitTesting(false)
        }
    }

    private func outlinePath(_ e: Element) -> Path {
        var path = Path()
        let corners = [CGPoint(x: e.x, y: e.y), CGPoint(x: e.x + e.w, y: e.y),
                       CGPoint(x: e.x + e.w, y: e.y + e.h), CGPoint(x: e.x, y: e.y + e.h)]
            .map { Geometry.rotate($0, around: e.center, degrees: e.rotation) }
            .map { CGPoint(x: $0.x * zoom, y: $0.y * zoom) }
        path.move(to: corners[0])
        for c in corners.dropFirst() { path.addLine(to: c) }
        path.closeSubpath()
        return path
    }

    // MARK: - Handles

    @ViewBuilder
    private func handleLayer(for element: Element) -> some View {
        ForEach(Handle.allCases) { handle in
            let point = Geometry.handlePoint(handle, in: element.frame,
                                             rotation: element.rotation,
                                             offset: 18 / zoom)
            if handle == .rotate {
                Circle()
                    .fill(Color.white)
                    .overlay(Circle().stroke(Color.accentColor, lineWidth: 1.5))
                    .overlay(Image(systemName: "arrow.trianglehead.clockwise")
                        .font(.system(size: 6, weight: .bold)).foregroundStyle(Color.accentColor))
                    .frame(width: 12, height: 12)
                    .position(x: point.x * zoom, y: point.y * zoom)
                    .allowsHitTesting(false)
            } else if element.type != .line || handle == .topLeft || handle == .bottomRight {
                Rectangle()
                    .fill(Color.white)
                    .overlay(Rectangle().stroke(Color.accentColor, lineWidth: 1.5))
                    .frame(width: 9, height: 9)
                    .position(x: point.x * zoom, y: point.y * zoom)
                    .allowsHitTesting(false)
            }
        }
    }

    // MARK: - Inline text editing

    @ViewBuilder
    private func inlineEditor(for element: Element) -> some View {
        let binding = Binding(
            get: { store.doc[element.id]?.text ?? "" },
            set: { newValue in store.update(element.id) { $0.text = newValue } }
        )
        TextField("Text", text: binding, axis: .vertical)
            .textFieldStyle(.plain)
            .font(FontResolver.font(element, size: min(TextFit.fittedSize(element) * zoom, 60)))
            .foregroundStyle((element.fill ?? .black).color)
            .multilineTextAlignment(element.align.swiftUI)
            .focused($textFieldFocused)
            .padding(4)
            .frame(width: max(element.w * zoom, 80), alignment: element.align.frameAlignment)
            .background(RoundedRectangle(cornerRadius: 3).fill(Color(nsColor: .textBackgroundColor).opacity(0.92)))
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.accentColor, lineWidth: 2))
            .offset(x: element.x * zoom, y: element.y * zoom)
            .onSubmit { editingText = nil; canvasFocused = true }
            .onExitCommand { editingText = nil; canvasFocused = true }
            .onAppear { store.begin() }
    }

    // MARK: - Dragging

    private struct DragSession {
        enum Mode: Equatable { case move, resize(Handle), rotate, marquee }
        var mode: Mode
        var start: CGPoint
        var frames: [UUID: CGRect]
        var rotations: [UUID: Double]
        var startAngle: Double = 0
        var didMutate = false
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                let point = CGPoint(x: value.location.x / zoom, y: value.location.y / zoom)
                let start = CGPoint(x: value.startLocation.x / zoom, y: value.startLocation.y / zoom)
                if session == nil { beginSession(at: start) }
                guard var current = session else { return }
                if !current.didMutate, value.translation == .zero, current.mode != .marquee { return }
                if !current.didMutate {
                    current.didMutate = true
                    session = current
                }
                apply(session: current, from: start, to: point)
            }
            .onEnded { value in
                let point = CGPoint(x: value.location.x / zoom, y: value.location.y / zoom)
                if let current = session, current.mode == .marquee, current.didMutate {
                    let rect = CGRect(x: min(current.start.x, point.x), y: min(current.start.y, point.y),
                                      width: abs(point.x - current.start.x),
                                      height: abs(point.y - current.start.y))
                    let hits = store.elements(intersecting: rect).map(\.id)
                    store.selection = NSEvent.modifierFlags.contains(.shift)
                        ? store.selection.union(hits) : Set(hits)
                }
                commitDraft()
                session = nil
                guides = []
                marquee = nil
                canvasFocused = true
            }
    }

    /// Fold the drag's live values into the document as a single undo step.
    private func commitDraft() {
        guard !draft.isEmpty else { return }
        let changes = draft.filter { id, element in store.doc[id] != element }
        draft = [:]
        guard !changes.isEmpty else { return }
        store.begin()
        for (id, element) in changes {
            store.update(id) { $0 = element }
        }
    }

    private func setDraft(_ id: UUID, _ transform: (inout Element) -> Void) {
        guard var element = draft[id] ?? store.doc[id], !element.locked else { return }
        transform(&element)
        draft[id] = element
    }

    private func beginSession(at start: CGPoint) {
        let modifiers = NSEvent.modifierFlags

        // A handle of the single selection wins over anything underneath it.
        if let element = liveSingle, !element.locked {
            let grab = 9.0 / zoom
            for handle in Handle.allCases {
                if element.type == .line && ![.topLeft, .bottomRight, .rotate].contains(handle) { continue }
                let point = Geometry.handlePoint(handle, in: element.frame,
                                                 rotation: element.rotation,
                                                 offset: 18 / zoom)
                if hypot(point.x - start.x, point.y - start.y) <= grab {
                    let mode: DragSession.Mode = handle == .rotate ? .rotate : .resize(handle)
                    session = DragSession(mode: mode, start: start,
                                          frames: [element.id: element.frame],
                                          rotations: [element.id: element.rotation],
                                          startAngle: angle(from: element.center, to: start))
                    return
                }
            }
        }

        if let hit = store.hitTest(start) {
            if modifiers.contains(.shift) {
                store.select(hit.id, additive: true)
            } else if !store.selection.contains(hit.id) {
                store.select(hit.id)
            }
            session = DragSession(mode: .move, start: start,
                                  frames: Dictionary(uniqueKeysWithValues: store.selectedElements.map { ($0.id, $0.frame) }),
                                  rotations: [:])
        } else {
            if !modifiers.contains(.shift) { store.selection.removeAll() }
            session = DragSession(mode: .marquee, start: start, frames: [:], rotations: [:])
        }
    }

    private func apply(session current: DragSession, from start: CGPoint, to point: CGPoint) {
        let modifiers = NSEvent.modifierFlags
        let shift = modifiers.contains(.shift)
        let option = modifiers.contains(.option)
        let noSnap = modifiers.contains(.command) || !store.snapEnabled

        switch current.mode {
        case .marquee:
            marquee = CGRect(x: min(start.x, point.x), y: min(start.y, point.y),
                             width: abs(point.x - start.x), height: abs(point.y - start.y))

        case .move:
            var dx = point.x - start.x, dy = point.y - start.y
            if shift { if abs(dx) > abs(dy) { dy = 0 } else { dx = 0 } }

            // Snap the selection's bounding box, then move everything by the same delta.
            let originalBounds = current.frames.values.reduce(into: CGRect?.none) { acc, r in
                acc = acc.map { $0.union(r) } ?? r
            }
            if let originalBounds, !noSnap {
                let moved = originalBounds.offsetBy(dx: dx, dy: dy)
                let others = store.doc.elements.filter { !store.selection.contains($0.id) }
                let (snapped, hits) = Snapper.snap(rect: moved, canvas: canvas.size,
                                                   others: others, scale: zoom)
                dx += snapped.minX - moved.minX
                dy += snapped.minY - moved.minY
                guides = hits
            } else {
                guides = []
            }
            for (id, frame) in current.frames {
                setDraft(id) { e in
                    var x = frame.minX + dx, y = frame.minY + dy
                    if store.snapEnabled && !noSnap && store.showGrid {
                        x = (x / store.gridSize).rounded() * store.gridSize
                        y = (y / store.gridSize).rounded() * store.gridSize
                    }
                    e.x = x; e.y = y
                }
            }

        case .resize(let handle):
            guard let (id, frame) = current.frames.first else { return }
            let rotation = current.rotations[id] ?? 0
            // Work in the element's own space so rotated resizes stay intuitive.
            let localPoint = Geometry.rotate(point, around: CGPoint(x: frame.midX, y: frame.midY),
                                             degrees: -rotation)
            var newRect = Geometry.resize(frame, handle: handle, to: localPoint,
                                          keepAspect: shift, fromCenter: option)
            if !noSnap, rotation == 0, !shift {
                let others = store.doc.elements.filter { $0.id != id }
                let (snapped, hits) = Snapper.snapResize(rect: newRect, handle: handle,
                                                         canvas: canvas.size,
                                                         others: others, scale: zoom)
                newRect = snapped
                guides = hits
            } else {
                guides = []
            }
            if rotation != 0 {
                // Keep the visual centre put by compensating for the rotated frame shift.
                let oldCenter = CGPoint(x: frame.midX, y: frame.midY)
                let newCenter = CGPoint(x: newRect.midX, y: newRect.midY)
                let rotated = Geometry.rotate(newCenter, around: oldCenter, degrees: rotation)
                newRect.origin.x += rotated.x - newCenter.x
                newRect.origin.y += rotated.y - newCenter.y
            }
            setDraft(id) { $0.frame = newRect }

        case .rotate:
            guard let (id, frame) = current.frames.first else { return }
            let centre = CGPoint(x: frame.midX, y: frame.midY)
            let delta = angle(from: centre, to: point) - current.startAngle
            var value = (current.rotations[id] ?? 0) + delta
            if shift { value = (value / 15).rounded() * 15 }
            setDraft(id) { $0.rotation = value.truncatingRemainder(dividingBy: 360) }
        }
    }

    private func angle(from centre: CGPoint, to point: CGPoint) -> Double {
        atan2(point.y - centre.y, point.x - centre.x) * 180 / .pi
    }

    // MARK: - Keyboard

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        guard editingText == nil else { return .ignored }
        let step: Double = press.modifiers.contains(.shift) ? 10 : 1
        switch press.key {
        case .leftArrow:  nudge(dx: -step, dy: 0); return .handled
        case .rightArrow: nudge(dx: step, dy: 0); return .handled
        case .upArrow:    nudge(dx: 0, dy: -step); return .handled
        case .downArrow:  nudge(dx: 0, dy: step); return .handled
        case .delete, .deleteForward:
            store.deleteSelected(); return .handled
        case .escape:
            store.selection.removeAll(); return .handled
        case .return:
            if let e = store.singleSelection, e.type == .text {
                editingText = e.id; textFieldFocused = true; return .handled
            }
            return .ignored
        default:
            return .ignored
        }
    }

    private func nudge(dx: Double, dy: Double) {
        guard !store.selection.isEmpty else { return }
        store.begin()
        store.updateSelected { $0.x += dx; $0.y += dy }
    }
}

// MARK: - Decoration

private struct GridOverlay: View {
    let canvas: CanvasSpec
    let zoom: Double
    let step: Double

    var body: some View {
        Canvas { context, size in
            guard step > 0.5 else { return }
            var path = Path()
            var x = step
            while x < canvas.w { path.move(to: CGPoint(x: x * zoom, y: 0)); path.addLine(to: CGPoint(x: x * zoom, y: size.height)); x += step }
            var y = step
            while y < canvas.h { path.move(to: CGPoint(x: 0, y: y * zoom)); path.addLine(to: CGPoint(x: size.width, y: y * zoom)); y += step }
            context.stroke(path, with: .color(.gray.opacity(0.28)), lineWidth: 0.5)
        }
        .frame(width: canvas.w * zoom, height: canvas.h * zoom)
        .allowsHitTesting(false)
    }
}

/// A hairline inset reminding you that panel bezels eat the outermost pixels.
private struct SafeAreaOverlay: View {
    let canvas: CanvasSpec
    let zoom: Double
    var body: some View {
        Rectangle()
            .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
            .foregroundStyle(Color.accentColor.opacity(0.35))
            .padding(6 * zoom)
            .frame(width: canvas.w * zoom, height: canvas.h * zoom)
            .allowsHitTesting(false)
    }
}

private struct SizeReadout: View {
    let rect: CGRect
    let rotation: Double
    var body: some View {
        Text(rotation == 0
             ? "\(Int(rect.width.rounded())) × \(Int(rect.height.rounded()))"
             : "\(Int(rect.width.rounded())) × \(Int(rect.height.rounded()))  \(Int(rotation.rounded()))°")
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(Color.accentColor))
            .foregroundStyle(.white)
    }
}

/// Live look at the reduced bitmap the panel will actually paint.
///
/// Reducing 120,000 pixels costs ~11 ms, which is far too much to spend inside a
/// view body during a drag, so it runs off the document revision with a short
/// debounce: the preview settles a moment after you stop moving things.
private struct PanelPreviewOverlay: View {
    @EnvironmentObject var store: Store
    @ViewState private var image: CGImage?

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let image {
                Image(decorative: image, scale: 1, orientation: .up)
                    .resizable()
                    .interpolation(.none)
            }
            // Without a marker the mode is invisible on artwork that is already
            // on-gamut — which is most of it, since the editor draws in the four inks.
            Text("PANEL PREVIEW")
                .font(.system(size: 9, weight: .heavy))
                .kerning(0.5)
                .foregroundStyle(.white)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(PPColor.red.color)
                .padding(4)
        }
        .overlay(Rectangle().strokeBorder(PPColor.red.color, lineWidth: 2))
        .allowsHitTesting(false)
        .task(id: store.revision) {
            try? await Task.sleep(for: .milliseconds(90))
            guard !Task.isCancelled else { return }
            image = Exporter.panelImage(store.doc, quantize: true, dither: .none)
        }
    }
}

private struct CanvasContextMenu: View {
    @EnvironmentObject var store: Store
    var body: some View {
        Group {
            Button("Bring to Front") { store.bringToFront() }
            Button("Bring Forward") { store.bringForward() }
            Button("Send Backward") { store.sendBackward() }
            Button("Send to Back") { store.sendToBack() }
            Divider()
            Button("Duplicate") { store.duplicateSelected() }
            Button("Delete") { store.deleteSelected() }
            Divider()
            Button("Fill Canvas") { store.fitSelectedToCanvas() }
        }
        .disabled(store.selection.isEmpty)
    }
}


// MARK: - Rulers

/// A pixel scale pinned along the top or left of the canvas area. It follows the
/// artboard as you scroll and pinch — live, mid-gesture — instead of scrolling away with
/// it, and shades the selection's extent so you can read off how far a shape reaches.
struct ViewportRuler: View {
    @ObservedObject var viewport: CanvasViewport
    let horizontal: Bool

    var body: some View {
        let zoom = viewport.zoom
        let magnification = viewport.magnification
        let origin = Double(horizontal ? viewport.origin.x : viewport.origin.y)
        let span = Double(horizontal ? viewport.canvasSize.width : viewport.canvasSize.height)
        let highlight = viewport.highlight.map { horizontal ? ($0.minX, $0.maxX) : ($0.minY, $0.maxY) }

        return Canvas { context, size in
            let thickness = horizontal ? size.height : size.width
            let length = horizontal ? size.width : size.height
            func at(_ value: Double) -> Double {
                CanvasZoom.rulerPosition(value: value, zoom: zoom, magnification: magnification, origin: origin)
            }
            func strip(_ from: Double, _ to: Double) -> CGRect {
                horizontal ? CGRect(x: from, y: 0, width: to - from, height: thickness)
                           : CGRect(x: 0, y: from, width: thickness, height: to - from)
            }

            // The panel's own extent reads lighter, so the scale belongs to the artboard.
            let panelStart = max(at(0), 0), panelEnd = min(at(span), length)
            if panelEnd > panelStart {
                context.fill(Path(strip(panelStart, panelEnd)), with: .color(Color(nsColor: .textBackgroundColor)))
            }
            if let (low, high) = highlight {
                let from = max(at(Double(low)), 0), to = min(at(Double(high)), length)
                if to >= from {
                    context.fill(Path(strip(from, max(to, from + 1))), with: .color(.accentColor.opacity(0.28)))
                }
            }

            let major = CanvasZoom.rulerStep(pointsPerPixel: zoom * magnification)
            let minor = major / 5
            let firstVisible = CanvasZoom.rulerValue(position: 0, zoom: zoom, magnification: magnification, origin: origin)
            let lastVisible = CanvasZoom.rulerValue(position: length, zoom: zoom, magnification: magnification, origin: origin)
            var value = max(0, (firstVisible / minor).rounded(.down) * minor)
            let end = min(span, lastVisible)

            var ticks = Path()
            while value <= end + 0.01 {
                let isMajor = abs(value.truncatingRemainder(dividingBy: major)) < 0.01
                let depth = isMajor ? thickness * 0.55 : thickness * 0.28
                let position = at(value)
                if horizontal {
                    ticks.move(to: CGPoint(x: position, y: thickness))
                    ticks.addLine(to: CGPoint(x: position, y: thickness - depth))
                } else {
                    ticks.move(to: CGPoint(x: thickness, y: position))
                    ticks.addLine(to: CGPoint(x: thickness - depth, y: position))
                }
                if isMajor {
                    let label = Text("\(Int(value))")
                        .font(.system(size: 8, design: .monospaced))
                        .foregroundStyle(.secondary)
                    // The last label would hang off the panel's end; tuck it back inside.
                    let atEnd = value >= span - 0.01
                    if horizontal {
                        context.draw(label,
                                     at: CGPoint(x: atEnd ? position - 2 : position + 2, y: 1),
                                     anchor: atEnd ? .topTrailing : .topLeading)
                    } else {
                        context.draw(label,
                                     at: CGPoint(x: thickness / 2 - 1, y: atEnd ? position - 1 : position + 1),
                                     anchor: atEnd ? .bottom : .top)
                    }
                }
                value += minor
            }
            context.stroke(ticks, with: .color(.secondary.opacity(0.65)), lineWidth: 0.75)

            var edge = Path()
            if horizontal {
                edge.move(to: CGPoint(x: 0, y: thickness - 0.25))
                edge.addLine(to: CGPoint(x: size.width, y: thickness - 0.25))
            } else {
                edge.move(to: CGPoint(x: thickness - 0.25, y: 0))
                edge.addLine(to: CGPoint(x: thickness - 0.25, y: size.height))
            }
            context.stroke(edge, with: .color(.secondary.opacity(0.5)), lineWidth: 0.5)
        }
        .frame(width: horizontal ? nil : CanvasZoom.rulerThickness,
               height: horizontal ? CanvasZoom.rulerThickness : nil)
        .background(Color(nsColor: .controlBackgroundColor))
        .allowsHitTesting(false)
    }
}

struct RulerCorner: View {
    var body: some View {
        Text("px")
            .font(.system(size: 8, design: .monospaced))
            .foregroundStyle(.secondary)
            .frame(width: CanvasZoom.rulerThickness, height: CanvasZoom.rulerThickness)
            .background(Color(nsColor: .controlBackgroundColor))
    }
}
