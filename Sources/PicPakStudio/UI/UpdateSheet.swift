import SwiftUI

/// Shown when a newer release exists. It offers the download page rather than
/// installing anything, so there is no surprise replacement of a running app.
struct UpdateSheet: View {
    let release: ReleaseInfo
    @ObservedObject private var checker = UpdateChecker.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.title)
                    .foregroundStyle(PPColor.red.color)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(release.title) is available")
                        .font(.headline)
                    Text("You have \(checker.currentVersion).")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(16)
            Divider()

            ScrollView {
                Text(notes)
                    .font(.system(size: 11))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
            }
            .frame(height: 240)

            Divider()
            HStack {
                Button("Skip This Version") {
                    checker.skip(release)
                    dismiss()
                }
                Spacer()
                Button("Later") {
                    checker.dismiss()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button("Download…") {
                    checker.openDownloadPage(release)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(14)
        }
        .frame(width: 520)
    }

    /// Release notes are Markdown; strip the heading marks so they read as plain text
    /// rather than rendering as literal hashes.
    private var notes: String {
        let cleaned = release.notes
            .replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                var text = String(line)
                while text.hasPrefix("#") { text.removeFirst() }
                return text.trimmingCharacters(in: .whitespaces)
            }
            .joined(separator: "\n")
        return cleaned.isEmpty ? "No release notes." : cleaned
    }
}
