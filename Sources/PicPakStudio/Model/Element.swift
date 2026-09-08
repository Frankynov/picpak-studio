import Foundation
import CoreGraphics

enum ElementType: String, Codable, CaseIterable, Sendable {
    case rect, ellipse, triangle, line, star, text, symbol, svg, image, barcode

    var label: String {
        switch self {
        case .rect: "Rectangle"
        case .ellipse: "Ellipse"
        case .triangle: "Triangle"
        case .line: "Line"
        case .star: "Star"
        case .text: "Text"
        case .symbol: "Symbol"
        case .svg: "SVG"
        case .image: "Image"
        case .barcode: "Barcode"
        }
    }

    var symbol: String {
        switch self {
        case .rect: "rectangle"
        case .ellipse: "circle"
        case .triangle: "triangle"
        case .line: "line.diagonal"
        case .star: "star"
        case .text: "textformat"
        case .symbol: "star.circle"
        case .svg: "bezier.path"
        case .image: "photo"
        case .barcode: "barcode"
        }
    }

    var usesFill: Bool {
        switch self {
        case .rect, .ellipse, .triangle, .star: true
        default: false
        }
    }
}

/// One item on the board. Deliberately a flat struct with an explicit `type`
/// discriminator: the JSON stays readable and old documents keep loading as
/// fields are added, because decoding falls back to defaults for missing keys.
struct Element: Identifiable, Codable, Equatable, Sendable {
    var id: UUID = UUID()
    var type: ElementType = .rect
    var name: String = ""

    // Frame, in canvas points, origin top-left.
    var x: Double = 0
    var y: Double = 0
    var w: Double = 100
    var h: Double = 100
    var rotation: Double = 0        // degrees, about the frame centre

    var hidden: Bool = false
    var locked: Bool = false

    // Paint
    var fill: PPColor? = .red
    var stroke: PPColor? = nil
    var strokeWidth: Double = 0
    var cornerRadius: Double = 0
    var points: Int = 5             // star points

    // Text
    var text: String = "Text"
    var fontSize: Double = 32
    var fontWeight: PPFontWeight = .bold
    var fontDesign: PPFontDesign = .standard
    var fontFamily: String? = nil   // nil = system font
    var align: PPAlign = .center
    var vAlign: PPVAlign = .middle
    var lineSpacing: Double = 0
    var tracking: Double = 0
    var strikethrough: Bool = false
    var strikeColor: PPColor? = nil
    var autoFit: Bool = false       // shrink font until the text fits the box
    var uppercase: Bool = false

    // Symbol
    var symbolName: String = "star.fill"

    // Assets (svg / image)
    var assetID: String? = nil
    /// nil means "keep the artwork's own colours"; a value re-paints it as a flat silhouette.
    var tint: PPColor? = nil
    var dither: DitherMode = .floyd
    var brightness: Double = 0      // -1...1, applied before quantising
    var contrast: Double = 1        // 0...3
    var knockoutWhite: Bool = false // drop near-white pixels to transparent
    var knockoutThreshold: Double = 0.88
    var flipH: Bool = false
    var flipV: Bool = false

    // Barcode
    var barcodeKind: BarcodeKind = .code128
    var barcodeValue: String = "5901234123457"

    var frame: CGRect {
        get { CGRect(x: x, y: y, width: w, height: h) }
        set { x = newValue.minX; y = newValue.minY; w = newValue.width; h = newValue.height }
    }
    var center: CGPoint { CGPoint(x: x + w / 2, y: y + h / 2) }

    var displayName: String {
        if !name.isEmpty { return name }
        switch type {
        case .text: return text.isEmpty ? "Text" : String(text.prefix(24)).replacingOccurrences(of: "\n", with: " ")
        case .symbol: return symbolName
        case .barcode: return "Barcode"
        default: return type.label
        }
    }

    static func make(_ type: ElementType, at rect: CGRect) -> Element {
        var e = Element()
        e.type = type
        e.frame = rect
        switch type {
        case .rect, .ellipse, .triangle, .star:
            e.fill = .red
        case .line:
            e.fill = nil; e.stroke = .black; e.strokeWidth = 3
        case .text:
            e.fill = .black; e.text = "PRICE"; e.fontWeight = .black; e.autoFit = true
        case .symbol:
            e.fill = .black; e.symbolName = "leaf.fill"
        case .svg, .image:
            e.fill = nil
        case .barcode:
            e.fill = .black
        }
        return e
    }

    // MARK: - Codable with defaults for forward/backward compatibility

