import SwiftUI
import AppKit

/// The app's Settings window (⌘,). Connection details live here rather than only in
/// the Push sheet, so they can be set up once and forgotten.
struct SettingsView: View {
    var body: some View {
        TabView {
            TesseraeSettingsPane()
                .tabItem { Label("Panels", systemImage: "dot.radiowaves.up.forward") }
            EditorSettingsPane()
                .tabItem { Label("Editor", systemImage: "ruler") }
        }
        .frame(width: 460)
        .padding(.top, 6)
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
