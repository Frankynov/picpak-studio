import SwiftUI
import AppKit
import Combine

/// Zoom and scroll for the artboard, done the way Preview and Safari do it.
///
/// The canvas lives in a real `NSScrollView` with magnification turned on, so pinching,
/// two-finger panning, momentum, rubber-banding and double-tap smart zoom are all
/// AppKit's own. During a pinch AppKit scales what is already drawn — nothing is laid
/// out again, so nothing can flash. When the gesture ends the magnification is folded
/// back into the document's zoom: the board re-renders crisply at the new scale and the
/// scroll position moves in the same pass.
///
/// That fold is only exact if the document is a *pure* scale of the artboard. So the
/// margin around the artboard is measured in panel pixels and grows with zoom, and the
/// rulers live outside the scroll view, pinned along its edges like Preview's.
enum CanvasZoom {
    static let range: ClosedRange<Double> = 0.25...12

    /// Backdrop around the artboard, in panel pixels — so it scales with everything else.
    static let margin: Double = 20

    static let rulerThickness: Double = 18

    static func documentSize(canvas: CGSize, zoom: Double) -> CGSize {
        CGSize(width: (Double(canvas.width) + margin * 2) * zoom,
               height: (Double(canvas.height) + margin * 2) * zoom)
    }

    /// How a scroll event should be treated. `nil` means "not ours" — let it pan.
    ///
    /// - `precise` is `NSEvent.hasPreciseScrollingDeltas`: true for a trackpad or Magic
    ///   Mouse, false for a notched wheel. A trackpad's two-finger scroll must keep
    ///   panning, so it only zooms with ⌘ held; a wheel has nothing else to do.
    /// - A wheel reports whole notches and a trackpad reports points, so the two need
    ///   very different sensitivities to feel alike.
    static func zoomFactor(precise: Bool, commandHeld: Bool, deltaY: Double) -> Double? {
        guard !precise || commandHeld else { return nil }
        guard deltaY != 0 else { return 1 }
        return precise ? pow(1.006, deltaY) : pow(1.15, deltaY)
    }

    /// Folding a live magnification `m` into the zoom. The document is a pure scale of
    /// the artboard, so re-rendering it `m` times larger and scaling the scroll origin
    /// by `m` puts every point back exactly where it was on screen — at the edges too,
    /// because the scrollable range scales by `m` as well.
    static func bakedOrigin(origin: CGPoint, magnification m: Double) -> CGPoint {
        CGPoint(x: Double(origin.x) * m, y: Double(origin.y) * m)
    }

    /// Magnifying around a point: `point` (document coordinates) sat `offset` points from
    /// the viewport's top-left before the change and must sit there after it. At
    /// magnification `m` the origin that does that is `point − offset / m`.
    ///
    /// AppKit's `setMagnification(_:centeredAt:)` isn't used for this: measured in this
    /// view, it moved the point under the pointer by about 43 pt instead of holding it.
    static func anchoredOrigin(point: CGPoint, offset: CGPoint, magnification m: Double) -> CGPoint {
        CGPoint(x: Double(point.x) - Double(offset.x) / m,
                y: Double(point.y) - Double(offset.y) / m)
    }

    /// Where the view rests on one axis once nothing is moving: a document smaller than
    /// the visible span is centred, a larger one is kept filling the view.
    static func restingOrigin(_ origin: Double, document: Double, visible: Double) -> Double {
        visible > document ? (document - visible) / 2 : min(max(origin, 0), document - visible)
    }

    /// A zoom from the toolbar or menu keeps whatever is at the centre of the view there.
    static func recentredOrigin(visible: CGRect, oldZoom: Double, newZoom: Double) -> CGPoint {
        let ratio = newZoom / oldZoom
        return CGPoint(x: Double(visible.midX) * ratio - Double(visible.width) / 2,
                       y: Double(visible.midY) * ratio - Double(visible.height) / 2)
    }

    /// Where panel pixel `value` falls along a ruler, in points from the ruler's start.
    /// `origin` is the scroll view's origin along that axis, in document points.
    static func rulerPosition(value: Double, zoom: Double, magnification: Double, origin: Double) -> Double {
        ((value + margin) * zoom - origin) * magnification
    }