    private enum CodingKeys: String, CodingKey {
        case id, type, name, x, y, w, h, rotation, hidden, locked
        case fill, stroke, strokeWidth, cornerRadius, points
        case text, fontSize, fontWeight, fontDesign, fontFamily, align, vAlign
        case lineSpacing, tracking, strikethrough, strikeColor, autoFit, uppercase
        case symbolName, assetID, tint, dither, brightness, contrast
        case knockoutWhite, knockoutThreshold, flipH, flipV
        case barcodeKind, barcodeValue
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Element()
        func v<T: Decodable>(_ k: CodingKeys, _ fallback: T) -> T {
            (try? c.decodeIfPresent(T.self, forKey: k)) .flatMap { $0 } ?? fallback
        }
        // Optional-valued properties need explicit handling: a missing key keeps the
        // default, an explicit null means "no paint".
        func opt<T: Decodable>(_ k: CodingKeys, _ fallback: T?) -> T? {
            guard c.contains(k) else { return fallback }
            return try? c.decodeIfPresent(T.self, forKey: k)
        }

        id = v(.id, d.id)
        type = v(.type, d.type)
        name = v(.name, d.name)
        x = v(.x, d.x); y = v(.y, d.y); w = v(.w, d.w); h = v(.h, d.h)
        rotation = v(.rotation, d.rotation)
        hidden = v(.hidden, d.hidden); locked = v(.locked, d.locked)
        fill = opt(.fill, d.fill)
        stroke = opt(.stroke, d.stroke)
        strokeWidth = v(.strokeWidth, d.strokeWidth)
        cornerRadius = v(.cornerRadius, d.cornerRadius)
        points = v(.points, d.points)
        text = v(.text, d.text)
        fontSize = v(.fontSize, d.fontSize)
        fontWeight = v(.fontWeight, d.fontWeight)
        fontDesign = v(.fontDesign, d.fontDesign)
        fontFamily = opt(.fontFamily, d.fontFamily)
        align = v(.align, d.align)
        vAlign = v(.vAlign, d.vAlign)
        lineSpacing = v(.lineSpacing, d.lineSpacing)
        tracking = v(.tracking, d.tracking)
        strikethrough = v(.strikethrough, d.strikethrough)
        strikeColor = opt(.strikeColor, d.strikeColor)
        autoFit = v(.autoFit, d.autoFit)
        uppercase = v(.uppercase, d.uppercase)
        symbolName = v(.symbolName, d.symbolName)
        assetID = opt(.assetID, d.assetID)
        tint = opt(.tint, d.tint)
        dither = v(.dither, d.dither)
        brightness = v(.brightness, d.brightness)
        contrast = v(.contrast, d.contrast)
        knockoutWhite = v(.knockoutWhite, d.knockoutWhite)
        knockoutThreshold = v(.knockoutThreshold, d.knockoutThreshold)
        flipH = v(.flipH, d.flipH)
        flipV = v(.flipV, d.flipV)
        barcodeKind = v(.barcodeKind, d.barcodeKind)
        barcodeValue = v(.barcodeValue, d.barcodeValue)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(type, forKey: .type)
        if !name.isEmpty { try c.encode(name, forKey: .name) }
        try c.encode(x, forKey: .x); try c.encode(y, forKey: .y)
        try c.encode(w, forKey: .w); try c.encode(h, forKey: .h)
        if rotation != 0 { try c.encode(rotation, forKey: .rotation) }
        if hidden { try c.encode(hidden, forKey: .hidden) }
        if locked { try c.encode(locked, forKey: .locked) }
        try c.encode(fill, forKey: .fill)
        try c.encode(stroke, forKey: .stroke)
        try c.encode(strokeWidth, forKey: .strokeWidth)
        try c.encode(cornerRadius, forKey: .cornerRadius)

        switch type {
        case .star:
            try c.encode(points, forKey: .points)
        case .text:
            try c.encode(text, forKey: .text)
            try c.encode(fontSize, forKey: .fontSize)
            try c.encode(fontWeight, forKey: .fontWeight)
            try c.encode(fontDesign, forKey: .fontDesign)
            try c.encodeIfPresent(fontFamily, forKey: .fontFamily)
            try c.encode(align, forKey: .align)
            try c.encode(vAlign, forKey: .vAlign)
            try c.encode(lineSpacing, forKey: .lineSpacing)
            try c.encode(tracking, forKey: .tracking)
            try c.encode(strikethrough, forKey: .strikethrough)
            try c.encode(strikeColor, forKey: .strikeColor)
            try c.encode(autoFit, forKey: .autoFit)
            try c.encode(uppercase, forKey: .uppercase)
        case .symbol:
            try c.encode(symbolName, forKey: .symbolName)
        case .svg, .image:
            try c.encodeIfPresent(assetID, forKey: .assetID)
            try c.encode(tint, forKey: .tint)
            try c.encode(flipH, forKey: .flipH)
            try c.encode(flipV, forKey: .flipV)
            if type == .image {
                try c.encode(dither, forKey: .dither)
                try c.encode(brightness, forKey: .brightness)
                try c.encode(contrast, forKey: .contrast)
                try c.encode(knockoutWhite, forKey: .knockoutWhite)
                try c.encode(knockoutThreshold, forKey: .knockoutThreshold)
            }
        case .barcode:
            try c.encode(barcodeKind, forKey: .barcodeKind)
            try c.encode(barcodeValue, forKey: .barcodeValue)
        case .rect, .ellipse, .triangle, .line:
            break
        }
    }
}
