import SwiftUI
import AppKit

/// Identity-compared handle on an embedded asset. Handing `ElementView` the whole
/// document meant every element re-rendered whenever anything in the document
/// changed; handing it just this makes SwiftUI skip the elements that didn't move.
/// Comparing ids rather than the asset's `Data` is both correct (ids are minted
/// fresh on every import) and vastly cheaper.
struct AssetRef: Equatable {
    let id: String
    let asset: Asset
    static func == (lhs: AssetRef, rhs: AssetRef) -> Bool { lhs.id == rhs.id }
}

/// The single source of truth for how a document looks.
/// The editor draws it at `scale`; the exporter draws the very same view at
/// scale 1, so what you see is what the panel gets.
struct PosterView: View {
    let doc: PicPakDocument
    var scale: Double = 1
    /// Elements being dragged right now, held by the editor rather than the document.
    /// Keeping a live drag out of the store means a mouse move re-renders the canvas
    /// only — not the layers panel and inspector that also observe the store.
    var overrides: [UUID: Element] = [:]

    var body: some View {
        ZStack(alignment: .topLeading) {
            doc.canvas.background.color
                .frame(width: doc.canvas.w * scale, height: doc.canvas.h * scale)
            ForEach(doc.elements) { stored in
                let element = overrides[stored.id] ?? stored
                if !element.hidden {
                    ElementView(element: element,
                                asset: PosterView.ref(for: element, in: doc),
                                scale: scale)
                        .equatable()
                }
            }
        }
        .frame(width: doc.canvas.w * scale, height: doc.canvas.h * scale, alignment: .topLeading)
        .clipped()
    }

    static func ref(for element: Element, in doc: PicPakDocument) -> AssetRef? {
        guard let id = element.assetID, let asset = doc.assets[id] else { return nil }
        return AssetRef(id: id, asset: asset)
    }
}

struct ElementView: View, Equatable {
    let element: Element
    let asset: AssetRef?
    let scale: Double

    nonisolated static func == (lhs: ElementView, rhs: ElementView) -> Bool {
        lhs.element == rhs.element && lhs.asset == rhs.asset && lhs.scale == rhs.scale
    }

    private var w: Double { element.w * scale }
    private var h: Double { element.h * scale }

    var body: some View {
        Perf.tick("element")
        return content
            .frame(width: max(w, 0.01), height: max(h, 0.01))
            .rotationEffect(.degrees(element.rotation))
            .offset(x: element.x * scale, y: element.y * scale)
    }

    @ViewBuilder
    private var content: some View {
        switch element.type {
        case .rect:      shape(RoundedRectangle(cornerRadius: element.cornerRadius * scale, style: .continuous))
        case .ellipse:   shape(Ellipse())
        case .triangle:  shape(TriangleShape())
        case .star:      shape(StarShape(points: element.points))
        case .polygon:   shape(PolygonShape(sides: element.points))
        case .arrow:     shape(ArrowShape(head: element.arrowHead, thickness: element.arrowThickness))
        case .line:      lineView
        case .text:      textView
        case .symbol:    symbolView
        case .svg, .image: artworkView
        case .barcode:   barcodeView
        }
    }

    // MARK: - Vector primitives

    @ViewBuilder
    private func shape<S: InsettableShape>(_ s: S) -> some View {
        ZStack {
            if let fill = element.fill { s.fill(fill.color) }
            if let stroke = element.stroke, element.strokeWidth > 0 {
                s.strokeBorder(stroke.color, lineWidth: element.strokeWidth * scale)
            }
        }
    }

    private var lineView: some View {
        Path { p in
            p.move(to: CGPoint(x: 0, y: 0))
            p.addLine(to: CGPoint(x: w, y: h))
        }
        .stroke((element.stroke ?? element.fill ?? .black).color,
                style: StrokeStyle(lineWidth: max(element.strokeWidth, 0.5) * scale, lineCap: .butt))
    }

    // MARK: - Text

