import AppKit
import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins

/// Rasterising, recolouring and 4-colour reduction.
///
/// Imported artwork is always rasterised at *panel resolution* (1 canvas point =
/// 1 device pixel) and reduced to the gamut there, so what the editor shows is
/// literally the pixels the panel will paint.
enum ImageFX {

    // MARK: - Palette reduction

    struct Params: Hashable {
        var assetID: String
        var pixelW: Int
        var pixelH: Int
        var tint: PPColor?
        var dither: DitherMode
        var brightness: Double
        var contrast: Double
        var knockoutWhite: Bool
        var knockoutThreshold: Double
        var flipH: Bool
        var flipV: Bool
        var quantize: Bool
    }

    private static let paletteRGB: [(c: PPColor, r: Double, g: Double, b: Double)] =
        PPColor.allCases.map { ($0, $0.rgb.r * 255, $0.rgb.g * 255, $0.rgb.b * 255) }

    /// Weighted so hue errors cost roughly what the eye thinks they cost.
    @inline(__always)
    static func nearest(_ r: Double, _ g: Double, _ b: Double) -> (Double, Double, Double) {
        var bestIndex = 0
        var bestDistance = Double.greatestFiniteMagnitude
        for (i, p) in paletteRGB.enumerated() {
            let dr = r - p.r, dg = g - p.g, db = b - p.b
            let d = 0.30 * dr * dr + 0.59 * dg * dg + 0.11 * db * db
            if d < bestDistance { bestDistance = d; bestIndex = i }
        }
        let p = paletteRGB[bestIndex]
        return (p.r, p.g, p.b)
    }

    private static let bayer4: [Double] = [
         0,  8,  2, 10,
        12,  4, 14,  6,
         3, 11,  1,  9,
        15,  7, 13,  5
    ].map { Double($0) / 16.0 - 0.5 }

    // MARK: - Rasterisation

    static func nsImage(from asset: Asset) -> NSImage? { NSImage(data: asset.data) }

