import SwiftUI
import AppKit
import UniformTypeIdentifiers

extension UTType {
    static let picpakDocument = UTType(exportedAs: "com.picpak.studio.document",
                                       conformingTo: .json)
}

@MainActor
enum AssetImporter {

    static func pick(kind: Asset.Kind, completion: @escaping (Asset) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = kind == .svg ? [.svg] : [.png, .jpeg, .tiff, .gif, .bmp, .heic, .webP]
        panel.message = kind == .svg ? "Choose an SVG" : "Choose an image"
        guard panel.runModal() == .OK, let url = panel.url,
              let data = try? Data(contentsOf: url) else { return }
        completion(Asset(kind: kind, filename: url.lastPathComponent, data: data))
    }

    /// Accepts both kinds in one panel and works out which it got.
    static func pickAny(completion: @escaping (Asset) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.svg, .png, .jpeg, .tiff, .gif, .bmp, .heic, .webP]
        panel.message = "Choose artwork to place"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let asset = asset(from: url) else { return }
        completion(asset)
    }

    static func asset(from url: URL) -> Asset? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let isSVG = url.pathExtension.lowercased() == "svg"
            || (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType) == .svg
        return Asset(kind: isSVG ? .svg : .bitmap, filename: url.lastPathComponent, data: data)
    }
}

@MainActor
enum FileActions {

    // MARK: - Place artwork

    static func place(_ asset: Asset, into store: Store) {
        guard let image = ImageFX.nsImage(from: asset), image.size.width > 0, image.size.height > 0 else {
            store.flash("That file couldn't be read as artwork.")
            return
        }
        let canvas = store.doc.canvas
        let aspect = image.size.width / image.size.height
        var w = min(canvas.w * 0.6, image.size.width)
        var h = w / aspect
        if h > canvas.h * 0.8 { h = canvas.h * 0.8; w = h * aspect }

        store.begin()
        let id = store.registerAsset(kind: asset.kind, filename: asset.filename, data: asset.data)
        var element = Element.make(asset.kind == .svg ? .svg : .image,
                                   at: CGRect(x: ((canvas.w - w) / 2).rounded(),
                                              y: ((canvas.h - h) / 2).rounded(),
                                              width: w.rounded(), height: h.rounded()))
        element.assetID = id
        element.name = asset.filename
        if asset.kind == .svg { element.tint = .black }
        store.doc.elements.append(element)
        store.selection = [element.id]
    }

    static func importArtwork(into store: Store) {
        AssetImporter.pickAny { asset in place(asset, into: store) }
    }

    static func importArtwork(kind: Asset.Kind, into store: Store) {
        AssetImporter.pick(kind: kind) { asset in place(asset, into: store) }
    }

    // MARK: - Open

    static func open(into store: Store) {
        guard confirmDiscard(store) else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.picpakDocument, .json, .png]
        panel.allowsOtherFileTypes = true
        panel.message = "Open a .picpak project, or a PNG exported with its project inside"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        open(url: url, into: store)
    }

    static func open(url: URL, into store: Store) {
        do {
            let data = try Data(contentsOf: url)
            let document: PicPakDocument
            if url.pathExtension.lowercased() == "png" {
                document = try Exporter.documentFromPNG(data)
            } else {
                document = try PicPakDocument.decode(data)
            }
            RenderCache.shared.clear()
            store.load(document, url: url.pathExtension.lowercased() == "picpak" ? url : nil)
            RecentDocuments.shared.note(url)
            store.flash("Opened \(url.lastPathComponent)")
        } catch {
            present(error: error)
        }
    }

    // MARK: - Save

    @discardableResult
    static func save(_ store: Store) -> Bool {
        guard let url = store.fileURL else { return saveAs(store) }
        return write(store, to: url)
    }

    @discardableResult
    static func saveAs(_ store: Store) -> Bool {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.picpakDocument]
        panel.nameFieldStringValue = defaultName(store) + ".picpak"
        panel.message = "Save the editable project"
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        return write(store, to: url)
    }

    @discardableResult
    private static func write(_ store: Store, to url: URL) -> Bool {
        do {
            var document = store.doc
            document.vacuum()
            try document.encoded().write(to: url, options: .atomic)
            store.fileURL = url
            store.isDirty = false
            RecentDocuments.shared.note(url)
            store.flash("Saved \(url.lastPathComponent)")
            return true
        } catch {
            present(error: error)
            return false
        }
    }

    // MARK: - Export

    static func exportPNG(_ store: Store, options: Exporter.ExportOptions) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        let suffix = options.scale > 1 ? "@\(options.scale)x" : ""
        panel.nameFieldStringValue = defaultName(store) + suffix + ".png"
        panel.message = options.embedProject
            ? "The project is tucked inside this PNG — you can reopen it here"
            : "Flat PNG, no project data"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Exporter.pngData(store.doc, options: options)
            try data.write(to: url, options: .atomic)
            if options.embedProject { RecentDocuments.shared.note(url) }
            store.flash("Exported \(url.lastPathComponent)")
        } catch {
            present(error: error)
        }
    }

    static func copyPNGToPasteboard(_ store: Store) {
        guard let image = Exporter.panelImage(store.doc) else { return }
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setData(data, forType: .png)
        store.flash("Panel image copied to the clipboard")
    }

    // MARK: - Helpers

    static func defaultName(_ store: Store) -> String {
        if let url = store.fileURL { return url.deletingPathExtension().lastPathComponent }
        let title = store.doc.meta.title.trimmingCharacters(in: .whitespaces)
        return title.isEmpty ? "Untitled" : title
    }

    static func confirmDiscard(_ store: Store) -> Bool {
        guard store.isDirty else { return true }
        let alert = NSAlert()
        alert.messageText = "Save changes to \(defaultName(store))?"
        alert.informativeText = "Your changes will be lost otherwise."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return save(store)
        case .alertSecondButtonReturn: return true
        default: return false
        }
    }

    static func present(error: Error) {
        let alert = NSAlert()
        alert.messageText = "Something went wrong"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.runModal()
    }
}