    private var textView: some View {
        Text(TextFit.displayString(element))
            .font(FontResolver.font(element, size: TextFit.fittedSize(element) * scale))
            .tracking(element.tracking * scale)
            .lineSpacing(element.lineSpacing * scale)
            .multilineTextAlignment(element.align.swiftUI)
            .foregroundStyle((element.fill ?? .black).color)
            .strikethrough(element.strikethrough,
                           color: (element.strikeColor ?? element.fill ?? .black).color)
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: max(w, 0.01), alignment: element.align.frameAlignment)
            .frame(height: max(h, 0.01), alignment: element.vAlign.frameAlignment)
    }

    // MARK: - Symbols

    private var symbolView: some View {
        Group {
            if let image = ImageFX.symbol(element.symbolName, weight: element.fontWeight,
                                          pointSize: min(element.w, element.h)) {
                Image(nsImage: image)
                    .resizable()
                    .renderingMode(.template)
                    .aspectRatio(contentMode: .fit)
                    .foregroundStyle((element.fill ?? .black).color)
                    .scaleEffect(x: element.flipH ? -1 : 1, y: element.flipV ? -1 : 1)
            } else {
                MissingBadge(text: "?")
            }
        }
    }

    // MARK: - Imported artwork

    private var artworkView: some View {
        Group {
            if let cg = processedArtwork() {
                Image(decorative: cg, scale: 1, orientation: .up)
                    .resizable()
                    .interpolation(.none)
            } else {
                MissingBadge(text: element.type == .svg ? "SVG" : "IMG")
            }
        }
    }

    private func processedArtwork() -> CGImage? {
        guard let ref = asset else { return nil }
        let pw = max(Int(element.w.rounded()), 1)
        let ph = max(Int(element.h.rounded()), 1)
        guard pw <= 4000, ph <= 4000 else { return nil }
        let params = ImageFX.Params(
            assetID: ref.id, pixelW: pw, pixelH: ph, tint: element.tint,
            dither: element.type == .image ? element.dither : .none,
            brightness: element.brightness, contrast: element.contrast,
            knockoutWhite: element.knockoutWhite, knockoutThreshold: element.knockoutThreshold,
            flipH: element.flipH, flipV: element.flipV, quantize: true)
        return RenderCache.shared.image(params) {
            guard let image = ImageFX.nsImage(from: ref.asset) else { return nil }
            return ImageFX.process(image, params)
        }
    }

    // MARK: - Barcode

    private var barcodeView: some View {
        Group {
            if let cg = renderedBarcode() {
                Image(decorative: cg, scale: 1, orientation: .up)
                    .resizable()
                    .interpolation(.none)
            } else {
                MissingBadge(text: "BAR")
            }
        }
    }

    private func renderedBarcode() -> CGImage? {
        let pw = max(Int(element.w.rounded()), 1)
        let ph = max(Int(element.h.rounded()), 1)
        guard pw <= 2000, ph <= 2000 else { return nil }
        let colour = element.fill ?? .black
        let key = "bar|\(element.barcodeKind.rawValue)|\(element.barcodeValue)|\(colour.rawValue)|\(pw)x\(ph)"
        return RenderCache.shared.image(key: key) {
            ImageFX.barcode(element.barcodeKind, value: element.barcodeValue,
                            color: colour, w: pw, h: ph)
        }
    }
}

/// Shown in place of artwork whose asset is missing or too big to raster.
private struct MissingBadge: View {
    let text: String
    var body: some View {
        ZStack {
            Rectangle().strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                .foregroundStyle(.secondary)
            Text(text).font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Shapes

struct TriangleShape: Shape, InsettableShape {
    var inset: CGFloat = 0
    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: inset, dy: inset)
        var p = Path()
        p.move(to: CGPoint(x: r.midX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
        p.closeSubpath()
        return p
    }
    func inset(by amount: CGFloat) -> some InsettableShape {
        var copy = self; copy.inset += amount; return copy
    }
}

/// A regular n-gon, flat-topped at 6 sides so hexagons sit the way people draw them.
struct PolygonShape: Shape, InsettableShape {
    var sides: Int = 6
    var inset: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: inset, dy: inset)
        let n = max(3, sides)
        let centre = CGPoint(x: r.midX, y: r.midY)
        let radius = min(r.width, r.height) / 2
        // Point-up for odd counts, flat-top for even ones — both read as "upright".
        let start = n.isMultiple(of: 2) ? -CGFloat.pi / 2 + .pi / CGFloat(n) : -CGFloat.pi / 2
        var p = Path()
        for i in 0..<n {
            let angle = start + CGFloat(i) * 2 * .pi / CGFloat(n)
            let point = CGPoint(x: centre.x + cos(angle) * radius, y: centre.y + sin(angle) * radius)
            if i == 0 { p.move(to: point) } else { p.addLine(to: point) }
        }
        p.closeSubpath()
        return p
    }
    func inset(by amount: CGFloat) -> some InsettableShape {
        var copy = self; copy.inset += amount; return copy
    }
}

/// Points right inside its box; rotate the element to aim it anywhere else.
/// Filling the frame rather than joining two endpoints makes it behave like every
/// other shape — drag the handles and it scales predictably.
struct ArrowShape: Shape, InsettableShape {
    var head: Double = 0.42        // head length, as a fraction of the width
    var thickness: Double = 0.38   // shaft thickness, as a fraction of the height
    var inset: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: inset, dy: inset)
        guard r.width > 0, r.height > 0 else { return Path() }
        let headWidth = min(max(head, 0.05), 0.95) * r.width
        let shaft = min(max(thickness, 0.05), 1) * r.height
        let shaftTop = r.midY - shaft / 2
        let shaftBottom = r.midY + shaft / 2
        let neck = r.maxX - headWidth

        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: shaftTop))
        p.addLine(to: CGPoint(x: neck, y: shaftTop))
        p.addLine(to: CGPoint(x: neck, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.midY))
        p.addLine(to: CGPoint(x: neck, y: r.maxY))
        p.addLine(to: CGPoint(x: neck, y: shaftBottom))
        p.addLine(to: CGPoint(x: r.minX, y: shaftBottom))
        p.closeSubpath()
        return p
    }
    func inset(by amount: CGFloat) -> some InsettableShape {
        var copy = self; copy.inset += amount; return copy
    }
}

struct StarShape: Shape, InsettableShape {
    var points: Int = 5
    var innerRatio: CGFloat = 0.42
    var inset: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: inset, dy: inset)
        let n = max(3, points)
        let center = CGPoint(x: r.midX, y: r.midY)
        let outer = min(r.width, r.height) / 2
        let inner = outer * innerRatio
        var p = Path()
        for i in 0..<(n * 2) {
            let radius = i.isMultiple(of: 2) ? outer : inner
            let angle = -CGFloat.pi / 2 + CGFloat(i) * .pi / CGFloat(n)
            let pt = CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        p.closeSubpath()
        return p
    }
    func inset(by amount: CGFloat) -> some InsettableShape {
        var copy = self; copy.inset += amount; return copy
    }
}
