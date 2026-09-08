import SwiftUI
import AppKit

/// The only colours a PicPak panel can physically render.
/// Nothing in a document may reference a colour outside this set.
enum PPColor: String, Codable, CaseIterable, Identifiable, Sendable {
    case black, white, red, yellow

    var id: String { rawValue }

    var rgb: (r: Double, g: Double, b: Double) {
        switch self {
        case .black:  (0, 0, 0)
        case .white:  (1, 1, 1)
        case .red:    (1, 0, 0)
        case .yellow: (1, 1, 0)
        }
    }

    var color: Color { Color(.sRGB, red: rgb.r, green: rgb.g, blue: rgb.b, opacity: 1) }
    var nsColor: NSColor { NSColor(srgbRed: rgb.r, green: rgb.g, blue: rgb.b, alpha: 1) }

    var hex: String {
        switch self {
        case .black: "#000000"
        case .white: "#FFFFFF"
        case .red: "#FF0000"
        case .yellow: "#FFFF00"
        }
    }

    var label: String { rawValue.capitalized }

    /// A colour that reads against this one, for swatch borders and overlaid glyphs.
    var contrasting: Color { self == .black || self == .red ? .white : .black }

    static let quantized: [(PPColor, SIMD3<Double>)] = PPColor.allCases.map {
        ($0, SIMD3($0.rgb.r, $0.rgb.g, $0.rgb.b))
    }
}

/// Optional paint: `nil` means "leave this transparent".
typealias PPPaint = PPColor?

enum PPFontWeight: String, Codable, CaseIterable, Sendable {
    case regular, medium, semibold, bold, heavy, black

    var swiftUI: Font.Weight {
        switch self {
        case .regular: .regular
        case .medium: .medium
        case .semibold: .semibold
        case .bold: .bold
        case .heavy: .heavy
        case .black: .black
        }
    }
    var appKit: NSFont.Weight {
        switch self {
        case .regular: .regular
        case .medium: .medium
        case .semibold: .semibold
        case .bold: .bold
        case .heavy: .heavy
        case .black: .black
        }
    }
    var label: String { rawValue.capitalized }
}

enum PPFontDesign: String, Codable, CaseIterable, Sendable {
    case standard, rounded, serif, mono

    var swiftUI: Font.Design {
        switch self {
        case .standard: .default
        case .rounded: .rounded
        case .serif: .serif
        case .mono: .monospaced
        }
    }
    var appKitDesign: NSFontDescriptor.SystemDesign {
        switch self {
        case .standard: .default
        case .rounded: .rounded
        case .serif: .serif
        case .mono: .monospaced
        }
    }
    var label: String {
        switch self {
        case .standard: "System"
        case .rounded: "Rounded"
        case .serif: "Serif"
        case .mono: "Mono"
        }
    }
}

enum PPAlign: String, Codable, CaseIterable, Sendable {
    case leading, center, trailing
    var swiftUI: TextAlignment {
        switch self {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }
    var frameAlignment: Alignment {
        switch self {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }
    var symbol: String {
        switch self {
        case .leading: "text.alignleft"
        case .center: "text.aligncenter"
        case .trailing: "text.alignright"
        }
    }
}

enum PPVAlign: String, Codable, CaseIterable, Sendable {
    case top, middle, bottom
    var frameAlignment: Alignment {
        switch self {
        case .top: .top
        case .middle: .center
        case .bottom: .bottom
        }
    }
    var symbol: String {
        switch self {
        case .top: "arrow.up.to.line"
        case .middle: "arrow.up.and.down"
        case .bottom: "arrow.down.to.line"
        }
    }
}

/// How a full-colour bitmap is reduced to the 4-colour gamut.
enum DitherMode: String, Codable, CaseIterable, Sendable {
    case none, floyd, ordered
    var label: String {
        switch self {
        case .none: "Flat"
        case .floyd: "Diffuse"
        case .ordered: "Halftone"
        }
    }
}

enum BarcodeKind: String, Codable, CaseIterable, Sendable {
    case code128, qr
    var label: String { self == .code128 ? "Code 128" : "QR" }
}
