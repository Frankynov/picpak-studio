import Foundation
import CoreGraphics

/// An imported file kept inside the document so a `.picpak` is a single
/// self-contained thing you can hand to someone else.
struct Asset: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case svg, bitmap }
    var kind: Kind
    var filename: String
    var data: Data
}

struct CanvasSpec: Codable, Equatable, Sendable {
    var w: Double = 400
    var h: Double = 300
    var background: PPColor = .white

    var size: CGSize { CGSize(width: w, height: h) }
    var rect: CGRect { CGRect(x: 0, y: 0, width: w, height: h) }
}

struct DocMeta: Codable, Equatable, Sendable {
    var title: String = "Untitled"
    var created: Date = Date()
    var modified: Date = Date()
    var app: String = "PicPak Studio \(AppInfo.version)"
    var deviceIDs: [String] = []    // remembered Tesserae push targets
    var pageID: String? = nil       // the Tesserae page this document owns

    init() {}

    private enum CodingKeys: String, CodingKey {
        case title, created, modified, app, deviceIDs, pageID
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = (try? c.decode(String.self, forKey: .title)) ?? "Untitled"
        created = (try? c.decode(Date.self, forKey: .created)) ?? Date()
        modified = (try? c.decode(Date.self, forKey: .modified)) ?? Date()
        app = (try? c.decode(String.self, forKey: .app)) ?? "PicPak Studio"
        deviceIDs = (try? c.decode([String].self, forKey: .deviceIDs)) ?? []
        pageID = try? c.decodeIfPresent(String.self, forKey: .pageID)
    }
}

struct PicPakDocument: Codable, Equatable, Sendable {
    static let formatID = "picpak.studio.document"
    static let currentVersion = 1

    var format: String = PicPakDocument.formatID
    var version: Int = PicPakDocument.currentVersion
    var meta: DocMeta = DocMeta()
    var canvas: CanvasSpec = CanvasSpec()
    /// Bottom-most layer first, matching draw order.
    var elements: [Element] = []
    var assets: [String: Asset] = [:]

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        format = (try? c.decode(String.self, forKey: .format)) ?? PicPakDocument.formatID
        guard format == PicPakDocument.formatID else {
            throw DocumentError.notAPicPakDocument
        }
        version = (try? c.decode(Int.self, forKey: .version)) ?? 1
        guard version <= PicPakDocument.currentVersion else {
            throw DocumentError.tooNew(version)
        }
        meta = (try? c.decode(DocMeta.self, forKey: .meta)) ?? DocMeta()
        canvas = (try? c.decode(CanvasSpec.self, forKey: .canvas)) ?? CanvasSpec()
        elements = (try? c.decode([Element].self, forKey: .elements)) ?? []
        assets = (try? c.decode([String: Asset].self, forKey: .assets)) ?? [:]
    }

    /// Assets are compared by id, not by content.
    ///
    /// An asset id is a UUID minted at import and never reused, so two documents
    /// referencing the same id reference the same bytes. The synthesised version of
    /// this compared every embedded photo's `Data` byte by byte — which SwiftUI then
    /// paid for on every view diff, i.e. on every frame of a drag.
    static func == (lhs: PicPakDocument, rhs: PicPakDocument) -> Bool {
        lhs.format == rhs.format
            && lhs.version == rhs.version
            && lhs.canvas == rhs.canvas
            && lhs.meta == rhs.meta
            && lhs.elements == rhs.elements
            && lhs.assets.count == rhs.assets.count
            && lhs.assets.keys.allSatisfy { rhs.assets[$0] != nil }
    }

    func index(of id: UUID) -> Int? { elements.firstIndex { $0.id == id } }
    subscript(id: UUID) -> Element? {
        get { elements.first { $0.id == id } }
        set {
            guard let newValue, let i = index(of: id) else { return }
            elements[i] = newValue
        }
    }

    /// Assets no element points at any more.
    func orphanedAssetIDs() -> [String] {
        let used = Set(elements.compactMap(\.assetID))
        return assets.keys.filter { !used.contains($0) }
    }

    mutating func vacuum() {
        for id in orphanedAssetIDs() { assets.removeValue(forKey: id) }
    }

    func encoded() throws -> Data {
        var copy = self
        copy.vacuum()
        copy.meta.modified = Date()
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        return try enc.encode(copy)
    }

    static func decode(_ data: Data) throws -> PicPakDocument {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try dec.decode(PicPakDocument.self, from: data)
    }
}

enum DocumentError: LocalizedError {
    case notAPicPakDocument
    case tooNew(Int)
    case noEmbeddedProject
    case unreadableImage

    var errorDescription: String? {
        switch self {
        case .notAPicPakDocument: "That file isn't a PicPak Studio project."
        case .tooNew(let v): "This project was made with a newer version (format \(v))."
        case .noEmbeddedProject: "That PNG doesn't carry an editable PicPak project."
        case .unreadableImage: "That image couldn't be read."
        }
    }
}

enum AppInfo {
    static let version = "1.0"
}
