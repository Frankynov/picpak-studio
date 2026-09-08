import SwiftUI
import AppKit

struct Inspector: View {
    @EnvironmentObject var store: Store
    @State private var showSymbolPicker = false
    @State private var showFontPicker = false

    var body: some View {
        Perf.tick("inspector")
        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if store.selection.isEmpty {
                    canvasInspector
                } else {
                    header
                    geometry
                    paint
                    typeSpecific
                    arrange
                }
            }
            .padding(.bottom, 20)
        }
        .frame(minWidth: 260, idealWidth: 280)
        .sheet(isPresented: $showSymbolPicker) {
            SymbolPicker(selection: bind(\.symbolName, "symbolName", ""))
        }
    }

    // MARK: - Bindings that edit every selected element at once

    private func bind<T: Equatable>(_ keyPath: WritableKeyPath<Element, T>,
                                    _ token: String, _ fallback: T) -> Binding<T> {
        Binding(
            get: { store.primarySelection?[keyPath: keyPath] ?? fallback },
            set: { newValue in
                store.beginCoalesced(token)
                store.updateSelected { $0[keyPath: keyPath] = newValue }
            }
        )
    }

    private var first: Element? { store.primarySelection }
    private var types: Set<ElementType> { Set(store.selectedElements.map(\.type)) }
    private func showsFor(_ shown: Set<ElementType>) -> Bool { !types.isDisjoint(with: shown) }

    // MARK: - No selection: the canvas itself

    private var canvasInspector: some View {
        Group {
            InspectorSection(title: "Panel") {
                HStack(spacing: 6) {
                    NumberField(label: "W", value: Binding(
                        get: { store.doc.canvas.w },
                        set: { store.beginCoalesced("canvasW"); store.doc.canvas.w = $0 }),
                                range: 16...2000, onBegin: {})
                    NumberField(label: "H", value: Binding(
                        get: { store.doc.canvas.h },
                        set: { store.beginCoalesced("canvasH"); store.doc.canvas.h = $0 }),
                                range: 16...2000, onBegin: {})
                }
                HStack(spacing: 6) {
                    Button("400 × 300") { store.begin(); store.doc.canvas.w = 400; store.doc.canvas.h = 300 }
                    Button("Swap") {
                        store.begin()
                        let w = store.doc.canvas.w
                        store.doc.canvas.w = store.doc.canvas.h
                        store.doc.canvas.h = w
                    }
                }
                .controlSize(.small)
                .buttonStyle(.bordered)

                PaintPicker(label: "Paper", value: Binding(
                    get: { store.doc.canvas.background },
                    set: { store.doc.canvas.background = $0 ?? .white }),
                            allowsNone: false,
                            onBegin: { store.begin() })
            }

            InspectorSection(title: "Project") {
                TextField("Title", text: $store.doc.meta.title)
                    .textFieldStyle(.roundedBorder)
                Text("\(store.doc.elements.count) layers · \(store.doc.assets.count) embedded assets")
                    .font(.caption).foregroundStyle(.secondary)
            }

            InspectorSection(title: "Gamut Check") {
                GamutMeter()
            }

            InspectorSection(title: "View") {
                Toggle("Rulers", isOn: $store.showRulers)
                Toggle("Grid", isOn: $store.showGrid)
                Toggle("Snap to guides", isOn: $store.snapEnabled)
                Toggle("Bezel margin", isOn: $store.showBleedGuides)
                Toggle("Panel preview", isOn: $store.panelPreview)
                    .help("Show the exact bitmap the panel will paint")
                if store.panelPreview {
                    Text("Showing hardened panel pixels. Soft edges disappear because "
                         + "e-paper has only the four inks — no shades in between.")
                        .font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.checkbox)
            .controlSize(.small)
        }
    }

    // MARK: - Header

    private var header: some View {
        InspectorSection(title: store.selection.count > 1
                         ? "\(store.selection.count) Selected"
                         : (first?.type.label ?? "Element")) {
            HStack(spacing: 6) {
                Image.safeSymbol(first?.type.symbol ?? "square")
                    .foregroundStyle(.secondary)
                TextField("Name", text: bind(\.name, "name", ""))
                    .textFieldStyle(.roundedBorder)
                Button {
                    store.begin()
                    let value = !(first?.hidden ?? false)
                    store.updateSelected { $0.hidden = value }
                } label: { Image(systemName: (first?.hidden ?? false) ? "eye.slash" : "eye") }
                    .buttonStyle(.borderless)
                Button {
                    let value = !(first?.locked ?? false)
                    store.begin()
                    for id in store.selection {
                        store.doc[id].map { _ in }
                        if let i = store.doc.index(of: id) { store.doc.elements[i].locked = value }
                    }
                } label: { Image(systemName: (first?.locked ?? false) ? "lock.fill" : "lock.open") }
                    .buttonStyle(.borderless)
            }
        }
    }

    // MARK: - Geometry

    private var geometry: some View {
        InspectorSection(title: "Geometry") {
            HStack(spacing: 6) {
                NumberField(label: "X", value: bind(\.x, "x", 0))
                NumberField(label: "Y", value: bind(\.y, "y", 0))
            }
            HStack(spacing: 6) {
                NumberField(label: "W", value: bind(\.w, "w", 0), range: 0...4000)
                NumberField(label: "H", value: bind(\.h, "h", 0), range: 0...4000)
            }
            HStack(spacing: 6) {
                NumberField(label: "∠", value: bind(\.rotation, "rot", 0), range: -360...360, step: 5)
                Button { store.begin(); store.updateSelected { $0.rotation = 0 } } label: {
                    Image(systemName: "arrow.counterclockwise")
                }
                .buttonStyle(.bordered).controlSize(.small).help("Reset rotation")
                Button { store.begin(); store.updateSelected { $0.flipH.toggle() } } label: {
                    Image(systemName: "arrow.left.and.right.righttriangle.left.righttriangle.right")
                }
                .buttonStyle(.bordered).controlSize(.small).help("Flip horizontally")
                Button { store.begin(); store.updateSelected { $0.flipV.toggle() } } label: {
                    Image(systemName: "arrow.up.and.down.righttriangle.up.righttriangle.down")
                }
                .buttonStyle(.bordered).controlSize(.small).help("Flip vertically")
            }
            Button("Snap to whole pixels") {
                store.begin()
                store.updateSelected {
                    $0.x = $0.x.rounded(); $0.y = $0.y.rounded()
                    $0.w = $0.w.rounded(); $0.h = $0.h.rounded()
                }
            }
            .controlSize(.small)
        }
    }

    // MARK: - Paint

    private var paint: some View {
        InspectorSection(title: "Colour") {
            PaintPicker(label: fillLabel, value: bind(\.fill, "fill", nil),
                        allowsNone: !showsFor([.text, .symbol, .barcode]),
                        onBegin: { store.begin() })
            if showsFor([.rect, .ellipse, .triangle, .star, .polygon, .arrow, .line]) {
                PaintPicker(label: "Stroke", value: bind(\.stroke, "stroke", nil),
                            onBegin: { store.begin() })
                if first?.stroke != nil || (first?.strokeWidth ?? 0) > 0 {
                    SliderRow(label: "Stroke width", value: bind(\.strokeWidth, "sw", 0),
                              range: 0...24, format: "%.1f px", onBegin: { store.breakCoalescing() })
                }
            }
            if showsFor([.rect]) {
                SliderRow(label: "Corner radius", value: bind(\.cornerRadius, "cr", 0),
                          range: 0...80, format: "%.0f px", onBegin: { store.breakCoalescing() })
            }
            if showsFor([.star, .polygon]) {
                SliderRow(label: showsFor([.polygon]) ? "Sides" : "Points", value: Binding(
                    get: { Double(first?.points ?? 5) },
                    set: { new in store.beginCoalesced("pts"); store.updateSelected { $0.points = Int(new.rounded()) } }),
                          range: 3...14, format: "%.0f")
            }
            if showsFor([.arrow]) {
                SliderRow(label: "Head", value: bind(\.arrowHead, "head", 0.42),
                          range: 0.1...0.9, format: "%.2f", onBegin: { store.breakCoalescing() })
                SliderRow(label: "Shaft", value: bind(\.arrowThickness, "shaft", 0.38),
                          range: 0.05...1, format: "%.2f", onBegin: { store.breakCoalescing() })
            }
        }
    }

    private var fillLabel: String {
        if showsFor([.text]) { return "Text" }
        if showsFor([.symbol, .barcode]) { return "Ink" }
        return "Fill"
    }

    // MARK: - Per-type

    @ViewBuilder
    private var typeSpecific: some View {
        if showsFor([.text]) { textSection }
        if showsFor([.symbol]) { symbolSection }
        if showsFor([.svg, .image]) { artworkSection }
        if showsFor([.barcode]) { barcodeSection }
    }

    private var textSection: some View {
        InspectorSection(title: "Text") {
            TextEditor(text: bind(\.text, "text", ""))
                .font(.system(size: 12))
                .frame(height: 64)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.secondary.opacity(0.3)))

            Button {
                showFontPicker = true
            } label: {
                HStack(spacing: 4) {
                    Text("Aa").font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(first?.fontFamily ?? "System")
                        .font(.system(size: 11))
                        .lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 8))
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .popover(isPresented: $showFontPicker, arrowEdge: .bottom) {
                FontPicker(selection: Binding(
                    get: { first?.fontFamily ?? "" },
                    set: { new in
                        store.begin()
                        store.updateSelected { $0.fontFamily = new.isEmpty ? nil : new }
                    }))
            }

            HStack(spacing: 6) {
                Picker("", selection: bind(\.fontWeight, "fw", .bold)) {
                    ForEach(PPFontWeight.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .labelsHidden()
                Picker("", selection: bind(\.fontDesign, "fd", .standard)) {
                    ForEach(PPFontDesign.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .labelsHidden()
                .disabled(first?.fontFamily != nil)
            }
            .controlSize(.small)

            HStack(spacing: 6) {
                NumberField(label: "◆", value: bind(\.fontSize, "fs", 24), range: 4...400, step: 2)
                Toggle("Fit", isOn: bind(\.autoFit, "fit", false))
                    .toggleStyle(.checkbox).controlSize(.small)
                    .help("Shrink the type until it fits the box")
            }

            HStack(spacing: 10) {
                SegmentedIcons(options: PPAlign.allCases.map { ($0, $0.symbol, $0.rawValue) },
                               selection: bind(\.align, "align", .center),
                               onBegin: { store.begin() })
                SegmentedIcons(options: PPVAlign.allCases.map { ($0, $0.symbol, $0.rawValue) },
                               selection: bind(\.vAlign, "valign", .middle),
                               onBegin: { store.begin() })
            }

            SliderRow(label: "Tracking", value: bind(\.tracking, "tr", 0),
                      range: -5...20, format: "%.1f", onBegin: { store.breakCoalescing() })
            SliderRow(label: "Line spacing", value: bind(\.lineSpacing, "ls", 0),
                      range: -10...40, format: "%.0f", onBegin: { store.breakCoalescing() })

            HStack {
                Toggle("UPPER", isOn: bind(\.uppercase, "uc", false))
                Toggle("Strike", isOn: bind(\.strikethrough, "st", false))
            }
            .toggleStyle(.checkbox).controlSize(.small)

            if first?.strikethrough == true {
                PaintPicker(label: "Strike", value: bind(\.strikeColor, "stc", nil),
                            onBegin: { store.begin() })
            }
        }
    }

    private var symbolSection: some View {
        InspectorSection(title: "Symbol") {
            Button {
                showSymbolPicker = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: first?.symbolName ?? "questionmark")
                        .font(.system(size: 22))
                        .frame(width: 34, height: 34)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(first?.symbolName ?? "")
                            .font(.system(size: 11, design: .monospaced))
                            .lineLimit(1).truncationMode(.middle)
                        Text("Browse \(SymbolCatalog.all.count) symbols")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.bordered)
            Picker("Weight", selection: bind(\.fontWeight, "symw", .bold)) {
                ForEach(PPFontWeight.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .controlSize(.small)
        }
    }

    private var artworkSection: some View {
        InspectorSection(title: showsFor([.svg]) ? "Vector" : "Bitmap") {
            HStack {
                Text(assetName).font(.caption).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("Replace…") { replaceAsset() }.controlSize(.small)
            }

            PaintPicker(label: "Recolour", value: bind(\.tint, "tint", nil),
                        onBegin: { store.begin() })
            Text(first?.tint == nil
                 ? "Keeping the artwork's colours, reduced to the panel gamut."
                 : "Flattened to a single-colour silhouette.")
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            if showsFor([.image]), first?.tint == nil {
                Picker("Reduction", selection: bind(\.dither, "dither", .floyd)) {
                    ForEach(DitherMode.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .controlSize(.small)
                SliderRow(label: "Brightness", value: bind(\.brightness, "bri", 0),
                          range: -0.6...0.6, format: "%.2f", onBegin: { store.breakCoalescing() })
                SliderRow(label: "Contrast", value: bind(\.contrast, "con", 1),
                          range: 0.2...3, format: "%.2f", onBegin: { store.breakCoalescing() })
                Toggle("Knock out white background", isOn: bind(\.knockoutWhite, "ko", false))
                    .toggleStyle(.checkbox).controlSize(.small)
                if first?.knockoutWhite == true {
                    SliderRow(label: "Threshold", value: bind(\.knockoutThreshold, "kot", 0.88),
                              range: 0.5...0.99, format: "%.2f", onBegin: { store.breakCoalescing() })
                }
            }

            Button("Reset to natural aspect") { resetAspect() }
                .controlSize(.small)
        }
    }

    private var barcodeSection: some View {
        InspectorSection(title: "Barcode") {
            Picker("Kind", selection: bind(\.barcodeKind, "bk", .code128)) {
                ForEach(BarcodeKind.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .controlSize(.small)
            TextField("Value", text: bind(\.barcodeValue, "bv", ""))
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11, design: .monospaced))
            Text("Code 128 takes any ASCII; QR takes a URL or text.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    // MARK: - Arrange

    private var arrange: some View {
        InspectorSection(title: "Arrange") {
            HStack(spacing: 2) {
                alignButton(.left, "align.horizontal.left")
                alignButton(.hCenter, "align.horizontal.center")
                alignButton(.right, "align.horizontal.right")
                Divider().frame(height: 16)
                alignButton(.top, "align.vertical.top")
                alignButton(.vCenter, "align.vertical.center")
                alignButton(.bottom, "align.vertical.bottom")
            }
            if store.selection.count > 2 {
                HStack(spacing: 6) {
                    Button("Distribute ↔") { store.distribute(horizontal: true) }
                    Button("Distribute ↕") { store.distribute(horizontal: false) }
                }
                .controlSize(.small)
            }
            HStack(spacing: 2) {
                orderButton("Front", "square.3.stack.3d.top.filled") { store.bringToFront() }
                orderButton("Forward", "square.2.layers.3d.top.filled") { store.bringForward() }
                orderButton("Backward", "square.2.layers.3d.bottom.filled") { store.sendBackward() }
                orderButton("Back", "square.3.stack.3d.bottom.filled") { store.sendToBack() }
            }
            Text(store.selection.count == 1
                 ? "Aligns to the panel edges."
                 : "Aligns to the selection's bounds.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func alignButton(_ edge: Store.AlignEdge, _ symbol: String) -> some View {
        Button { store.align(edge) } label: {
            Image(systemName: symbol).frame(width: 26, height: 22)
        }
        .buttonStyle(.bordered)
    }

    private func orderButton(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).frame(width: 30, height: 22)
        }
        .buttonStyle(.bordered)
        .help(title)
    }

    // MARK: - Asset helpers

    private var assetName: String {
        guard let id = first?.assetID, let asset = store.doc.assets[id] else { return "Missing asset" }
        return asset.filename
    }

    private func replaceAsset() {
        guard let element = first else { return }
        AssetImporter.pick(kind: element.type == .svg ? .svg : .bitmap) { asset in
            store.begin()
            let id = store.registerAsset(kind: asset.kind, filename: asset.filename, data: asset.data)
            store.updateSelected { $0.assetID = id }
            store.doc.vacuum()
        }
    }

    private func resetAspect() {
        guard let element = first, let id = element.assetID, let asset = store.doc.assets[id],
              let image = ImageFX.nsImage(from: asset), image.size.height > 0 else { return }
        store.begin()
        let aspect = image.size.width / image.size.height
        store.updateSelected { $0.h = ($0.w / aspect).rounded() }
    }
}

/// How much of the panel each ink covers — a fast reality check before pushing.
private struct GamutMeter: View {
    @EnvironmentObject var store: Store
    @State private var counts: [PPColor: Int] = [:]
    @State private var total: Int = 1

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geo in
                HStack(spacing: 1) {
                    ForEach(PPColor.allCases) { colour in
                        let share = Double(counts[colour] ?? 0) / Double(max(total, 1))
                        Rectangle()
                            .fill(colour.color)
                            .frame(width: max(geo.size.width * share, share > 0 ? 2 : 0))
                    }
                }
                .frame(height: 14)
                .clipShape(RoundedRectangle(cornerRadius: 3))
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.secondary.opacity(0.3)))
            }
            .frame(height: 14)

            ForEach(PPColor.allCases) { colour in
                let share = Double(counts[colour] ?? 0) / Double(max(total, 1)) * 100
                if share >= 0.05 {
                    HStack(spacing: 5) {
                        RoundedRectangle(cornerRadius: 2).fill(colour.color)
                            .frame(width: 9, height: 9)
                            .overlay(RoundedRectangle(cornerRadius: 2).stroke(Color.secondary.opacity(0.4)))
                        Text(colour.label).font(.caption2)
                        Spacer()
                        Text(String(format: "%.1f%%", share))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        // Counting inks means rendering and reducing the whole panel, so it trails
        // the document rather than recomputing on every edit.
        .task(id: store.revision) {
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            recalc()
        }
    }

    private func recalc() {
        guard let image = Exporter.panelImage(store.doc, quantize: true, dither: .none) else { return }
        counts = Exporter.histogram(image)
        total = max(counts.values.reduce(0, +), 1)
    }
}
