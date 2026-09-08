import SwiftUI
import AppKit

/// The app's Settings window (⌘,). Connection details live here rather than only in
/// the Push sheet, so they can be set up once and forgotten.
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsPane()
                .tabItem { Label("General", systemImage: "gearshape") }
            EditorSettingsPane()
                .tabItem { Label("Editor", systemImage: "ruler") }
            TesseraeSettingsPane()
                .tabItem { Label("Panels", systemImage: "dot.radiowaves.up.forward") }
        }
        .frame(width: 460)
        .padding(.top, 6)
    }
}

private struct GeneralSettingsPane: View {
    @ObservedObject private var updates = UpdateChecker.shared

    var body: some View {
        Form {
            Section {
                LabeledContent("Installed", value: updates.currentVersion)
                Toggle("Check for updates automatically", isOn: $updates.checksAutomatically)
                HStack(spacing: 8) {
                    Button("Check Now") { Task { await updates.check(manual: true) } }
                        .disabled(updates.state == .checking)
                    switch updates.state {
                    case .checking:
                        ProgressView().controlSize(.small)
                    case .upToDate:
                        Label("Up to date", systemImage: "checkmark.circle.fill")
                            .font(.caption).foregroundStyle(.green)
                    case .failed(let message):
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(PPColor.red.color).lineLimit(2)
                    case .idle:
                        EmptyView()
                    }
                    Spacer()
                }
            } header: {
                Text("Version")
            } footer: {
                Text("Asks GitHub once a day whether a newer release exists, and tells you. "
                     + "It never installs anything on its own. Turning this off means no "
                     + "network request is made unless you press Check Now.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            }
        }
        .formStyle(.grouped)
        .frame(height: 300)
    }
}

private struct TesseraeSettingsPane: View {
    @StateObject private var settings = TesseraeSettings.shared
    @State private var probe: Probe = .idle

    private enum Probe: Equatable {
        case idle, checking, ok(Int), failed(String)
    }

    var body: some View {
        Form {
            Section {
                TextField("Address", text: $settings.address, prompt: Text("http://host:8766"))
                    .font(.system(size: 11, design: .monospaced))
                SecureField("MCP token", text: $settings.token)
                    .font(.system(size: 11, design: .monospaced))
            } header: {
                Text("Tesserae server")
            } footer: {
                Label {
                    Text("The token is stored in plain text in \(settings.preferencesPath), "
                         + "readable by anything running as you. That's the trade for never "
                         + "being asked for your macOS password when you push.")
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(PPColor.yellow.color)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
            }

            Section {
                HStack(spacing: 8) {
                    Button("Test Connection") { Task { await test() } }
                        .disabled(!settings.isConfigured || probe == .checking)
                    switch probe {
                    case .idle:
                        EmptyView()
                    case .checking:
                        ProgressView().controlSize(.small)
                    case .ok(let count):
                        Label("Reached the server — \(count) panel\(count == 1 ? "" : "s")",
                              systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    case .failed(let message):
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(PPColor.red.color)
                            .lineLimit(3)
                            .textSelection(.enabled)
                    }
                    Spacer()
                }
                .font(.caption)
            }
        }
        .formStyle(.grouped)
        .frame(height: 300)
    }

    private func test() async {
        guard let client = settings.client else { return }
        probe = .checking
        do {
            probe = .ok(try await client.devices().count)
        } catch {
            probe = .failed(error.localizedDescription)
        }
    }
}

private struct EditorSettingsPane: View {
    @StateObject private var store = Store.shared

    var body: some View {
        Form {
            Section("Canvas") {
                Toggle("Rulers", isOn: $store.showRulers)
                Toggle("Grid", isOn: $store.showGrid)
                Toggle("Snap to guides", isOn: $store.snapEnabled)
                Toggle("Bezel margin", isOn: $store.showBleedGuides)
            }
            Section("Grid") {
                Stepper(value: $store.gridSize, in: 2...50, step: 1) {
                    Text("Spacing: \(Int(store.gridSize)) px")
                }
            }
        }
        .formStyle(.grouped)
        .frame(height: 300)
    }
}
