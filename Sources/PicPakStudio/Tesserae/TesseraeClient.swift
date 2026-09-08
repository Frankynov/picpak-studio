import Foundation

/// A panel registered with Tesserae.
struct TesseraeDevice: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let w: Int
    let h: Int
    var kind: String?
    var color_mode: String?
    var colors: [String]?
    var gamut: String?

    var isFourColour: Bool { gamut == "bwry_4" }
    var summary: String { "\(w)×\(h) · \(color_mode ?? kind ?? "panel")" }
}

struct PushOutcome {
    var sent: [String] = []
    var errors: [String] = []
}

enum TesseraeError: LocalizedError {
    case notConfigured
    case http(Int, String)
    case badResponse

    var errorDescription: String? {
        switch self {
        case .notConfigured: "Set the Tesserae address and token first."
        case .http(let code, let body):
            code == 401 || code == 403
                ? "Tesserae rejected the token (HTTP \(code))."
                : "Tesserae returned HTTP \(code). \(body.prefix(200))"
        case .badResponse: "Tesserae sent something this app couldn't read."
        }
    }
}

/// Thin client over Tesserae's `/api/mcp` surface — the same one the MCP bridge uses.
struct TesseraeClient {
    var base: URL
    var token: String

    private func request(_ method: String, _ path: String, body: Any? = nil) async throws -> Data {
        var url = base
        url.append(path: "api/mcp")
        // `path` may carry a query, so build it by hand rather than through append(path:).
        guard let composed = URL(string: url.absoluteString + path) else { throw TesseraeError.badResponse }

        var request = URLRequest(url: composed)
        request.httpMethod = method
        request.timeoutInterval = 30
        if !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw TesseraeError.badResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw TesseraeError.http(http.statusCode, String(decoding: data, as: UTF8.self))
        }
        return data
    }

    private func json(_ method: String, _ path: String, body: Any? = nil) async throws -> [String: Any] {
        let data = try await request(method, path, body: body)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TesseraeError.badResponse
        }
        return object
    }

    // MARK: - Calls

    func devices() async throws -> [TesseraeDevice] {
        let data = try await request("GET", "/devices")
        struct Wrapper: Decodable { let devices: [TesseraeDevice] }
        return try JSONDecoder().decode(Wrapper.self, from: data).devices
    }

    func pageExists(_ id: String) async -> Bool {
        (try? await json("GET", "/pages/\(id)/canvas")) != nil
    }

    func createPage(name: String, w: Int, h: Int) async throws -> String {
        let result = try await json("POST", "/pages", body: ["name": name, "w": w, "h": h])
        if let id = result["id"] as? String { return id }
        if let page = result["page"] as? [String: Any], let id = page["id"] as? String { return id }
        throw TesseraeError.badResponse
    }

    /// Replace the page with a single full-bleed code element holding our PNG.
    func setImageCanvas(pageID: String, name: String, w: Int, h: Int, pngBase64: String) async throws {
        let html = "<img id=\"art\" src=\"data:image/png;base64,\(pngBase64)\" alt=\"\">"
        let css = """
        html,body{margin:0;padding:0;background:#ffffff;}
        #art{position:absolute;left:0;top:0;width:\(w)px;height:\(h)px;\
        image-rendering:pixelated;image-rendering:crisp-edges;display:block;}
        """
        // set_canvas validates each element itself, so it needs an explicit id
        // (only add_element mints one for you). A fixed id keeps re-pushes in place.
        let element: [String: Any] = [
            "id": "picpakart", "kind": "code", "x": 0, "y": 0, "w": w, "h": h,
            "html": html, "css": css, "js": "",
            "dither": false, "autolibs": false, "visible": true
        ]
        let canvas: [String: Any] = [
            "name": name, "w": w, "h": h, "theme": "light", "els": [element]
        ]
        _ = try await json("PUT", "/pages/\(pageID)/canvas", body: canvas)
    }

    func bind(pageID: String, devices: [String]) async throws {
        _ = try await json("POST", "/pages/\(pageID)/devices", body: ["device_ids": devices])
    }

    func push(pageID: String, devices: [String]) async throws -> PushOutcome {
        let result = try await json("POST", "/pages/\(pageID)/push", body: ["device_ids": devices])
        var outcome = PushOutcome()
        outcome.sent = (result["sent"] as? [Any])?.map { "\($0)" } ?? []
        outcome.errors = (result["errors"] as? [Any])?.map { "\($0)" } ?? []
        return outcome
    }
}

// MARK: - Settings

/// Address and token are both kept in plain text in this app's preferences
/// (`~/Library/Preferences/com.picpak.studio.plist`).
///
/// This is a deliberate trade. The token started in the Keychain, which sounds
/// better but behaved worse: the app is ad-hoc signed, so its signature changes on
/// every build, the item's access control stops matching, and macOS asks for your
/// login password again — twice per push. There is no Keychain call left anywhere in
/// the app, which is the only way to be certain it can never prompt. The token is for
/// a server on your own LAN; the Settings window says plainly where it is stored.
@MainActor
final class TesseraeSettings: ObservableObject {
    static let shared = TesseraeSettings()

    private static let addressKey = "tesserae.address"
    private static let tokenKey = "tesserae.token"

    @Published var address: String {
        didSet { UserDefaults.standard.set(address, forKey: Self.addressKey) }
    }
    @Published var token: String {
        didSet { UserDefaults.standard.set(token, forKey: Self.tokenKey) }
    }

    private init() {
        let defaults = UserDefaults.standard
        // No default server: the Settings window prompts for one on first run.
        address = defaults.string(forKey: Self.addressKey) ?? ""
        token = defaults.string(forKey: Self.tokenKey) ?? ""
    }

    var isConfigured: Bool {
        !address.trimmingCharacters(in: .whitespaces).isEmpty
            && !token.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var preferencesPath: String {
        "~/Library/Preferences/com.picpak.studio.plist"
    }

    var client: TesseraeClient? {
        var text = address.trimmingCharacters(in: .whitespaces)
        if text.isEmpty { return nil }
        if !text.contains("://") { text = "http://" + text }
        if !text.hasSuffix("/") { text += "/" }
        guard let url = URL(string: text) else { return nil }
        return TesseraeClient(base: url, token: token)
    }
}
