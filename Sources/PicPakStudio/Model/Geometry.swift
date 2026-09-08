import Foundation
import CoreGraphics

enum Handle: String, CaseIterable, Identifiable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left, rotate
    var id: String { rawValue }

    var unit: CGPoint {   // position within the frame, 0...1
        switch self {
        case .topLeft: CGPoint(x: 0, y: 0)
        case .top: CGPoint(x: 0.5, y: 0)
        case .topRight: CGPoint(x: 1, y: 0)
        case .right: CGPoint(x: 1, y: 0.5)
        case .bottomRight: CGPoint(x: 1, y: 1)
        case .bottom: CGPoint(x: 0.5, y: 1)
        case .bottomLeft: CGPoint(x: 0, y: 1)
        case .left: CGPoint(x: 0, y: 0.5)
        case .rotate: CGPoint(x: 0.5, y: 0)
        }
    }

    var movesX: Bool { [.topLeft, .left, .bottomLeft, .topRight, .right, .bottomRight].contains(self) }
    var movesY: Bool { [.topLeft, .top, .topRight, .bottomLeft, .bottom, .bottomRight].contains(self) }
    var anchorsLeft: Bool { [.topRight, .right, .bottomRight].contains(self) }
    var anchorsTop: Bool { [.bottomLeft, .bottom, .bottomRight].contains(self) }

    var cursorAngle: Double {   // degrees, for picking a resize cursor
        switch self {
        case .topLeft, .bottomRight: 45
        case .topRight, .bottomLeft: 135
        case .top, .bottom: 90
        case .left, .right: 0
        case .rotate: 0
        }
    }
}

enum Geometry {

    static func rotate(_ point: CGPoint, around center: CGPoint, degrees: Double) -> CGPoint {
        guard degrees != 0 else { return point }
        let r = degrees * .pi / 180
        let dx = point.x - center.x, dy = point.y - center.y
        return CGPoint(x: center.x + dx * cos(r) - dy * sin(r),
                       y: center.y + dx * sin(r) + dy * cos(r))
    }

    /// Hit test in the element's own (unrotated) space.
    static func contains(element: Element, point: CGPoint) -> Bool {
        let local = rotate(point, around: element.center, degrees: -element.rotation)
        if element.type == .line {
            let tolerance = max(element.strokeWidth, 6) / 2 + 2
            return distanceToSegment(local,
                                     a: CGPoint(x: element.x, y: element.y),
                                     b: CGPoint(x: element.x + element.w, y: element.y + element.h)) <= tolerance
        }
        return element.frame.insetBy(dx: -2, dy: -2).contains(local)
    }