    /// Draw an NSImage (vector or bitmap) into an sRGB bitmap of exactly `w`x`h`.
    static func rasterize(_ image: NSImage, w: Int, h: Int, flipH: Bool, flipV: Bool) -> CGContext? {
        guard w > 0, h > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.interpolationQuality = .high
        ctx.saveGState()
        if flipH { ctx.translateBy(x: CGFloat(w), y: 0); ctx.scaleBy(x: -1, y: 1) }
        if flipV { ctx.translateBy(x: 0, y: CGFloat(h)); ctx.scaleBy(x: 1, y: -1) }
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        image.draw(in: NSRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h)),
                   from: .zero, operation: .sourceOver, fraction: 1,
                   respectFlipped: false, hints: [.interpolation: NSImageInterpolation.high.rawValue])
        NSGraphicsContext.current = previous
        ctx.restoreGState()
        return ctx
    }

    // MARK: - Pixel pipeline

    static func process(_ image: NSImage, _ p: Params) -> CGImage? {
        guard let ctx = rasterize(image, w: p.pixelW, h: p.pixelH, flipH: p.flipH, flipV: p.flipV),
              let data = ctx.data else { return nil }

        let w = p.pixelW, h = p.pixelH
        let bytes = data.bindMemory(to: UInt8.self, capacity: w * h * 4)

        // Un-premultiply into working floats.
        var buf = [Double](repeating: 0, count: w * h * 4)
        for i in 0..<(w * h) {
            let a = Double(bytes[i * 4 + 3])
            let scale = a > 0 ? 255.0 / a : 0
            buf[i * 4 + 0] = Double(bytes[i * 4 + 0]) * scale
            buf[i * 4 + 1] = Double(bytes[i * 4 + 1]) * scale
            buf[i * 4 + 2] = Double(bytes[i * 4 + 2]) * scale
            buf[i * 4 + 3] = a
        }

        if let tint = p.tint {
            // Flat silhouette: keep the shape, throw away the colours.
            let (tr, tg, tb) = (tint.rgb.r * 255, tint.rgb.g * 255, tint.rgb.b * 255)
            for i in 0..<(w * h) {
                buf[i * 4 + 0] = tr; buf[i * 4 + 1] = tg; buf[i * 4 + 2] = tb
            }
        } else {
            if p.brightness != 0 || p.contrast != 1 {
                let b = p.brightness * 255, k = p.contrast
                for i in 0..<(w * h * 4) where i % 4 != 3 {
                    buf[i] = min(255, max(0, (buf[i] - 128) * k + 128 + b))
                }
            }
            if p.knockoutWhite {
                let cut = p.knockoutThreshold * 255
                for i in 0..<(w * h) {
                    let r = buf[i * 4], g = buf[i * 4 + 1], b = buf[i * 4 + 2]
                    if r >= cut && g >= cut && b >= cut { buf[i * 4 + 3] = 0 }
                }
            }
            if p.quantize { reduce(&buf, w: w, h: h, mode: p.dither) }
        }

        // Re-premultiply.
        for i in 0..<(w * h) {
            let a = buf[i * 4 + 3]
            let scale = a / 255.0
            bytes[i * 4 + 0] = UInt8(min(255, max(0, buf[i * 4 + 0] * scale)))
            bytes[i * 4 + 1] = UInt8(min(255, max(0, buf[i * 4 + 1] * scale)))
            bytes[i * 4 + 2] = UInt8(min(255, max(0, buf[i * 4 + 2] * scale)))
            bytes[i * 4 + 3] = UInt8(min(255, max(0, a)))
        }
        return ctx.makeImage()
    }

    /// In-place reduction of an un-premultiplied RGBA float buffer to the 4 panel colours.
    static func reduce(_ buf: inout [Double], w: Int, h: Int, mode: DitherMode) {
        switch mode {
        case .none:
            for i in 0..<(w * h) {
                let (r, g, b) = nearest(buf[i * 4], buf[i * 4 + 1], buf[i * 4 + 2])
                buf[i * 4] = r; buf[i * 4 + 1] = g; buf[i * 4 + 2] = b
            }
        case .ordered:
            for y in 0..<h {
                for x in 0..<w {
                    let i = (y * w + x) * 4
                    let bias = bayer4[(y % 4) * 4 + (x % 4)] * 110
                    let (r, g, b) = nearest(buf[i] + bias, buf[i + 1] + bias, buf[i + 2] + bias)
                    buf[i] = r; buf[i + 1] = g; buf[i + 2] = b
                }
            }
        case .floyd:
            for y in 0..<h {
                for x in 0..<w {
                    let i = (y * w + x) * 4
                    let old = (buf[i], buf[i + 1], buf[i + 2])
                    let new = nearest(old.0, old.1, old.2)
                    buf[i] = new.0; buf[i + 1] = new.1; buf[i + 2] = new.2
                    let err = (old.0 - new.0, old.1 - new.1, old.2 - new.2)
                    @inline(__always) func spread(_ dx: Int, _ dy: Int, _ f: Double) {
                        let nx = x + dx, ny = y + dy
                        guard nx >= 0, nx < w, ny >= 0, ny < h else { return }
                        let j = (ny * w + nx) * 4
                        buf[j] += err.0 * f
                        buf[j + 1] += err.1 * f
                        buf[j + 2] += err.2 * f
                    }
                    spread(1, 0, 7.0 / 16); spread(-1, 1, 3.0 / 16)
                    spread(0, 1, 5.0 / 16); spread(1, 1, 1.0 / 16)
                }
            }
        }
    }

    /// Reduce a finished RGBA8 buffer (as produced by ImageRenderer) in place.
    /// Everything is composited over the canvas background first, so there is no alpha left.
    static func reduceBitmap(_ bytes: UnsafeMutablePointer<UInt8>, w: Int, h: Int, mode: DitherMode) {
        var buf = [Double](repeating: 0, count: w * h * 4)
        for i in 0..<(w * h * 4) { buf[i] = Double(bytes[i]) }
        reduce(&buf, w: w, h: h, mode: mode)
        for i in 0..<(w * h) {
            bytes[i * 4] = UInt8(min(255, max(0, buf[i * 4])))
            bytes[i * 4 + 1] = UInt8(min(255, max(0, buf[i * 4 + 1])))
            bytes[i * 4 + 2] = UInt8(min(255, max(0, buf[i * 4 + 2])))
            bytes[i * 4 + 3] = 255
        }
    }

    // MARK: - Barcodes

    static func barcode(_ kind: BarcodeKind, value: String, color: PPColor, w: Int, h: Int) -> CGImage? {
        guard w > 0, h > 0 else { return nil }
        let ci = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])
        var output: CIImage?
        switch kind {
        case .code128:
            let f = CIFilter.code128BarcodeGenerator()
            f.message = Data(value.utf8)
            f.quietSpace = 2
            output = f.outputImage
        case .qr:
            let f = CIFilter.qrCodeGenerator()
            f.message = Data(value.utf8)
            f.correctionLevel = "M"
            output = f.outputImage
        }
        guard var image = output else { return nil }
        // The generators emit black-on-white; make white transparent and recolour the bars.
        let mask = CIFilter.maskToAlpha()
        mask.inputImage = image.applyingFilter("CIColorInvert")
        guard let alpha = mask.outputImage else { return nil }
        let flat = CIImage(color: CIColor(color: color.nsColor) ?? .black).cropped(to: alpha.extent)
        let blend = CIFilter.blendWithAlphaMask()
        blend.inputImage = flat
        blend.maskImage = alpha
        blend.backgroundImage = CIImage(color: .clear).cropped(to: alpha.extent)
        guard let tinted = blend.outputImage else { return nil }
        image = tinted

        let sx = CGFloat(w) / image.extent.width
        let sy = CGFloat(h) / image.extent.height
        let scaled = image.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
        return ci.createCGImage(scaled, from: CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h)))
    }

    // MARK: - SF Symbols

    static func symbol(_ name: String, weight: PPFontWeight, pointSize: Double) -> NSImage? {
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return nil }
        let config = NSImage.SymbolConfiguration(pointSize: max(pointSize, 1), weight: weight.appKit)
        return base.withSymbolConfiguration(config) ?? base
    }
}

/// Small bounded cache so dragging an image element stays smooth.
@MainActor
final class RenderCache {
    static let shared = RenderCache()
    private var store: [ImageFX.Params: CGImage] = [:]
    private var order: [ImageFX.Params] = []
    private let limit = 120

    func image(_ params: ImageFX.Params, build: () -> CGImage?) -> CGImage? {
        if let hit = store[params] { return hit }
        guard let made = build() else { return nil }
        store[params] = made
        order.append(params)
        if order.count > limit, let oldest = order.first {
            order.removeFirst()
            store.removeValue(forKey: oldest)
        }
        return made
    }

    private var keyed: [String: CGImage] = [:]
    private var keyedOrder: [String] = []

    func image(key: String, build: () -> CGImage?) -> CGImage? {
        if let hit = keyed[key] { return hit }
        guard let made = build() else { return nil }
        keyed[key] = made
        keyedOrder.append(key)
        if keyedOrder.count > limit { keyed.removeValue(forKey: keyedOrder.removeFirst()) }
        return made
    }

    func clear() {
        store.removeAll(); order.removeAll()
        keyed.removeAll(); keyedOrder.removeAll()
    }
}
