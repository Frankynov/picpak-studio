import Foundation
import CoreGraphics

enum Template: String, CaseIterable, Identifiable {
    case blank, priceTag, saleSplit, notice, qrCard

    var id: String { rawValue }

    var title: String {
        switch self {
        case .blank: "Blank"
        case .priceTag: "Price Tag"
        case .saleSplit: "Split Sale"
        case .notice: "Notice"
        case .qrCard: "QR Card"
        }
    }

    var subtitle: String {
        switch self {
        case .blank: "An empty 400 × 300 panel"
        case .priceTag: "Product, price, origin, barcode"
        case .saleSplit: "Red promo panel beside a yellow price"
        case .notice: "A headline and a line of detail"
        case .qrCard: "Scannable code with a caption"
        }
    }

    var symbol: String {
        switch self {
        case .blank: "rectangle"
        case .priceTag: "tag.fill"
        case .saleSplit: "rectangle.split.2x1.fill"
        case .notice: "exclamationmark.bubble.fill"
        case .qrCard: "qrcode"
        }
    }

    func build() -> PicPakDocument {
        var doc = PicPakDocument()
        doc.meta.title = title
        doc.canvas = CanvasSpec(w: 400, h: 300, background: .white)
        doc.elements = elements()
        return doc
    }

    private func elements() -> [Element] {
        switch self {
        case .blank:
            return []

        case .priceTag:
            return [
                bg(.yellow),
                text("Organic Bananas", at: CGRect(x: 12, y: 10, width: 376, height: 40),
                     size: 34, weight: .heavy, colour: .black, align: .leading),
                text("2 KG · Spain", at: CGRect(x: 12, y: 52, width: 376, height: 22),
                     size: 18, weight: .semibold, colour: .black, align: .leading),
                strike("WAS 2.30", at: CGRect(x: 200, y: 88, width: 188, height: 36), size: 26),
                text("1.90", at: CGRect(x: 150, y: 116, width: 238, height: 110),
                     size: 104, weight: .black, colour: .black, align: .trailing),
                text("0.95 / kg", at: CGRect(x: 200, y: 226, width: 188, height: 26),
                     size: 22, weight: .semibold, colour: .black, align: .trailing),
                {
                    var e = Element.make(.symbol, at: CGRect(x: 18, y: 120, width: 96, height: 96))
                    e.symbolName = "leaf.fill"; e.fill = .red; e.name = "Organic mark"
                    return e
                }(),
                text("ORGANIC", at: CGRect(x: 8, y: 220, width: 116, height: 22),
                     size: 18, weight: .black, colour: .red, align: .center),
                barcode("5901234123457", at: CGRect(x: 150, y: 258, width: 238, height: 34))
            ]

        case .saleSplit:
            return [
                bg(.yellow),
                {
                    var e = Element.make(.rect, at: CGRect(x: 0, y: 0, width: 186, height: 300))
                    e.fill = .red; e.name = "Promo panel"
                    return e
                }(),
                text("BIG", at: CGRect(x: 12, y: 24, width: 104, height: 72),
                     size: 66, weight: .black, colour: .yellow, align: .leading),
                text("15%", at: CGRect(x: 118, y: 30, width: 62, height: 54),
                     size: 44, weight: .black, colour: .white, align: .trailing),
                text("SALE", at: CGRect(x: 12, y: 100, width: 166, height: 78),
                     size: 70, weight: .black, colour: .yellow, align: .leading),
                {
                    var e = Element.make(.symbol, at: CGRect(x: 30, y: 190, width: 120, height: 96))
                    e.symbolName = "tag.fill"; e.fill = .yellow; e.rotation = -12; e.name = "Tag"
                    return e
                }(),
                text("Organic Bananas 2 KG", at: CGRect(x: 194, y: 12, width: 196, height: 66),
                     size: 30, weight: .heavy, colour: .black, align: .leading),
                strike("WAS 2.30", at: CGRect(x: 194, y: 88, width: 196, height: 34), size: 24),
                text("1.90", at: CGRect(x: 194, y: 118, width: 196, height: 96),
                     size: 92, weight: .black, colour: .black, align: .trailing),
                text("0.95 / kg", at: CGRect(x: 194, y: 214, width: 196, height: 24),
                     size: 20, weight: .semibold, colour: .black, align: .trailing),
                text("Spain", at: CGRect(x: 194, y: 244, width: 100, height: 22),
                     size: 20, weight: .bold, colour: .black, align: .leading),
                barcode("5901234123457", at: CGRect(x: 262, y: 258, width: 128, height: 32))
            ]

        case .notice:
            return [
                bg(.white),
                {
                    var e = Element.make(.rect, at: CGRect(x: 0, y: 0, width: 400, height: 74))
                    e.fill = .red; e.name = "Header"
                    return e
                }(),
                text("CLOSED", at: CGRect(x: 16, y: 12, width: 368, height: 50),
                     size: 46, weight: .black, colour: .white, align: .leading),
                text("Back at 14:00", at: CGRect(x: 16, y: 96, width: 368, height: 70),
                     size: 56, weight: .black, colour: .black, align: .leading),
                text("Deliveries to the side door, please.",
                     at: CGRect(x: 16, y: 180, width: 368, height: 60),
                     size: 26, weight: .medium, colour: .black, align: .leading),
                {
                    var e = Element.make(.rect, at: CGRect(x: 0, y: 288, width: 400, height: 12))
                    e.fill = .yellow; e.name = "Footer rule"
                    return e
                }()
            ]

        case .qrCard:
            return [
                bg(.white),
                {
                    var e = Element.make(.barcode, at: CGRect(x: 22, y: 40, width: 220, height: 220))
                    e.barcodeKind = .qr; e.barcodeValue = "https://example.com"; e.fill = .black
                    return e
                }(),
                text("Scan me", at: CGRect(x: 254, y: 60, width: 130, height: 50),
                     size: 40, weight: .black, colour: .red, align: .leading),
                text("Menu, allergens and today's specials.",
                     at: CGRect(x: 254, y: 118, width: 130, height: 120),
                     size: 20, weight: .medium, colour: .black, align: .leading)
            ]
        }
    }

    // MARK: - Builders

    private func bg(_ colour: PPColor) -> Element {
        var e = Element.make(.rect, at: CGRect(x: 0, y: 0, width: 400, height: 300))
        e.fill = colour
        e.name = "Background"
        return e
    }

    private func text(_ string: String, at rect: CGRect, size: Double, weight: PPFontWeight,
                      colour: PPColor, align: PPAlign) -> Element {
        var e = Element.make(.text, at: rect)
        e.text = string
        e.fontSize = size
        e.fontWeight = weight
        e.fill = colour
        e.align = align
        e.vAlign = .middle
        e.autoFit = true
        return e
    }

    private func strike(_ string: String, at rect: CGRect, size: Double) -> Element {
        var e = text(string, at: rect, size: size, weight: .bold, colour: .black, align: .trailing)
        e.strikethrough = true
        e.strikeColor = .red
        return e
    }

    private func barcode(_ value: String, at rect: CGRect) -> Element {
        var e = Element.make(.barcode, at: rect)
        e.barcodeValue = value
        e.fill = .black
        return e
    }
}