    static func distanceToSegment(_ p: CGPoint, a: CGPoint, b: CGPoint) -> Double {
        let dx = b.x - a.x, dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        var t = ((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared
        t = min(max(t, 0), 1)
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }

    static func handlePoint(_ handle: Handle, in rect: CGRect, rotation: Double, offset: Double = 0) -> CGPoint {
        var p = CGPoint(x: rect.minX + rect.width * handle.unit.x,
                        y: rect.minY + rect.height * handle.unit.y)
        if handle == .rotate { p.y -= offset }
        return rotate(p, around: CGPoint(x: rect.midX, y: rect.midY), degrees: rotation)
    }

    /// Resize `rect` by dragging `handle` to `point` (both in unrotated canvas space).
    static func resize(_ rect: CGRect, handle: Handle, to point: CGPoint,
                       keepAspect: Bool, fromCenter: Bool, minSize: Double = 1) -> CGRect {
        var minX = rect.minX, minY = rect.minY, maxX = rect.maxX, maxY = rect.maxY
        let aspect = rect.height > 0 ? rect.width / rect.height : 1

        if handle.movesX {
            if handle.anchorsLeft { maxX = point.x } else { minX = point.x }
        }
        if handle.movesY {
            if handle.anchorsTop { maxY = point.y } else { minY = point.y }
        }

        var result = CGRect(x: min(minX, maxX), y: min(minY, maxY),
                            width: abs(maxX - minX), height: abs(maxY - minY))

        if keepAspect && handle.movesX && handle.movesY && aspect > 0 {
            let byWidth = result.width / aspect >= result.height
            let w = byWidth ? result.width : result.height * aspect
            let h = byWidth ? result.width / aspect : result.height
            var x = result.minX, y = result.minY
            if !handle.anchorsLeft { x = result.maxX - w }
            if !handle.anchorsTop { y = result.maxY - h }
            result = CGRect(x: x, y: y, width: w, height: h)
        }

        if fromCenter {
            let c = CGPoint(x: rect.midX, y: rect.midY)
            let halfW = max(abs(point.x - c.x), minSize / 2)
            let halfH = max(abs(point.y - c.y), minSize / 2)
            result = CGRect(x: c.x - halfW, y: c.y - halfH, width: halfW * 2, height: halfH * 2)
        }

        return CGRect(x: result.minX, y: result.minY,
                      width: max(result.width, minSize), height: max(result.height, minSize))
    }
}

/// A line the canvas draws while something snaps to it.
struct SnapGuide: Identifiable, Equatable {
    let id = UUID()
    var vertical: Bool
    var position: Double
    var from: Double
    var to: Double
}

enum Snapper {
    /// Screen points, converted to canvas pixels by the current zoom. At 4pt the magnet
    /// was only ~2 panel pixels wide at 200% — you had to hit the target almost exactly.
    static let threshold: Double = 7

    /// Snap the edge a resize handle is dragging onto nearby edges and centres.
    ///
    /// `snap(rect:)` only ever *translates*, which is right for a move and wrong for a
    /// resize — using it here slid the whole shape instead of pinning the edge under
    /// the cursor. This moves one edge and lets the size follow, so dragging a
    /// rectangle's right edge to the middle of the panel lands exactly on it.
    static func snapResize(rect: CGRect, handle: Handle, canvas: CGSize,
                           others: [Element], scale: Double,
                           minSize: Double = 1) -> (CGRect, [SnapGuide]) {
        let tolerance = threshold / max(scale, 0.01)
        var result = rect
        var guides: [SnapGuide] = []

        let cw = Double(canvas.width), ch = Double(canvas.height)
        var vTargets: [Double] = [0, cw / 2, cw]
        var hTargets: [Double] = [0, ch / 2, ch]
        for o in others where !o.hidden {
            vTargets += [Double(o.frame.minX), Double(o.frame.midX), Double(o.frame.maxX)]
            hTargets += [Double(o.frame.minY), Double(o.frame.midY), Double(o.frame.maxY)]
        }

        func nearest(_ value: Double, _ targets: [Double]) -> Double? {
            targets.min { abs($0 - value) < abs($1 - value) }
                .flatMap { abs($0 - value) <= tolerance ? $0 : nil }
        }

        if handle.movesX {
            // `anchorsLeft` means the left edge is pinned, so the right edge is the one moving.
            let movingRight = handle.anchorsLeft
            let edge = movingRight ? Double(result.maxX) : Double(result.minX)
            if let target = nearest(edge, vTargets) {
                if movingRight {
                    result.size.width = max(target - Double(result.minX), minSize)
                } else {
                    let right = Double(result.maxX)
                    result.origin.x = min(target, right - minSize)
                    result.size.width = right - Double(result.origin.x)
                }
                guides.append(SnapGuide(vertical: true, position: target, from: 0, to: ch))
            }
        }

        if handle.movesY {
            let movingBottom = handle.anchorsTop
            let edge = movingBottom ? Double(result.maxY) : Double(result.minY)
            if let target = nearest(edge, hTargets) {
                if movingBottom {
                    result.size.height = max(target - Double(result.minY), minSize)
                } else {
                    let bottom = Double(result.maxY)
                    result.origin.y = min(target, bottom - minSize)
                    result.size.height = bottom - Double(result.origin.y)
                }
                guides.append(SnapGuide(vertical: false, position: target, from: 0, to: cw))
            }
        }

        return (result, guides)
    }

    /// Nudge `rect` onto nearby edges/centres of the canvas and the other elements.
    static func snap(rect: CGRect, canvas: CGSize, others: [Element],
                     scale: Double) -> (CGRect, [SnapGuide]) {
        let tolerance = threshold / max(scale, 0.01)
        var guides: [SnapGuide] = []
        var result = rect

        let cw = Double(canvas.width), ch = Double(canvas.height)
        var vTargets: [(Double, ClosedRange<Double>)] = [(0, 0...ch), (cw / 2, 0...ch), (cw, 0...ch)]
        var hTargets: [(Double, ClosedRange<Double>)] = [(0, 0...cw), (ch / 2, 0...cw), (ch, 0...cw)]
        for o in others where !o.hidden {
            let f = o.frame
            let vSpan: ClosedRange<Double> = Double(min(f.minY, rect.minY))...Double(max(f.maxY, rect.maxY))
            let hSpan: ClosedRange<Double> = Double(min(f.minX, rect.minX))...Double(max(f.maxX, rect.maxX))
            vTargets += [(Double(f.minX), vSpan), (Double(f.midX), vSpan), (Double(f.maxX), vSpan)]
            hTargets += [(Double(f.minY), hSpan), (Double(f.midY), hSpan), (Double(f.maxY), hSpan)]
        }

        func best(_ candidates: [Double], _ targets: [(Double, ClosedRange<Double>)]) -> (delta: Double, guide: (Double, ClosedRange<Double>))? {
            var found: (Double, (Double, ClosedRange<Double>))?
            for target in targets {
                for candidate in candidates {
                    let delta = target.0 - candidate
                    if abs(delta) <= tolerance, abs(delta) < abs(found?.0 ?? .greatestFiniteMagnitude) {
                        found = (delta, target)
                    }
                }
            }
            return found.map { (delta: $0.0, guide: $0.1) }
        }

        if let hit = best([Double(result.minX), Double(result.midX), Double(result.maxX)], vTargets) {
            result.origin.x += hit.delta
            guides.append(SnapGuide(vertical: true, position: hit.guide.0,
                                    from: hit.guide.1.lowerBound, to: hit.guide.1.upperBound))
        }
        if let hit = best([Double(result.minY), Double(result.midY), Double(result.maxY)], hTargets) {
            result.origin.y += hit.delta
            guides.append(SnapGuide(vertical: false, position: hit.guide.0,
                                    from: hit.guide.1.lowerBound, to: hit.guide.1.upperBound))
        }
        return (result, guides)
    }
}
