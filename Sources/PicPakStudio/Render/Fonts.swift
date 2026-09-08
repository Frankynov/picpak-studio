import SwiftUI
import AppKit

enum FontResolver {

    /// Resolve a family name + weight to a concrete PostScript font, or nil for the system face.
    nonisolated(unsafe) private static var psNameCache: [String: String?] = [:]

    static func postScriptName(family: String, weight: PPFontWeight) -> String? {
        if let hit = psNameCache["\(family)|\(weight.rawValue)"] { return hit }
        let resolved = resolvePostScriptName(family: family, weight: weight)
        psNameCache["\(family)|\(weight.rawValue)"] = resolved
        return resolved
    }

    private static func resolvePostScriptName(family: String, weight: PPFontWeight) -> String? {
        let manager = NSFontManager.shared
        let appKitWeight: Int = switch weight {
        case .regular: 5
        case .medium: 6
        case .semibold: 8
        case .bold: 9
        case .heavy: 10
        case .black: 11
        }
        if let font = manager.font(withFamily: family, traits: [], weight: appKitWeight, size: 12) {
            return font.fontName
        }
        return NSFont(name: family, size: 12)?.fontName
    }

    static func nsFont(_ e: Element, size: Double) -> NSFont {
        let pointSize = max(size, 1)
        if let family = e.fontFamily, !family.isEmpty,
           let name = postScriptName(family: family, weight: e.fontWeight),
           let font = NSFont(name: name, size: pointSize) {
            return font
        }
        let base = NSFont.systemFont(ofSize: pointSize, weight: e.fontWeight.appKit)
        if e.fontDesign != .standard,
           let descriptor = base.fontDescriptor.withDesign(e.fontDesign.appKitDesign),
           let designed = NSFont(descriptor: descriptor, size: pointSize) {
            return designed
        }
        return base
    }

    static func font(_ e: Element, size: Double) -> Font {
        let pointSize = max(size, 1)
        if let family = e.fontFamily, !family.isEmpty,
           let name = postScriptName(family: family, weight: e.fontWeight) {
            return .custom(name, fixedSize: pointSize)
        }
        return .system(size: pointSize, weight: e.fontWeight.swiftUI, design: e.fontDesign.swiftUI)
    }

    /// Querying NSFontManager costs ~14 ms, which is far too much to pay inside a
    /// view body. The set of installed families doesn't change while we run.
    static let availableFamilies: [String] = NSFontManager.shared.availableFontFamilies.sorted()
}

enum TextFit {

    static func displayString(_ e: Element) -> String {
        e.uppercase ? e.text.uppercased() : e.text
    }

    static func measure(_ e: Element, size: Double, width: Double) -> CGSize {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = switch e.align {
        case .leading: .left
        case .center: .center
        case .trailing: .right
        }
        paragraph.lineSpacing = e.lineSpacing
        let attributes: [NSAttributedString.Key: Any] = [
            .font: nsFontCached(e, size: size),
            .paragraphStyle: paragraph,
            .kern: e.tracking
        ]
        let string = NSAttributedString(string: displayString(e), attributes: attributes)
        let bounds = string.boundingRect(
            with: CGSize(width: max(width, 1), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading])
        return CGSize(width: ceil(bounds.width), height: ceil(bounds.height))
    }

    /// Largest point size (never above the element's own) whose text fits the box.
    static func fittedSize(_ e: Element) -> Double {
        guard e.autoFit, !e.text.isEmpty, e.w > 1, e.h > 1 else { return e.fontSize }
        let key = FitKey(text: displayString(e), w: e.w, h: e.h, size: e.fontSize,
                         weight: e.fontWeight, design: e.fontDesign, family: e.fontFamily,
                         tracking: e.tracking, lineSpacing: e.lineSpacing, align: e.align)
        if let hit = fitCache[key] { return hit }

        let slack = 1.0
        var low = 4.0, high = e.fontSize, best = 4.0
        if measure(e, size: high, width: e.w).height <= e.h - slack { best = high }
        else {
            for _ in 0..<12 {
                let mid = (low + high) / 2
                let size = measure(e, size: mid, width: e.w)
                if size.height <= e.h - slack && size.width <= e.w + 0.5 { best = mid; low = mid }
                else { high = mid }
                if high - low < 0.25 { break }
            }
        }
        cacheFit(key, best)
        return best
    }

    // MARK: - Caches (measurement runs inside view bodies)

    private struct FitKey: Hashable {
        var text: String; var w: Double; var h: Double; var size: Double
        var weight: PPFontWeight; var design: PPFontDesign; var family: String?
        var tracking: Double; var lineSpacing: Double; var align: PPAlign
    }
    nonisolated(unsafe) private static var fitCache: [FitKey: Double] = [:]
    nonisolated(unsafe) private static var fitOrder: [FitKey] = []

    private static func cacheFit(_ key: FitKey, _ value: Double) {
        fitCache[key] = value
        fitOrder.append(key)
        if fitOrder.count > 400 { fitCache.removeValue(forKey: fitOrder.removeFirst()) }
    }

    private struct FontKey: Hashable {
        var size: Double; var weight: PPFontWeight; var design: PPFontDesign; var family: String?
    }
    nonisolated(unsafe) private static var fontCache: [FontKey: NSFont] = [:]

    static func nsFontCached(_ e: Element, size: Double) -> NSFont {
        let key = FontKey(size: size, weight: e.fontWeight, design: e.fontDesign, family: e.fontFamily)
        if let hit = fontCache[key] { return hit }
        let font = FontResolver.nsFont(e, size: size)
        if fontCache.count > 200 { fontCache.removeAll() }
        fontCache[key] = font
        return font
    }
}
