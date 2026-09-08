import SwiftUI
import AppKit
import ImageIO
import UniformTypeIdentifiers
import Compression

@MainActor
enum Exporter {

    /// The exact 400x300 (or whatever the canvas is) bitmap the panel would paint.
    static func panelImage(_ doc: PicPakDocument, quantize: Bool = true,
                           dither: DitherMode = .none) -> CGImage? {
        let w = max(Int(doc.canvas.w.rounded()), 1)
        let h = max(Int(doc.canvas.h.rounded()), 1)

        let renderer = ImageRenderer(content: PosterView(doc: doc, scale: 1))
        renderer.scale = 1
        renderer.isOpaque = true
        guard let rendered = renderer.cgImage,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }

        let rect = CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h))
        ctx.setFillColor(doc.canvas.background.nsColor.cgColor)
        ctx.fill(rect)
        ctx.interpolationQuality = .none
        ctx.draw(rendered, in: rect)

        if quantize, let data = ctx.data {
            ImageFX.reduceBitmap(data.bindMemory(to: UInt8.self, capacity: w * h * 4),
                                 w: w, h: h, mode: dither)
        }
        return ctx.makeImage()
    }

    /// Integer nearest-neighbour blow-up, so a big PNG still shows the panel's real pixels.
    static func upscale(_ image: CGImage, factor: Int) -> CGImage? {
        guard factor > 1 else { return image }
        let w = image.width * factor, h = image.height * factor
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.interpolationQuality = .none
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h)))
        return ctx.makeImage()
    }

    struct ExportOptions {
        var scale: Int = 1
        var quantize: Bool = true
        var dither: DitherMode = .none
        var embedProject: Bool = true
    }

    static func pngData(_ doc: PicPakDocument, options: ExportOptions = ExportOptions()) throws -> Data {
        guard var image = panelImage(doc, quantize: options.quantize, dither: options.dither) else {
            throw DocumentError.unreadableImage
        }
        if options.scale > 1, let bigger = upscale(image, factor: options.scale) { image = bigger }

        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else {
            throw DocumentError.unreadableImage
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw DocumentError.unreadableImage }

        var data = out as Data
        if options.embedProject {
            let json = try doc.encoded()
            data = PNGChunks.embed(project: json, in: data)
        }
        return data
    }

    static func documentFromPNG(_ data: Data) throws -> PicPakDocument {
        guard let json = PNGChunks.extractProject(from: data) else {
            throw DocumentError.noEmbeddedProject
        }
        return try PicPakDocument.decode(json)
    }

    /// Base64 PNG for handing to a panel over HTTP.
    static func panelPNGBase64(_ doc: PicPakDocument, dither: DitherMode = .none) throws -> String {
        let data = try pngData(doc, options: ExportOptions(scale: 1, quantize: true,
                                                           dither: dither, embedProject: false))
        return data.base64EncodedString()
    }

    /// Counts of each palette colour — a quick sanity check that the art is on-gamut.
    static func histogram(_ image: CGImage) -> [PPColor: Int] {
        let w = image.width, h = image.height
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let raw = ctx.data else { return [:] }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h)))
        let bytes = raw.bindMemory(to: UInt8.self, capacity: w * h * 4)
        var counts: [PPColor: Int] = [:]
        for i in 0..<(w * h) {
            let r = Double(bytes[i * 4]), g = Double(bytes[i * 4 + 1]), b = Double(bytes[i * 4 + 2])
            let (nr, ng, nb) = ImageFX.nearest(r, g, b)
            let match = PPColor.allCases.first {
                $0.rgb.r * 255 == nr && $0.rgb.g * 255 == ng && $0.rgb.b * 255 == nb
            }
            if let match { counts[match, default: 0] += 1 }
        }
        return counts
    }
}

/// Reading and writing our own `tEXt` chunk, which is what makes an exported PNG
/// re-openable as a full project.
enum PNGChunks {
    static let keyword = "picpakStudio"
    private static let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

    static func embed(project json: Data, in png: Data) -> Data {
        let payload = compress(json).base64EncodedString()
        var chunkData = Data(keyword.utf8)
        chunkData.append(0)
        chunkData.append(contentsOf: Array(payload.utf8))
        let chunk = makeChunk(type: "tEXt", data: chunkData)

        // Splice in front of IEND.
        guard let iendRange = findIEND(png) else { return png + chunk }
        var out = png.subdata(in: 0..<iendRange.lowerBound)
        out.append(chunk)
        out.append(png.subdata(in: iendRange.lowerBound..<png.count))
        return out
    }

    static func extractProject(from png: Data) -> Data? {
        guard png.count > 8, Array(png.prefix(8)) == signature else { return nil }
        var offset = 8
        while offset + 8 <= png.count {
            let length = Int(readUInt32(png, offset))
            let typeStart = offset + 4
            guard typeStart + 4 <= png.count else { return nil }
            let type = String(decoding: png[typeStart..<(typeStart + 4)], as: UTF8.self)
            let dataStart = typeStart + 4
            guard dataStart + length <= png.count else { return nil }
            if type == "tEXt" {
                let body = png.subdata(in: dataStart..<(dataStart + length))
                if let split = body.firstIndex(of: 0) {
                    let key = String(decoding: body[body.startIndex..<split], as: UTF8.self)
                    if key == keyword {
                        let b64 = body[(split + 1)...]
                        guard let decoded = Data(base64Encoded: Data(b64)) else { return nil }
                        return decompress(decoded)
                    }
                }
            }
            if type == "IEND" { return nil }
            offset = dataStart + length + 4
        }
        return nil
    }

    // MARK: - Bits and pieces

    private static func findIEND(_ png: Data) -> Range<Int>? {
        guard png.count > 12 else { return nil }
        var offset = 8
        while offset + 8 <= png.count {
            let length = Int(readUInt32(png, offset))
            let typeStart = offset + 4
            guard typeStart + 4 <= png.count else { return nil }
            let type = String(decoding: png[typeStart..<(typeStart + 4)], as: UTF8.self)
            let next = typeStart + 4 + length + 4
            if type == "IEND" { return offset..<min(next, png.count) }
            offset = next
        }
        return nil
    }

    private static func readUInt32(_ d: Data, _ offset: Int) -> UInt32 {
        let bytes = [UInt8](d[offset..<(offset + 4)])
        return (UInt32(bytes[0]) << 24) | (UInt32(bytes[1]) << 16) | (UInt32(bytes[2]) << 8) | UInt32(bytes[3])
    }

    private static func makeChunk(type: String, data: Data) -> Data {
        var out = Data()
        var length = UInt32(data.count).bigEndian
        withUnsafeBytes(of: &length) { out.append(contentsOf: $0) }
        var body = Data(type.utf8)
        body.append(data)
        out.append(body)
        var crc = crc32(body).bigEndian
        withUnsafeBytes(of: &crc) { out.append(contentsOf: $0) }
        return out
    }

    private static let crcTable: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) == 1 ? 0xEDB88320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func crc32(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xFFFFFFFF
        for byte in data { c = crcTable[Int((c ^ UInt32(byte)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFFFFFF
    }

    // Raw DEFLATE keeps the payload small; base64 keeps it legal inside a tEXt chunk.
    static func compress(_ data: Data) -> Data {
        (try? (data as NSData).compressed(using: .zlib) as Data) ?? data
    }

    static func decompress(_ data: Data) -> Data? {
        if let out = try? (data as NSData).decompressed(using: .zlib) as Data { return out }
        // Older exports (or a future uncompressed path) store plain JSON.
        return data.first == UInt8(ascii: "{") ? data : nil
    }
}
