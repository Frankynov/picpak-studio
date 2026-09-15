import Foundation
import AppKit

/// Reads the image's stored bytes with no redraw and no colour conversion.
func strayCount(_ image: CGImage) -> Int {
    guard let data = image.dataProvider?.data,
          let bytes = CFDataGetBytePtr(data) else { return -1 }
    let bpp = image.bitsPerPixel / 8
    let stride = image.bytesPerRow
    let allowed: Set<[UInt8]> = Set(PPColor.allCases.map {
        [UInt8($0.rgb.r * 255), UInt8($0.rgb.g * 255), UInt8($0.rgb.b * 255)]
    })
    var stray = 0
    for y in 0..<image.height {
        for x in 0..<image.width {
            let i = y * stride + x * bpp
            if !allowed.contains([bytes[i], bytes[i + 1], bytes[i + 2]]) { stray += 1 }
        }
    }
    return stray
}

@MainActor
func run() {
    var failures = 0
    func check(_ label: String, _ ok: Bool, _ detail: String = "") {
        print(ok ? "  ok   \(label) \(detail)" : "  FAIL \(label) \(detail)")
        if !ok { failures += 1 }
    }

    print("SF Symbols catalog: \(SymbolCatalog.all.count)")
    check("catalog non-trivial", SymbolCatalog.all.count > 3000)
    check("search finds leaf", SymbolCatalog.search("leaf").contains("leaf.fill"))

    for template in Template.allCases {
        let doc = template.build()
        print("\nTemplate: \(template.title) — \(doc.elements.count) elements")

        guard let image = Exporter.panelImage(doc, quantize: true, dither: .none) else {
            check("render \(template.title)", false); continue
        }
        check("size 400x300", image.width == 400 && image.height == 300,
              "\(image.width)x\(image.height)")

        let histogram = Exporter.histogram(image)
        let total = histogram.values.reduce(0, +)
        check("every pixel on-gamut", total == 400 * 300, "\(total)/120000")
        let share = histogram
            .sorted { $0.value > $1.value }
            .map { "\($0.key.rawValue) \(String(format: "%.1f", Double($0.value) / 1200))%" }
        print("       inks: \(share.joined(separator: ", "))")

        // Confirm the stored bytes really are only the four inks (no colour conversion).
        check("no intermediate colours", strayCount(image) == 0, "\(strayCount(image)) stray pixels")

        // PNG round-trip: export, reopen, compare.
        do {
            let png = try Exporter.pngData(doc, options: .init(scale: 1, quantize: true,
                                                               dither: .none, embedProject: true))
            check("png decodes", NSImage(data: png) != nil, "\(png.count) bytes")
            if let src = CGImageSourceCreateWithData(png as CFData, nil),
               let decoded = CGImageSourceCreateImageAtIndex(src, 0, nil) {
                check("png file bytes on-gamut", strayCount(decoded) == 0,
                      "\(strayCount(decoded)) stray pixels")
            } else { check("png reopens", false) }
            let reopened = try Exporter.documentFromPNG(png)
            check("project survives the PNG", reopened.elements == doc.elements,
                  "\(reopened.elements.count) elements back")
            check("canvas survives", reopened.canvas == doc.canvas)

            // .picpak round-trip
            let json = try doc.encoded()
            let back = try PicPakDocument.decode(json)
            check("picpak round-trip", back.elements == doc.elements)

            let big = try Exporter.pngData(doc, options: .init(scale: 4, quantize: true,
                                                               dither: .none, embedProject: false))
            let bigImage = NSImage(data: big)
            check("@4x is 1600x1200", bigImage?.representations.first.map {
                $0.pixelsWide == 1600 && $0.pixelsHigh == 1200 } ?? false)
        } catch {
            check("export round-trip", false, "\(error)")
        }
    }

    // Forward compatibility: unknown fields and missing fields must not break loading.
    let sparse = """
    {"format":"picpak.studio.document","version":1,
     "canvas":{"w":400,"h":300,"background":"yellow"},
     "elements":[{"id":"\(UUID().uuidString)","type":"rect","x":1,"y":2,"w":3,"h":4,
                  "fill":"red","futureField":"ignored"}],
     "assets":{}}
    """
    do {
        let doc = try PicPakDocument.decode(Data(sparse.utf8))
        check("sparse document loads", doc.elements.count == 1)
        check("defaults filled in", doc.elements[0].fontSize == 32 && doc.elements[0].contrast == 1)
        check("unknown fields ignored", doc.elements[0].fill == .red)
    } catch {
        check("sparse document loads", false, "\(error)")
    }

    // Edge snapping during a resize: dragging an edge near a target must land on it
    // exactly, and must move only that edge.
    let canvasSize = CGSize(width: 400, height: 300)
    var neighbour = Element.make(.rect, at: CGRect(x: 260, y: 0, width: 60, height: 300))

    func resizeSnap(_ rect: CGRect, _ handle: Handle, others: [Element] = []) -> CGRect {
        Snapper.snapResize(rect: rect, handle: handle, canvas: canvasSize,
                           others: others, scale: 2).0
    }

    let toMiddle = resizeSnap(CGRect(x: 0, y: 0, width: 198, height: 300), .right)
    check("right edge snaps to panel centre",
          toMiddle == CGRect(x: 0, y: 0, width: 200, height: 300), "\(toMiddle)")

    let leftEdge = resizeSnap(CGRect(x: 3, y: 40, width: 120, height: 60), .left)
    check("left edge snaps to panel edge, right edge stays",
          leftEdge.minX == 0 && leftEdge.maxX == 123, "\(leftEdge)")

    let toNeighbour = resizeSnap(CGRect(x: 20, y: 10, width: 238, height: 40),
                                 .right, others: [neighbour])
    check("right edge snaps to a neighbour's left edge",
          toNeighbour.maxX == 260, "\(toNeighbour)")

    let farAway = CGRect(x: 20, y: 10, width: 100, height: 40)
    check("nothing snaps when nothing is near", resizeSnap(farAway, .right) == farAway)

    let bottom = resizeSnap(CGRect(x: 10, y: 10, width: 50, height: 139), .bottom)
    check("bottom edge snaps to panel centre",
          bottom.maxY == 150 && bottom.minY == 10, "\(bottom)")

    let corner = resizeSnap(CGRect(x: 0, y: 0, width: 197, height: 148), .bottomRight)
    check("a corner snaps on both axes at once",
          corner.width == 200 && corner.height == 150, "\(corner)")

    // A hidden element must not attract anything.
    neighbour.hidden = true
    let ignoresHidden = CGRect(x: 20, y: 10, width: 238, height: 40)
    check("hidden elements don't attract",
          resizeSnap(ignoresHidden, .right, others: [neighbour]).maxX == 258,
          "\(resizeSnap(ignoresHidden, .right, others: [neighbour]))")

    // Layer reordering. The panel lists front-to-back, the document stores
    // back-to-front, so every offset here crosses a reversal.
    func names(_ store: Store) -> String { store.doc.elements.map(\.name).joined() }

    func layerStore() -> Store {
        let s = Store()
        s.doc.elements = ["A", "B", "C", "D"].map { name in
            var e = Element.make(.rect, at: CGRect(x: 0, y: 0, width: 10, height: 10))
            e.name = name
            return e
        }
        return s
    }
    // Document order A,B,C,D means the panel lists D,C,B,A (front-most first).

    var ls = layerStore()
    let a = ls.doc.elements[0].id
    ls.moveLayers(ids: [a], toTopDownOffset: 0)
    check("dragging the bottom layer to the top of the list brings it to the front",
          names(ls) == "BCDA", names(ls))

    ls = layerStore()
    let d = ls.doc.elements[3].id
    ls.moveLayers(ids: [d], toTopDownOffset: 2)
    check("dragging the front layer down two rows", names(ls) == "ABDC", names(ls))

    ls = layerStore()
    let c = ls.doc.elements[2].id
    ls.moveLayers(ids: [c], toTopDownOffset: 4)
    check("dropping past the last row sends it to the back", names(ls) == "CABD", names(ls))

    ls = layerStore()
    ls.moveLayers(ids: [ls.doc.elements[0].id, ls.doc.elements[1].id], toTopDownOffset: 0)
    check("a multi-layer drag keeps the pair's own order", names(ls) == "CDAB", names(ls))

    ls = layerStore()
    let before = names(ls)
    ls.moveLayers(ids: [ls.doc.elements[3].id], toTopDownOffset: 0)
    check("dropping a layer where it already is changes nothing", names(ls) == before, names(ls))
    check("...and doesn't add an undo step", !ls.canUndo)

    ls = layerStore()
    ls.moveLayers(ids: [], toTopDownOffset: 2)
    check("an empty drag is ignored", names(ls) == "ABCD" && !ls.canUndo)

    // Scroll routing. The whole point is that a trackpad keeps panning while a mouse
    // wheel zooms, so the device distinction matters more than the exact factors.
    func routes(precise: Bool, cmd: Bool, delta: Double) -> Double? {
        CanvasZoom.zoomFactor(precise: precise, commandHeld: cmd, deltaY: delta)
    }

    check("mouse wheel zooms in when scrolled up",
          (routes(precise: false, cmd: false, delta: 1) ?? 0) > 1)
    check("mouse wheel zooms out when scrolled down",
          (routes(precise: false, cmd: false, delta: -1) ?? 0) < 1)
    check("trackpad scrolling is left alone so it can still pan",
          routes(precise: true, cmd: false, delta: 12) == nil)
    check("trackpad zooms with command held",
          (routes(precise: true, cmd: true, delta: 12) ?? 0) > 1)
    check("command-wheel zooms too",
          (routes(precise: false, cmd: true, delta: 1) ?? 0) > 1)
    check("a wheel notch moves more than a trackpad point",
          (routes(precise: false, cmd: false, delta: 1) ?? 0)
            > (routes(precise: true, cmd: true, delta: 1) ?? 0))
    check("a zero delta is consumed without changing the zoom",
          routes(precise: false, cmd: false, delta: 0) == 1)

    // Folding a live pinch into the zoom must leave every artboard point exactly where
    // it was on screen — otherwise the canvas visibly jumps as the fingers lift. That
    // includes pinching while scrolled hard against an edge: the new origin has to stay
    // inside the scrollable range, or the clip view clamps it and the canvas snaps.
    let boardSize = CGSize(width: 400, height: 300)
    let viewportSize = CGSize(width: 700, height: 500)
    func screenPosition(_ point: CGPoint, zoom: Double, magnification: Double, origin: CGPoint) -> CGPoint {
        CGPoint(x: ((Double(point.x) + CanvasZoom.margin) * zoom - Double(origin.x)) * magnification,
                y: ((Double(point.y) + CanvasZoom.margin) * zoom - Double(origin.y)) * magnification)
    }
    func scrollRange(zoom: Double, magnification: Double) -> CGSize {
        let doc = CanvasZoom.documentSize(canvas: boardSize, zoom: zoom)
        return CGSize(width: max(Double(doc.width) - Double(viewportSize.width) / magnification, 0),
                      height: max(Double(doc.height) - Double(viewportSize.height) / magnification, 0))
    }
    var bakeDrift = 0.0
    var leftRange = false
    for (zoom, m) in [(2.0, 1.5), (3.0, 2.25), (4.0, 0.6), (6.0, 1.9)] {
        let range = scrollRange(zoom: zoom, magnification: m)
        // Scrolled to the top-left edge, the middle, and the bottom-right edge.
        for origin in [CGPoint.zero,
                       CGPoint(x: range.width / 2, y: range.height / 2),
                       CGPoint(x: range.width, y: range.height)] {
            let baked = CanvasZoom.bakedOrigin(origin: origin, magnification: m)
            let after = scrollRange(zoom: zoom * m, magnification: 1)
            if Double(baked.x) < -1e-9 || Double(baked.y) < -1e-9
                || Double(baked.x) > Double(after.width) + 1e-9 || Double(baked.y) > Double(after.height) + 1e-9 {
                leftRange = true
            }
            for point in [CGPoint.zero, CGPoint(x: 120, y: 80), CGPoint(x: 400, y: 300)] {
                let a = screenPosition(point, zoom: zoom, magnification: m, origin: origin)
                let b = screenPosition(point, zoom: zoom * m, magnification: 1, origin: baked)
                bakeDrift = max(bakeDrift, abs(Double(a.x - b.x)), abs(Double(a.y - b.y)))
            }
        }
    }
    check("ending a pinch leaves the artboard exactly where it was", bakeDrift < 1e-9,
          "max drift \(bakeDrift) pt")
    check("ending a pinch against an edge stays inside the scrollable range", !leftRange)
    check("a magnification of 1 changes nothing",
          CanvasZoom.bakedOrigin(origin: CGPoint(x: 37, y: 12), magnification: 1) == CGPoint(x: 37, y: 12))

    let doc2 = CanvasZoom.documentSize(canvas: boardSize, zoom: 2)
    check("the document is a pure scale of the artboard and its margin",
          doc2 == CGSize(width: (400 + 2 * CanvasZoom.margin) * 2, height: (300 + 2 * CanvasZoom.margin) * 2))

    // A toolbar zoom keeps whatever was at the centre of the view at the centre.
    let visibleRect = CGRect(x: 100, y: 50, width: 500, height: 400)
    let recentred = CanvasZoom.recentredOrigin(visible: visibleRect, oldZoom: 2, newZoom: 3)
    let centreBefore = CGPoint(x: Double(visibleRect.midX) / 2, y: Double(visibleRect.midY) / 2)
    let centreAfter = CGPoint(x: (Double(recentred.x) + 250) / 3, y: (Double(recentred.y) + 200) / 3)
    check("toolbar zoom keeps the centre of the view in place",
          abs(Double(centreBefore.x - centreAfter.x)) < 1e-9 && abs(Double(centreBefore.y - centreAfter.y)) < 1e-9,
          "\(centreBefore) vs \(centreAfter)")

    // The pinned rulers must line up with the artboard under any zoom, pinch or scroll.
    var rulerError = 0.0
    for (zoom, m, origin) in [(2.0, 1.0, 0.0), (3.0, 1.7, 215.0), (0.5, 0.8, -40.0)] {
        for value in [0.0, 50, 400] {
            let position = CanvasZoom.rulerPosition(value: value, zoom: zoom, magnification: m, origin: origin)
            let screen = screenPosition(CGPoint(x: value, y: 0), zoom: zoom, magnification: m,
                                        origin: CGPoint(x: origin, y: 0))
            rulerError = max(rulerError, abs(position - Double(screen.x)))
            let back = CanvasZoom.rulerValue(position: position, zoom: zoom, magnification: m, origin: origin)
            rulerError = max(rulerError, abs(back - value))
        }
    }
    check("ruler ticks sit exactly over the artboard pixels they label", rulerError < 1e-9,
          "max error \(rulerError)")
    check("ruler labels stay readable when zoomed right out",
          CanvasZoom.rulerStep(pointsPerPixel: 0.25) * 0.25 >= 40 || CanvasZoom.rulerStep(pointsPerPixel: 0.25) == 200)
    check("ruler labels get finer when zoomed right in", CanvasZoom.rulerStep(pointsPerPixel: 12) == 5)

    // Wheel zoom anchors by hand: the document point under the pointer keeps its place in
    // the viewport across the magnification change.
    var anchorDrift = 0.0
    for (m0, m1, origin, point) in [(1.0, 1.15, CGPoint(x: 120, y: 40), CGPoint(x: 300, y: 260)),
                                    (1.7, 2.3, CGPoint(x: -35, y: 10), CGPoint(x: 90, y: 400)),
                                    (0.8, 0.5, CGPoint(x: 600, y: 300), CGPoint(x: 900, y: 500))] {
        let offset = CGPoint(x: (Double(point.x) - Double(origin.x)) * m0,
                             y: (Double(point.y) - Double(origin.y)) * m0)
        let moved = CanvasZoom.anchoredOrigin(point: point, offset: offset, magnification: m1)
        let after = CGPoint(x: (Double(point.x) - Double(moved.x)) * m1,
                            y: (Double(point.y) - Double(moved.y)) * m1)
        anchorDrift = max(anchorDrift, abs(Double(after.x - offset.x)), abs(Double(after.y - offset.y)))
    }
    check("wheel zoom keeps the point under the pointer in place", anchorDrift < 1e-9,
          "max drift \(anchorDrift) pt")

    // Resting limits: a small document rests centred, a large one fills the view.
    check("a document smaller than the view rests centred",
          CanvasZoom.restingOrigin(123, document: 680, visible: 777) == -48.5)
    check("a document larger than the view rests inside its range",
          CanvasZoom.restingOrigin(-16, document: 880, visible: 792) == 0
            && CanvasZoom.restingOrigin(500, document: 880, visible: 792) == 88)

    // The case that jumped: at 200 % the artboard fits vertically, and zooming in on its
    // upper part makes it taller than the view. Free to overshoot mid-zoom, the pixel under
    // the pointer stays exactly put; only afterwards does the view glide back into range.
    do {
        let doc = CanvasZoom.documentSize(canvas: CGSize(width: 400, height: 300), zoom: 2)
        let view = CGSize(width: 792, height: 777)
        let point = CGPoint(x: (300 + CanvasZoom.margin) * 2, y: (80 + CanvasZoom.margin) * 2)
        var m = 1.0
        var origin = CGPoint(x: 44, y: CanvasZoom.restingOrigin(0, document: Double(doc.height),
                                                             visible: Double(view.height)))
        let start = CGPoint(x: (Double(point.x) - Double(origin.x)) * m, y: (Double(point.y) - Double(origin.y)) * m)
        for _ in 0..<4 {
            let offset = CGPoint(x: (Double(point.x) - Double(origin.x)) * m, y: (Double(point.y) - Double(origin.y)) * m)
            m *= 1.15
            origin = CanvasZoom.anchoredOrigin(point: point, offset: offset, magnification: m)
        }
        let end = CGPoint(x: (Double(point.x) - Double(origin.x)) * m, y: (Double(point.y) - Double(origin.y)) * m)
        let drift = hypot(Double(end.x - start.x), Double(end.y - start.y))
        check("zooming in on a centred artboard keeps the pointer's pixel still", drift < 1e-9,
              "\(drift) pt")
    }

    // AppKit aborts on a non-finite scroll rectangle ("Invalid view geometry: x is NaN"),
    // so the clip view must never pass one on — and outside the zoom code's own synchronous
    // overshoot scope, every position is pulled back inside the limits.
    do {
        let clipView = CenteringClipView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        clipView.documentView = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let bad = clipView.constrainBoundsRect(NSRect(x: CGFloat.nan, y: 10, width: 300, height: 200))
        check("a NaN scroll position never gets through the clip view",
              bad.origin.x.isFinite && bad.origin.y.isFinite && bad.width.isFinite, "\(bad)")
        // AppKit finds the ends of the scrollable range by proposing ±infinity; answering
        // with the current position made panning towards the start stick after a few points.
        clipView.setBoundsOrigin(NSPoint(x: 250, y: 200))
        let start = clipView.constrainBoundsRect(NSRect(x: -CGFloat.infinity, y: -CGFloat.infinity, width: 300, height: 200))
        let end = clipView.constrainBoundsRect(NSRect(x: CGFloat.infinity, y: CGFloat.infinity, width: 300, height: 200))
        clipView.setBoundsOrigin(.zero)
        check("proposing -infinity finds the start of the scrollable range, wherever the view is",
              start.origin == .zero, "\(start.origin)")
        check("proposing +infinity finds the end of the scrollable range",
              end.origin == CGPoint(x: 500, y: 400), "\(end.origin)")
        let far = clipView.constrainBoundsRect(NSRect(x: -500, y: 9000, width: 300, height: 200))
        check("scroll positions are pulled back inside the limits", far.origin.x == 0 && far.origin.y == 400, "\(far)")
        var inside = NSRect.zero
        clipView.overshooting { inside = clipView.constrainBoundsRect(NSRect(x: -500, y: 9000, width: 300, height: 200)) }
        let after = clipView.constrainBoundsRect(NSRect(x: -500, y: 9000, width: 300, height: 200))
        check("overshoot is allowed only inside the synchronous scope",
              inside.origin.x == -500 && after.origin.x == 0, "inside \(inside), after \(after)")
    }

    // A fresh install has no server configured; that has to be a quiet no-op, not a crash.
    check("blank address yields no client", TesseraeSettings.normalizedURL("") == nil)
    check("whitespace-only address yields no client", TesseraeSettings.normalizedURL("   ") == nil)
    check("bare host:port gets a scheme",
          TesseraeSettings.normalizedURL("192.168.1.5:8766")?.absoluteString == "http://192.168.1.5:8766/")
    check("an explicit scheme is kept",
          TesseraeSettings.normalizedURL("https://tess.local:8766")?.absoluteString == "https://tess.local:8766/")
    check("a trailing slash isn't doubled",
          TesseraeSettings.normalizedURL("http://tess.local:8766/")?.absoluteString == "http://tess.local:8766/")
    check("a hostless string is rejected", TesseraeSettings.normalizedURL("http://") == nil)

    // Every symbol the UI names must actually exist, or it renders as a blank button.
    var missingSymbols: [String] = []
    for type in ElementType.allCases where !SymbolAvailability.exists(type.symbol) {
        missingSymbols.append("\(type.rawValue) -> \(type.symbol)")
    }
    for name in ["doc.badge.plus", "folder", "square.and.arrow.down", "arrow.uturn.backward",
                 "arrow.uturn.forward", "plus.magnifyingglass", "ruler", "eye.square",
                 "square.and.arrow.up", "dot.radiowaves.up.forward", "magnifyingglass",
                 "line.3.horizontal", "eye", "eye.slash", "lock.fill", "lock.open", "trash",
                 "plus.square.on.square", "chevron.up", "chevron.down", "photo", "qrcode",
                 "hexagon", "arrowshape.right", "point.topleft.down.to.point.bottomright.curvepath",
                 "square.stack.3d.up.slash", "paperplane.fill", "checkmark.circle.fill",
                 "exclamationmark.triangle.fill", "questionmark.square.dashed"]
    where !SymbolAvailability.exists(name) {
        missingSymbols.append(name)
    }
    check("every named SF Symbol exists on this system", missingSymbols.isEmpty,
          missingSymbols.joined(separator: ", "))
    check("a bogus symbol falls back rather than vanishing",
          SymbolAvailability.resolve("definitely.not.a.symbol", fallback: "circle") == "circle")

    // New shapes must produce a real path, not an empty one.
    let box = CGRect(x: 0, y: 0, width: 100, height: 60)
    check("polygon draws", !PolygonShape(sides: 6).path(in: box).isEmpty)
    check("polygon clamps below 3 sides", !PolygonShape(sides: 1).path(in: box).isEmpty)
    check("arrow draws", !ArrowShape().path(in: box).isEmpty)
    check("arrow with a zero-size box stays empty", ArrowShape().path(in: .zero).isEmpty)
    let wideHead = ArrowShape(head: 5, thickness: 5).path(in: box).boundingRect
    check("arrow clamps silly proportions to its box",
          wideHead.maxX <= box.maxX + 0.01 && wideHead.maxY <= box.maxY + 0.01, "\(wideHead)")

    // Version comparison decides whether an update is offered, so it has to be
    // numeric — as text, "1.10" sorts before "1.9".
    func v(_ s: String) -> AppVersion? { AppVersion(s) }
    check("a leading v is ignored", v("v1.2") == v("1.2"))
    check("1.10 is newer than 1.9", v("1.9")! < v("1.10")!)
    check("1.2 is newer than 1.1", v("1.1")! < v("1.2")!)
    check("2.0 is newer than 1.99", v("1.99")! < v("2.0")!)
    check("equal versions are not newer", !(v("1.2")! < v("1.2")!))
    check("missing components count as zero", v("1.2") == v("1.2.0"))
    check("1.2.1 is newer than 1.2", v("1.2")! < v("1.2.1")!)
    check("a pre-release suffix is ignored", v("1.3-beta.1") == v("1.3"))
    check("nonsense is rejected", v("banana") == nil && v("") == nil && v("1.x") == nil)
    check("the app's own version parses", v(AppInfo.version) != nil, AppInfo.version)

    // Barcodes actually generate.
    check("code128 renders", ImageFX.barcode(.code128, value: "5901234123457", color: .black, w: 200, h: 60) != nil)
    check("qr renders", ImageFX.barcode(.qr, value: "https://example.com", color: .red, w: 120, h: 120) != nil)

    // SVG import path.
    let svg = Data("""
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64">
      <circle cx="32" cy="32" r="28" fill="#3477eb"/><rect x="8" y="28" width="48" height="8" fill="#12ab4f"/>
    </svg>
    """.utf8)
    if let image = ImageFX.nsImage(from: Asset(kind: .svg, filename: "t.svg", data: svg)) {
        let params = ImageFX.Params(assetID: "a", pixelW: 64, pixelH: 64, tint: .red, dither: .none,
                                    brightness: 0, contrast: 1, knockoutWhite: false,
                                    knockoutThreshold: 0.88, flipH: false, flipV: false, quantize: true)
        let out = ImageFX.process(image, params)
        check("svg rasterises and recolours", out?.width == 64)
    } else {
        check("svg loads", false)
    }

    print(failures == 0 ? "\nALL CHECKS PASSED" : "\n\(failures) CHECK(S) FAILED")
    exit(failures == 0 ? 0 : 1)
}

MainActor.assumeIsolated { run() }
