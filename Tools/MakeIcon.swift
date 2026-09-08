// Draws the app icon: the four inks a PicPak panel can print, nothing else.
import AppKit

let sizes = [16, 32, 64, 128, 256, 512, 1024]
let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources")
try? FileManager.default.createDirectory(at: out.appendingPathComponent("AppIcon.iconset"),
                                         withIntermediateDirectories: true)
let iconset = out.appendingPathComponent("AppIcon.iconset")

func draw(size: Int) -> Data? {
    let s = CGFloat(size)
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
          let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                              bytesPerRow: size * 4, space: space,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }

    let inset = s * 0.055
    let body = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let radius = body.width * 0.225

    // Panel body: white, like unprinted e-paper.
    ctx.saveGState()
    let outline = CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil)
    ctx.addPath(outline)
    ctx.clip()
    ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
    ctx.fill(body)

    // The gamut, as a poster would use it: yellow ground, red mark, black type.
    let gap = max(s * 0.018, 1)
    let half = body.width / 2
    let cells: [(CGRect, CGColor)] = [
        (CGRect(x: body.minX, y: body.midY + gap / 2, width: half - gap / 2, height: half - gap / 2),
         CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)),
        (CGRect(x: body.midX + gap / 2, y: body.midY + gap / 2, width: half - gap / 2, height: half - gap / 2),
         CGColor(srgbRed: 1, green: 1, blue: 0, alpha: 1)),
        (CGRect(x: body.minX, y: body.minY, width: half - gap / 2, height: half - gap / 2),
         CGColor(srgbRed: 1, green: 1, blue: 0, alpha: 1)),
        (CGRect(x: body.midX + gap / 2, y: body.minY, width: half - gap / 2, height: half - gap / 2),
         CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
    ]
    for (rect, colour) in cells {
        ctx.setFillColor(colour)
        ctx.fill(rect)
    }
    ctx.restoreGState()

    // A hairline keeps the white quadrant from dissolving on a light desktop.
    ctx.addPath(outline)
    ctx.setStrokeColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.18))
    ctx.setLineWidth(max(s * 0.006, 0.5))
    ctx.strokePath()

    guard let image = ctx.makeImage() else { return nil }
    return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
}

for size in sizes {
    guard let data = draw(size: size) else { continue }
    try? data.write(to: iconset.appendingPathComponent("icon_\(size)x\(size).png"))
    if size <= 512, let retina = draw(size: size * 2) {
        try? retina.write(to: iconset.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
    }
}
print("iconset written to \(iconset.path)")
