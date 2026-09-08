import Foundation
import AppKit

/// A dotted version, compared numerically rather than as text — otherwise "1.10"
/// sorts before "1.9". Leading "v" and any suffix ("1.2-beta") are ignored.
struct AppVersion: Comparable, CustomStringConvertible {
    let parts: [Int]
    let description: String

    init?(_ raw: String) {
        var text = raw.trimmingCharacters(in: .whitespaces)
        if text.lowercased().hasPrefix("v") { text.removeFirst() }
        let core = text.split(whereSeparator: { $0 == "-" || $0 == "+" }).first.map(String.init) ?? text
        let fields = core.split(separator: ".", omittingEmptySubsequences: false)
        guard !fields.isEmpty else { return nil }
        var numbers: [Int] = []
        for field in fields {
            guard let value = Int(field), value >= 0 else { return nil }
            numbers.append(value)
        }
        parts = numbers
        description = core
    }

    static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        for i in 0..<max(lhs.parts.count, rhs.parts.count) {
            let l = i < lhs.parts.count ? lhs.parts[i] : 0
            let r = i < rhs.parts.count ? rhs.parts[i] : 0
            if l != r { return l < r }
        }
        return false
    }

    static func == (lhs: AppVersion, rhs: AppVersion) -> Bool {
        !(lhs < rhs) && !(rhs < lhs)
    }
}

struct ReleaseInfo: Equatable, Identifiable {
    var id: String { version.description }
    var version: AppVersion
    var title: String
    var notes: String
    var pageURL: URL

    static func == (lhs: ReleaseInfo, rhs: ReleaseInfo) -> Bool {
        lhs.version == rhs.version && lhs.pageURL == rhs.pageURL
    }
}

/// Asks GitHub whether a newer release exists. It never installs anything — it points
/// you at the download and gets out of the way. Deliberately not Sparkle: that would
/// mean a signing key to keep safe forever and an appcast to regenerate every release,
/// which is a lot of standing obligation for a tool this size.
@MainActor
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()

    enum State: Equatable {
        case idle, checking, upToDate, failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published var available: ReleaseInfo?

    @Published var checksAutomatically: Bool {
        didSet { UserDefaults.standard.set(checksAutomatically, forKey: Keys.automatic) }
    }

    private enum Keys {
        static let automatic = "updates.checkAutomatically"
        static let skipped = "updates.skippedVersion"
        static let lastCheck = "updates.lastCheck"
    }

    private init() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: Keys.automatic) == nil { defaults.set(true, forKey: Keys.automatic) }
        checksAutomatically = defaults.bool(forKey: Keys.automatic)
    }

    var currentVersion: String { AppInfo.version }

    /// Called at launch. Silent about failures — an offline laptop shouldn't produce a
    /// dialog — and throttled so it asks GitHub at most once a day.
    func checkInBackground() async {
        guard checksAutomatically else { return }
        let last = UserDefaults.standard.object(forKey: Keys.lastCheck) as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) > 60 * 60 * 24 else { return }
        await check(manual: false)
    }

    func check(manual: Bool) async {
        state = .checking
        do {
            let release = try await fetchLatest()
            UserDefaults.standard.set(Date(), forKey: Keys.lastCheck)

            guard let current = AppVersion(AppInfo.version) else {
                state = manual ? .failed("This build has no readable version number.") : .idle
                return
            }
            guard current < release.version else {
                state = .upToDate
                return
            }
            if !manual, skipped == release.version.description {
                state = .idle
                return
            }
            available = release
            state = .idle
        } catch {
            // Only bother the user when they asked.
            state = manual ? .failed(error.localizedDescription) : .idle
        }
    }

    private var skipped: String? { UserDefaults.standard.string(forKey: Keys.skipped) }

    func skip(_ release: ReleaseInfo) {
        UserDefaults.standard.set(release.version.description, forKey: Keys.skipped)
        available = nil
    }

    func dismiss() { available = nil }

    func openDownloadPage(_ release: ReleaseInfo) {
        NSWorkspace.shared.open(release.pageURL)
        available = nil
    }

    // MARK: - Networking

    enum UpdateError: LocalizedError {
        case badResponse(Int)
        case unreadable

        var errorDescription: String? {
            switch self {
            case .badResponse(let code) where code == 403:
                "GitHub is rate-limiting this network right now. Try again later."
            case .badResponse(let code):
                "GitHub returned HTTP \(code)."
            case .unreadable:
                "GitHub's reply couldn't be read."
            }
        }
    }

    private func fetchLatest() async throws -> ReleaseInfo {
        let url = URL(string: "https://api.github.com/repos/\(AppInfo.repository)/releases/latest")!
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("PicPakStudio/\(AppInfo.version)", forHTTPHeaderField: "User-Agent")
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw UpdateError.unreadable }
        guard http.statusCode == 200 else { throw UpdateError.badResponse(http.statusCode) }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = object["tag_name"] as? String,
              let version = AppVersion(tag),
              let page = object["html_url"] as? String,
              let pageURL = URL(string: page)
        else { throw UpdateError.unreadable }

        return ReleaseInfo(
            version: version,
            title: (object["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? tag,
            notes: (object["body"] as? String) ?? "",
            pageURL: pageURL)
    }
}