    /// The panel pixel under a point along the ruler — the inverse of `rulerPosition`.
    static func rulerValue(position: Double, zoom: Double, magnification: Double, origin: Double) -> Double {
        (position / magnification + origin) / zoom - margin
    }

    /// Keep ruler labels roughly 40 pt apart whatever the zoom.
    static func rulerStep(pointsPerPixel: Double) -> Double {
        for candidate in [5.0, 10, 25, 50, 100, 200] where candidate * pointsPerPixel >= 40 {
            return candidate
        }
        return 200
    }
}

/// What the rulers need to know about the scroll view, published as it scrolls and
/// magnifies. Only the two rulers observe it, so a pan redraws two strips — not the board.
@MainActor
final class CanvasViewport: ObservableObject {
    @Published var origin: CGPoint = .zero
    @Published var magnification: Double = 1
    @Published var zoom: Double = 1
    @Published var canvasSize = CGSize(width: 400, height: 300)
    /// The selection's live extent in panel pixels, for shading the rulers.
    @Published var highlight: CGRect?
}

// MARK: - AppKit pieces

/// Keeps the artboard centred while it is smaller than the view, as Preview does.
///
/// Only the canvas's own zoom code may place the view beyond those limits, and only inside
/// `overshooting {}` — a synchronous scope. An earlier version switched the limits off for
/// the whole length of a zoom; AppKit's momentum scrolling, running on the display link in
/// the meantime, fed unconstrained positions into its rubber-banding maths and got NaN back
/// ("Invalid view geometry: x is NaN" — a crash).
final class CenteringClipView: NSClipView {
    private var allowsOvershoot = false

    func overshooting(_ body: () -> Void) {
        allowsOvershoot = true
        defer { allowsOvershoot = false }
        body()
    }

    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        // AppKit proposes ±infinity to find the ends of the scrollable range, so those must
        // reach super — answered with the current bounds, panning towards the start stuck
        // after a few points. Only NaN, which AppKit aborts on, is swapped for the bounds.
        var proposed = proposedBounds
        if proposed.origin.x.isNaN { proposed.origin.x = bounds.origin.x }
        if proposed.origin.y.isNaN { proposed.origin.y = bounds.origin.y }
        if proposed.width.isNaN || proposed.height.isNaN { proposed.size = bounds.size }
        let finite = proposed.origin.x.isFinite && proposed.origin.y.isFinite
            && proposed.width.isFinite && proposed.height.isFinite
        if allowsOvershoot && finite { return proposed }
        var rect = super.constrainBoundsRect(proposed)
        guard let document = documentView else { return rect }
        rect.origin.x = CGFloat(CanvasZoom.restingOrigin(Double(rect.origin.x),
                                                         document: Double(document.frame.width),
                                                         visible: Double(rect.width)))
        rect.origin.y = CGFloat(CanvasZoom.restingOrigin(Double(rect.origin.y),
                                                         document: Double(document.frame.height),
                                                         visible: Double(rect.height)))
        guard rect.origin.x.isFinite, rect.origin.y.isFinite else { return bounds }
        return rect
    }
}

/// Adds exactly one thing to a stock scroll view: a notched mouse wheel zooms instead
/// of scrolling. Everything a trackpad does stays AppKit's.
final class CanvasNSScrollView: NSScrollView {
    var onWheelZoom: (@MainActor (_ factor: Double, _ locationInWindow: NSPoint) -> Void)?
    /// Called when a pan gesture begins, before AppKit starts scrolling.
    var onPanBegins: (@MainActor () -> Void)?

    override func scrollWheel(with event: NSEvent) {
        if let factor = CanvasZoom.zoomFactor(precise: event.hasPreciseScrollingDeltas,
                                              commandHeld: event.modifierFlags.contains(.command),
                                              deltaY: Double(event.scrollingDeltaY)) {
            if factor != 1 { onWheelZoom?(factor, event.locationInWindow) }
            return
        }
        if event.phase.contains(.mayBegin) || event.phase.contains(.began) {
            onPanBegins?()
        }
        super.scrollWheel(with: event)
    }
}

