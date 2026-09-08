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

    // Pointer-anchored zoom: whatever sits under the cursor should stay under it.
    let anchored = CanvasZoom.anchoredOrigin(
        cursorInContent: CGPoint(x: 400, y: 300),
        contentBefore: CGSize(width: 800, height: 600),
        contentAfter: CGSize(width: 1600, height: 1200),
        visibleOrigin: CGPoint(x: 100, y: 50),
        viewport: CGSize(width: 500, height: 400))
    // The cursor sat 300pt into the viewport horizontally and 250pt down. After
    // doubling, that content point is at (800, 600), so the origin has to be
    // (800-300, 600-250) for it to stay under the cursor.
    check("zoom keeps the point under the cursor fixed",
          anchored == CGPoint(x: 500, y: 350), "\(anchored)")

    let clampedOrigin = CanvasZoom.anchoredOrigin(
        cursorInContent: .zero,
        contentBefore: CGSize(width: 800, height: 600),
        contentAfter: CGSize(width: 200, height: 150),
        visibleOrigin: CGPoint(x: 0, y: 0),
        viewport: CGSize(width: 500, height: 400))
    check("content smaller than the viewport pins to the origin",
          clampedOrigin == .zero, "\(clampedOrigin)")

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
