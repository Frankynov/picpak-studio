import SwiftUI
import AppKit

/// Every SF Symbol the running system knows about, read from CoreGlyphs.
enum SymbolCatalog {
    private static let resources =
        "/System/Library/CoreServices/CoreGlyphs.bundle/Contents/Resources"

    /// Localised variants (`.ar`, `.hi`, …) only clutter a picker for a price tag.
    private static let localeSuffixes: Set<String> = [
        "ar", "hi", "he", "ja", "ko", "th", "zh", "cy", "gu", "kn", "ml", "mr",
        "or", "pa", "si", "ta", "te", "ur", "am", "km", "my", "ru", "el", "hy",
        "ka", "lo", "bn", "as", "sat", "csl", "ase", "gcs", "jcs", "kcs"
    ]

    static let all: [String] = {
        let url = URL(fileURLWithPath:
            "/System/Library/CoreServices/CoreGlyphs.bundle/Contents/Resources/name_availability.plist")
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dict = plist as? [String: Any],
              let symbols = dict["symbols"] as? [String: String]
        else { return fallback }

        let names = symbols.keys.filter { name in
            let parts = name.split(separator: ".").map(String.init)
            if parts.contains(where: { localeSuffixes.contains($0) }) { return false }
            return NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil
        }
        return sortedByAppleOrder(names)
    }()

    /// Apple ships the ordering its own SF Symbols app uses; alphabetical puts
    /// `0.circle` and friends first, which is a useless way to open a picker.
    private static let ranking: [String: Int] = {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: resources + "/symbol_order.plist")),
              let order = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String]
        else { return [:] }
        return Dictionary(uniqueKeysWithValues: order.enumerated().map { ($0.element, $0.offset) })
    }()

    static func sortedByAppleOrder<S: Sequence<String>>(_ names: S) -> [String] {
        names.sorted { a, b in
            let ra = ranking[a] ?? Int.max, rb = ranking[b] ?? Int.max
            return ra == rb ? a < b : ra < rb
        }
    }

    /// If the plist ever moves, a small hand-picked set keeps the picker useful.
    private static let fallback = [
        "star.fill", "heart.fill", "tag.fill", "cart.fill", "leaf.fill", "flame.fill",
        "bolt.fill", "checkmark.circle.fill", "xmark.circle.fill", "exclamationmark.triangle.fill",
        "arrow.right", "arrow.left", "arrow.up", "arrow.down", "clock.fill", "calendar",
        "sun.max.fill", "cloud.fill", "snowflake", "drop.fill", "wifi", "battery.100",
        "house.fill", "person.fill", "bag.fill", "gift.fill", "percent", "eurosign.circle.fill"
    ]

    /// Browsable categories, straight from CoreGlyphs. The picker is far easier to
    /// use by category than by guessing a name, so this is the default view.
    struct Category: Identifiable, Hashable {
        let key: String
        let icon: String
        var id: String { key }
        var label: String { Category.labels[key] ?? key.capitalized }

        static let labels: [String: String] = [
            "all": "All", "whatsnew": "What's New", "multicolor": "Multicolour",
            "objectsandtools": "Objects & Tools", "cameraandphotos": "Camera & Photos",
            "privacyandsecurity": "Privacy & Security", "textformatting": "Text Formatting",
            "communication": "Communication", "connectivity": "Connectivity",
            "transportation": "Transport", "automotive": "Automotive",
            "accessibility": "Accessibility", "editing": "Editing", "devices": "Devices",
            "commerce": "Commerce", "weather": "Weather", "gaming": "Gaming",
            "shapes": "Shapes", "arrows": "Arrows", "indices": "Indices",
            "nature": "Nature", "health": "Health", "fitness": "Fitness",
            "human": "People", "home": "Home", "maps": "Maps", "media": "Media",
            "time": "Time", "math": "Maths", "draw": "Drawing", "keyboard": "Keyboard",
            "variable": "Variable"
        ]
    }

    static let categories: [Category] = {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: resources + "/categories.plist")),
              let list = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [[String: String]]
        else { return [Category(key: "all", icon: "square.grid.2x2")] }
        // "variable" and "multicolor" describe rendering modes, not subject matter.
        let skip: Set<String> = ["variable", "multicolor", "whatsnew"]
        return list.compactMap { entry in
            guard let key = entry["key"], !skip.contains(key) else { return nil }
            return Category(key: key, icon: entry["icon"] ?? "square")
        }
    }()

    private static let membership: [String: [String]] = {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: resources + "/symbol_categories.plist")),
              let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: [String]]
        else { return [:] }
        return dict
    }()

    static func inCategory(_ key: String) -> [String] {
        guard key != "all" else { return all }
        let names = Set(all)
        return sortedByAppleOrder(membership.filter { $0.value.contains(key) && names.contains($0.key) }.keys)
    }

    static func search(_ query: String) -> [String] {
        let trimmed = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !trimmed.isEmpty else { return Array(all.prefix(600)) }
        let terms = trimmed.split(separator: " ").map(String.init)
        let hits = all.filter { name in terms.allSatisfy { name.contains($0) } }
        // Whole-word prefix matches feel more like what you meant.
        return Array(hits.sorted { a, b in
            let aExact = a.hasPrefix(trimmed), bExact = b.hasPrefix(trimmed)
            if aExact != bExact { return aExact }
            if a.count != b.count { return a.count < b.count }
            return a < b
        }.prefix(600))
    }
}