/// Hosts the SwiftUI board. Scroll and magnify events are handed straight to the scroll
/// view: the board has no scrolling of its own, and forwarding them explicitly means a
/// pinch can't be swallowed somewhere on the way up the responder chain.
final class CanvasHostingView<Content: View>: NSHostingView<Content> {
    override func scrollWheel(with event: NSEvent) {
        if let scroll = enclosingScrollView { scroll.scrollWheel(with: event) } else { super.scrollWheel(with: event) }
    }
    override func magnify(with event: NSEvent) {
        if let scroll = enclosingScrollView { scroll.magnify(with: event) } else { super.magnify(with: event) }
    }
    override func smartMagnify(with event: NSEvent) {
        if let scroll = enclosingScrollView { scroll.smartMagnify(with: event) } else { super.smartMagnify(with: event) }
    }
}

// MARK: - SwiftUI bridge

struct CanvasScrollView<Content: View>: NSViewRepresentable {
    let store: Store
    let viewport: CanvasViewport
    let content: Content

    func makeCoordinator() -> Coordinator { Coordinator(store: store, viewport: viewport) }

    func makeNSView(context: Context) -> CanvasNSScrollView {
        let scroll = CanvasNSScrollView()
        scroll.contentView = CenteringClipView()
        // The scroll view paints the backdrop itself, so any area not drawn yet is the
        // backdrop's grey — never the white of an empty layer.
        scroll.drawsBackground = true
        scroll.backgroundColor = .underPageBackgroundColor
        scroll.hasHorizontalScroller = true
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.usesPredominantAxisScrolling = false
        scroll.horizontalScrollElasticity = .allowed
        scroll.verticalScrollElasticity = .allowed
        scroll.allowsMagnification = true
        // SwiftUI already places this view below the toolbar; AppKit's own insetting
        // would let the artboard slide up underneath it.
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsetsZero

        let host = CanvasHostingView(rootView: content)
        host.sizingOptions = []
        scroll.documentView = host

        context.coordinator.attach(scroll: scroll, host: host)
        return scroll
    }

    func updateNSView(_ scroll: CanvasNSScrollView, context: Context) {
        context.coordinator.host?.rootView = content
        context.coordinator.sync()
    }

    static func dismantleNSView(_ scroll: CanvasNSScrollView, coordinator: Coordinator) {
        coordinator.detach()
    }

    @MainActor
    final class Coordinator: NSObject {
        let store: Store
        let viewport: CanvasViewport
        weak var scroll: CanvasNSScrollView?
        var host: CanvasHostingView<Content>?

        /// What the document is currently sized for, so unrelated store changes cost
        /// one comparison.
        private var renderedZoom: Double
        private var renderedCanvas: CGSize

        private var storeChanges: AnyCancellable?
        private var pendingBake: Task<Void, Never>?
        private var settleTask: Task<Void, Never>?
        private var liveMagnifying = false
        private var clip: CenteringClipView? { scroll?.contentView as? CenteringClipView }

        init(store: Store, viewport: CanvasViewport) {
            self.store = store
            self.viewport = viewport
            renderedZoom = store.zoom
            renderedCanvas = store.doc.canvas.size
        }

        func attach(scroll: CanvasNSScrollView, host: CanvasHostingView<Content>) {
            self.scroll = scroll
            self.host = host

            scroll.onWheelZoom = { [weak self] factor, location in self?.wheelZoom(factor, at: location) }
            scroll.onPanBegins = { [weak self] in self?.finishZoomForPan() }
            let center = NotificationCenter.default
            center.addObserver(self, selector: #selector(willStartLiveMagnify(_:)),
                               name: NSScrollView.willStartLiveMagnifyNotification, object: scroll)
            center.addObserver(self, selector: #selector(didEndLiveMagnify(_:)),
                               name: NSScrollView.didEndLiveMagnifyNotification, object: scroll)
            // Scrolling and magnifying both change the clip view's bounds; that is what
            // keeps the rulers glued to the artboard, mid-gesture included.
            scroll.contentView.postsBoundsChangedNotifications = true
            center.addObserver(self, selector: #selector(boundsChanged(_:)),
                               name: NSView.boundsDidChangeNotification, object: scroll.contentView)

            // Zoom from the toolbar or a canvas resize change the document's size. The
            // main queue keeps delivering during a live scroll, which a run-loop
            // scheduler would not.
            storeChanges = store.objectWillChange
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in MainActor.assumeIsolated { self?.sync() } }

