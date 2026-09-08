import SwiftUI
import AppKit

/// Trackpad pinch and mouse-wheel zoom for the artboard.
///
/// The two input devices want opposite things from a plain scroll: a trackpad's
/// two-finger scroll must keep panning, while a mouse wheel has nothing else to do and
/// should zoom. `hasPreciseScrollingDeltas` is what tells them apart — it is false only
/// for a traditional notched wheel. ⌘-scroll zooms on either device.
@MainActor
final class CanvasZoom: ObservableObject {
    static let range: ClosedRange<Double> = 0.25...12

    weak var scrollView: NSScrollView?
    /// Fallback when SwiftUI's scroll view can't be found: the probe still tells us
    /// where the artboard area is, so wheel zoom works even without cursor anchoring.
    weak var probe: NSView?
    private var monitor: Any?
    private weak var store: Store?

    func start(store: Store) {
        self.store = store
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel]) { [weak self] event in
            guard let self else { return event }
            return MainActor.assumeIsolated { self.handle(event) } ? nil : event
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    /// Returns true when the event was consumed as a zoom.
    private func handle(_ event: NSEvent) -> Bool {
        guard let store else { return false }
        guard let area: NSView = scrollView ?? probe, let window = area.window,
              event.window === window else { return false }

        // Only over the artboard: the layers list and inspector keep scrolling normally.
        let local = area.convert(event.locationInWindow, from: nil)
        guard area.bounds.contains(local) else { return false }

        guard let factor = CanvasZoom.zoomFactor(
            precise: event.hasPreciseScrollingDeltas,
            commandHeld: event.modifierFlags.contains(.command),
            deltaY: Double(event.scrollingDeltaY)) else { return false }

        apply(store.zoom * factor, anchorInWindow: event.locationInWindow, store: store)
        return true
    }

    /// How a scroll event should be treated. `nil` means "not ours" — let it through
    /// so the view keeps panning.
    ///
    /// - `precise` is `NSEvent.hasPreciseScrollingDeltas`: true for a trackpad or
    ///   Magic Mouse, false for a notched wheel. A trackpad's plain two-finger scroll
    ///   must keep panning, so it only zooms with ⌘ held.
    /// - A wheel reports whole notches and a trackpad reports points, so the two need
    ///   very different sensitivities to feel alike.
    static func zoomFactor(precise: Bool, commandHeld: Bool, deltaY: Double) -> Double? {
        guard !precise || commandHeld else { return nil }
        guard deltaY != 0 else { return 1 }
        return precise ? pow(1.006, deltaY) : pow(1.15, deltaY)
    }

    /// Where the content should sit after a zoom so the point under the cursor stays put.
    static func anchoredOrigin(cursorInContent point: CGPoint,
                               contentBefore: CGSize, contentAfter: CGSize,
                               visibleOrigin: CGPoint, viewport: CGSize) -> CGPoint {
        let fractionX = contentBefore.width > 0 ? point.x / contentBefore.width : 0.5
        let fractionY = contentBefore.height > 0 ? point.y / contentBefore.height : 0.5
        let insetX = point.x - visibleOrigin.x
        let insetY = point.y - visibleOrigin.y
        return CGPoint(
            x: min(max(fractionX * contentAfter.width - insetX, 0),
                   max(contentAfter.width - viewport.width, 0)),
            y: min(max(fractionY * contentAfter.height - insetY, 0),
                   max(contentAfter.height - viewport.height, 0)))
    }

    var pointerInWindow: NSPoint? {
        scrollView?.window?.mouseLocationOutsideOfEventStream
    }

    /// Zoom to `target`, keeping whatever sits under `anchorInWindow` under it afterwards.
    func apply(_ target: Double, anchorInWindow: NSPoint?, store: Store) {
        let clamped = min(max(target, CanvasZoom.range.lowerBound), CanvasZoom.range.upperBound)
        guard abs(clamped - store.zoom) > 0.0001 else { return }

        guard let scrollView, let document = scrollView.documentView, let anchor = anchorInWindow else {
            store.zoom = clamped
            return
        }

        // Where the cursor sits in the content, as a fraction of it and as an offset
        // into the viewport. The content isn't a pure scale of itself — rulers and
        // padding stay a fixed size — but over one zoom step the error is invisible.
        let before = document.frame.size
        let point = document.convert(anchor, from: nil)
        let visible = scrollView.documentVisibleRect

        store.zoom = clamped

        // The content resizes on the next layout pass, so the correction waits for it.
        DispatchQueue.main.async { [weak self] in
            guard let scrollView = self?.scrollView,
                  let document = scrollView.documentView else { return }
            let origin = CanvasZoom.anchoredOrigin(
                cursorInContent: point,
                contentBefore: before, contentAfter: document.frame.size,
                visibleOrigin: visible.origin, viewport: scrollView.contentView.bounds.size)
            scrollView.contentView.setBoundsOrigin(origin)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }
}

/// Finds the `NSScrollView` SwiftUI built for the canvas, so zoom can keep the point
/// under the cursor fixed instead of drifting toward the middle.
struct ScrollViewFinder: NSViewRepresentable {
    let zoom: CanvasZoom

    final class Probe: NSView {
        var onFound: ((NSView, NSScrollView?) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            report()
            // The enclosing scroll view isn't always hooked up yet at this point.
            DispatchQueue.main.async { [weak self] in self?.report() }
        }

        private func report() {
            guard window != nil else { return }
            onFound?(self, enclosingScrollView)
        }
    }

    func makeNSView(context: Context) -> Probe {
        let probe = Probe(frame: .zero)
        probe.onFound = { [zoom] view, found in
            MainActor.assumeIsolated {
                zoom.probe = view
                if let found { zoom.scrollView = found }
            }
        }
        return probe
    }

    func updateNSView(_ nsView: Probe, context: Context) {}
}