/// Browse by category, or search. Every tile carries its name — a wall of unlabelled
/// glyphs is impossible to choose from, and the name is what you end up needing anyway.
struct SymbolPicker: View {
    @Binding var selection: String
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var category = "all"
    @State private var results: [String] = []

    private let columns = [GridItem(.adaptive(minimum: 76, maximum: 76), spacing: 8)]
    private var searching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        HSplitView {
            categorySidebar
            VStack(spacing: 0) {
                searchBar
                Divider()
                grid
                Divider()
                footer
            }
            .frame(minWidth: 430)
        }
        .frame(width: 660, height: 500)
        .onAppear(perform: refresh)
        .onChange(of: query) { _, _ in refresh() }
        .onChange(of: category) { _, _ in refresh() }
    }

    private var categorySidebar: some View {
        List(selection: $category) {
            ForEach(SymbolCatalog.categories) { item in
                Label(item.label, systemImage: item.icon)
                    .font(.system(size: 11))
                    .tag(item.key)
            }
        }
        .listStyle(.sidebar)
        .frame(width: 178)
        .disabled(searching)
        .opacity(searching ? 0.45 : 1)
    }

    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search all \(SymbolCatalog.all.count) symbols", text: $query)
                .textFieldStyle(.plain)
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
            }
        }
        .padding(10)
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(results, id: \.self) { name in
                    Button { selection = name } label: { tile(name) }
                        .buttonStyle(.plain)
                        .help(name)
                }
            }
            .padding(10)
        }
    }

    private func tile(_ name: String) -> some View {
        let chosen = name == selection
        return VStack(spacing: 3) {
            Image(systemName: name)
                .font(.system(size: 21))
                .frame(height: 26)
            Text(name)
                .font(.system(size: 8))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(height: 20, alignment: .top)
        }
        .frame(width: 72, height: 58)
        .background(RoundedRectangle(cornerRadius: 6)
            .fill(chosen ? Color.accentColor.opacity(0.22) : Color.primary.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 6)
            .stroke(chosen ? Color.accentColor : .clear, lineWidth: 2))
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if !selection.isEmpty {
                Image(systemName: selection)
                Text(selection).font(.system(size: 11, design: .monospaced)).lineLimit(1)
            }
            Spacer()
            Text("\(results.count)").font(.caption).foregroundStyle(.secondary)
            Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
        }
        .padding(10)
    }

    private func refresh() {
        results = searching ? SymbolCatalog.search(query) : SymbolCatalog.inCategory(category)
    }
}

/// Families are listed in their own typeface — for choosing a face, that *is* the preview.
struct FontPicker: View {
    @Binding var selection: String        // "" means the system face
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var matches: [String] {
        let trimmed = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !trimmed.isEmpty else { return FontResolver.availableFamilies }
        return FontResolver.availableFamilies.filter { $0.lowercased().contains(trimmed) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search \(FontResolver.availableFamilies.count) families", text: $query)
                    .textFieldStyle(.plain)
            }
            .padding(9)
            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    row(family: "", label: "System")
                    Divider().padding(.vertical, 3)
                    ForEach(matches, id: \.self) { row(family: $0, label: $0) }
                }
                .padding(.vertical, 4)
            }
        }
        .frame(width: 300, height: 380)
    }

    private func row(family: String, label: String) -> some View {
        let chosen = selection == family
        return Button {
            selection = family
            dismiss()
        } label: {
            HStack(spacing: 6) {
                Text(label)
                    .font(preview(for: family))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                if chosen {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(chosen ? Color.accentColor.opacity(0.14) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func preview(for family: String) -> Font {
        guard !family.isEmpty,
              let name = FontResolver.postScriptName(family: family, weight: .regular)
        else { return .system(size: 15) }
        return .custom(name, fixedSize: 15)
    }
}