            host.setFrameSize(CanvasZoom.documentSize(canvas: renderedCanvas, zoom: renderedZoom))
            updateLimits()
            publishViewport()
            Task { @MainActor [weak self] in self?.centreDocument() }
        }

        func detach() {
            NotificationCenter.default.removeObserver(self)
            storeChanges = nil
            pendingBake?.cancel()
            settleTask?.cancel()
        }

        // MARK: Keeping the document the right size

        func sync() {
            guard let scroll, let host else { return }
            let zoom = store.zoom
            let canvas = store.doc.canvas.size
            guard zoom != renderedZoom || canvas != renderedCanvas else { return }

            pendingBake?.cancel(); pendingBake = nil
            settleTask?.cancel(); settleTask = nil
            if abs(scroll.magnification - 1) > 0.0005 { scroll.magnification = 1 }
            let origin = CanvasZoom.recentredOrigin(visible: scroll.contentView.bounds,
                                                    oldZoom: renderedZoom, newZoom: zoom)
            renderedZoom = zoom
            renderedCanvas = canvas
            host.setFrameSize(CanvasZoom.documentSize(canvas: canvas, zoom: zoom))
            setOrigin(origin)
            updateLimits()
            publishViewport()
        }

        // MARK: Zooming

        @objc private func willStartLiveMagnify(_ note: Notification) {
            liveMagnifying = true
            settleTask?.cancel(); settleTask = nil
        }

        @objc private func didEndLiveMagnify(_ note: Notification) {
            liveMagnifying = false
            bake()
        }

        @objc private func boundsChanged(_ note: Notification) {
            publishViewport()
            // Smart zoom, or anything else that magnifies without a gesture ending: fold it
            // in once things are still, so the board never stays soft.
            if let scroll, !liveMagnifying, pendingBake == nil, abs(scroll.magnification - 1) > 0.0005 {
                scheduleBake(after: .milliseconds(350))
            }
        }

        private func scheduleBake(after delay: Duration) {
            pendingBake?.cancel()
            pendingBake = Task { @MainActor [weak self] in
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
                self?.bake()
            }
        }

        /// A pan starting while a zoom is still pending or gliding back into range: fold the
        /// zoom in and put the view inside its limits *now*, so AppKit's scrolling always
        /// starts from a position its rubber-banding understands. The pan takes over.
        private func finishZoomForPan() {
            guard let scroll else { return }
            let unfinished = pendingBake != nil || settleTask != nil || liveMagnifying
                || abs(scroll.magnification - 1) > 0.0005
            guard unfinished else { return }
            pendingBake?.cancel(); pendingBake = nil
            settleTask?.cancel(); settleTask = nil
            liveMagnifying = false
            foldIn()
            if let clip { setOrigin(clip.bounds.origin) }
        }

        private func wheelZoom(_ factor: Double, at locationInWindow: NSPoint) {
            guard let scroll, let host, let clip else { return }
            settleTask?.cancel(); settleTask = nil
            let target = min(max(scroll.magnification * factor, scroll.minMagnification),
                             scroll.maxMagnification)
            let point = host.convert(locationInWindow, from: nil)
            let current = Double(scroll.magnification)
            let offset = CGPoint(x: (Double(point.x) - Double(clip.bounds.origin.x)) * current,
                                 y: (Double(point.y) - Double(clip.bounds.origin.y)) * current)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            clip.overshooting {
                scroll.magnification = target
                clip.setBoundsOrigin(CanvasZoom.anchoredOrigin(point: point, offset: offset,
                                                               magnification: Double(target)))
            }
            scroll.reflectScrolledClipView(clip)
            CATransaction.commit()
            publishViewport()

            // A wheel has no "gesture ended"; fold the zoom in once the spinning stops.
            scheduleBake(after: .milliseconds(250))
        }

        func bake() {
            pendingBake = nil
            foldIn()
            settle()
        }

        /// Turn the live magnification into a real zoom. Everything happens inside one
        /// Core Animation transaction, with SwiftUI's layout forced before the scroll
        /// position moves, so no frame can show the new size at the old position.
        private func foldIn() {
            guard let scroll, let host, let clip else { return }
            let m = Double(scroll.magnification)
            guard abs(m - 1) > 0.0005 else { return }

            let newZoom = min(max(renderedZoom * m, CanvasZoom.range.lowerBound), CanvasZoom.range.upperBound)
            let origin = CanvasZoom.bakedOrigin(origin: clip.bounds.origin,
                                                magnification: newZoom / renderedZoom)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            clip.overshooting {
                renderedZoom = newZoom
                store.zoom = newZoom
                scroll.magnification = 1
                host.setFrameSize(CanvasZoom.documentSize(canvas: renderedCanvas, zoom: newZoom))
                host.layoutSubtreeIfNeeded()
                clip.setBoundsOrigin(origin)
            }
            scroll.reflectScrolledClipView(clip)
            CATransaction.commit()
            updateLimits()
            publishViewport()
        }

        /// Glide back inside the resting limits after a zoom that overshot them. A clamp
        /// applied in a single frame reads as a jump; spread over ~180 ms it reads as the
        /// view easing into place. Each step is its own synchronous overshoot scope.
        private func settle() {
            guard let scroll, let clip else { return }
            let start = clip.bounds.origin
            let rest = clip.constrainBoundsRect(clip.bounds).origin
            guard hypot(Double(rest.x - start.x), Double(rest.y - start.y)) > 0.25 else { return }

            settleTask?.cancel()
            settleTask = Task { @MainActor [weak self] in
                let frames = 12
                for frame in 1...frames {
                    try? await Task.sleep(for: .milliseconds(15))
                    guard !Task.isCancelled else { return }
                    let t = Double(frame) / Double(frames)
                    let eased = 1 - pow(1 - t, 3)
                    let step = CGPoint(x: Double(start.x) + Double(rest.x - start.x) * eased,
                                       y: Double(start.y) + Double(rest.y - start.y) * eased)
                    clip.overshooting { clip.setBoundsOrigin(step) }
                    scroll.reflectScrolledClipView(clip)
                }
                self?.settleTask = nil
                self?.publishViewport()
            }
        }

        private func updateLimits() {
            guard let scroll else { return }
            scroll.minMagnification = CanvasZoom.range.lowerBound / renderedZoom
            scroll.maxMagnification = CanvasZoom.range.upperBound / renderedZoom
        }

        private func publishViewport() {
            guard let scroll else { return }
            let origin = scroll.contentView.bounds.origin
            let magnification = Double(scroll.magnification)
            if viewport.origin != origin { viewport.origin = origin }
            if viewport.magnification != magnification { viewport.magnification = magnification }
            if viewport.zoom != renderedZoom { viewport.zoom = renderedZoom }
            if viewport.canvasSize != renderedCanvas { viewport.canvasSize = renderedCanvas }
        }

        private func centreDocument() {
            guard let scroll, let host else { return }
            let clip = scroll.contentView.bounds.size
            setOrigin(CGPoint(x: (host.frame.width - clip.width) / 2,
                              y: (host.frame.height - clip.height) / 2))
        }

        private func setOrigin(_ origin: CGPoint) {
            guard let scroll else { return }
            let clip = scroll.contentView
            let constrained = clip.constrainBoundsRect(NSRect(origin: origin, size: clip.bounds.size))
            clip.setBoundsOrigin(constrained.origin)
            scroll.reflectScrolledClipView(clip)
            publishViewport()
        }
    }
}
