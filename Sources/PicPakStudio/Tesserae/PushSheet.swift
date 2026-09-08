import SwiftUI

struct PushSheet: View {
    @EnvironmentObject var store: Store
    @StateObject private var settings = TesseraeSettings.shared
    @Environment(\.dismiss) private var dismiss

    @State private var devices: [TesseraeDevice] = []
    @State private var chosen: Set<String> = []
    @State private var status: Status = .idle
    @State private var log: String = ""

    private enum Status: Equatable {
        case idle, connecting, ready, pushing, done(String), failed(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            HStack(alignment: .top, spacing: 16) {
                preview
                VStack(alignment: .leading, spacing: 12) {
                    connection
                    deviceList
                }
            }
            .padding(16)

            Divider()
            footer
        }
        .frame(width: 640)
        .task { await connect() }
    }

    // MARK: - Pieces

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "dot.radiowaves.up.forward")
                .font(.title3)
                .foregroundStyle(PPColor.red.color)
            VStack(alignment: .leading, spacing: 1) {
                Text("Push to a panel").font(.headline)
                Text("Tesserae renders the page once and sends it to each panel you pick.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(16)
    }

    private var preview: some View {
        VStack(spacing: 6) {
            Group {
                if let image = Exporter.panelImage(store.doc, quantize: true, dither: .none) {
                    Image(decorative: image, scale: 1, orientation: .up)
                        .resizable()
                        .interpolation(.none)
                        .frame(width: 240, height: 240 * store.doc.canvas.h / store.doc.canvas.w)
                }
            }
            .overlay(Rectangle().stroke(Color.secondary.opacity(0.4)))
            Text("Exactly what the panel receives")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var connection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("TESSERAE").font(.system(size: 10, weight: .semibold)).kerning(0.6)
                    .foregroundStyle(.secondary)
                Spacer()
                SettingsLink { Text("Settings…").font(.caption) }
                    .buttonStyle(.link)
            }
            Text(settings.address)
                .font(.system(size: 11, design: .monospaced))
                .lineLimit(1).truncationMode(.middle)
                .foregroundStyle(.secondary)
            if !settings.isConfigured {
                Text("Set the address and MCP token in Settings first.")
                    .font(.caption).foregroundStyle(PPColor.red.color)
            }
            HStack(spacing: 8) {
                Button("Connect") { Task { await connect() } }
                    .controlSize(.small)
                    .disabled(!settings.isConfigured)
                statusLabel
            }
        }
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch status {
        case .idle:
            EmptyView()
        case .connecting:
            HStack(spacing: 5) {
                ProgressView().controlSize(.small)
                Text("Connecting…").font(.caption).foregroundStyle(.secondary)
            }
        case .ready:
            Label("\(devices.count) panels", systemImage: "checkmark.circle.fill")
                .font(.caption).foregroundStyle(.green)
        case .pushing:
            HStack(spacing: 5) {
                ProgressView().controlSize(.small)
                Text("Sending…").font(.caption).foregroundStyle(.secondary)
            }
        case .done(let message):
            Label(message, systemImage: "checkmark.circle.fill")
                .font(.caption).foregroundStyle(.green).lineLimit(2)
        case .failed(let message):
            ScrollView {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(PPColor.red.color)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 70)
        }
    }

    private var deviceList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("PANELS").font(.system(size: 10, weight: .semibold)).kerning(0.6)
                .foregroundStyle(.secondary)
            if devices.isEmpty {
                Text("No panels yet — connect above.")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(height: 100, alignment: .top)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(devices) { device in
                            deviceRow(device)
                        }
                    }
                }
                .frame(height: 132)
            }
        }
    }

    private func deviceRow(_ device: TesseraeDevice) -> some View {
        let fits = device.w == Int(store.doc.canvas.w) && device.h == Int(store.doc.canvas.h)
        return Toggle(isOn: Binding(
            get: { chosen.contains(device.id) },
            set: { on in if on { chosen.insert(device.id) } else { chosen.remove(device.id) } })) {
            HStack(spacing: 6) {
                Text(device.name).font(.system(size: 11, weight: .medium))
                Text(device.summary).font(.system(size: 10)).foregroundStyle(.secondary)
                if !fits {
                    Text("resized by server")
                        .font(.system(size: 9))
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(Capsule().fill(PPColor.yellow.color))
                        .foregroundStyle(.black)
                }
                if device.isFourColour {
                    Circle().fill(PPColor.red.color).frame(width: 6, height: 6)
                }
            }
        }
        .toggleStyle(.checkbox)
    }

    private var footer: some View {
        HStack {
            if !log.isEmpty {
                Text(log).font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            Button {
                Task { await push() }
            } label: {
                Label(chosen.isEmpty
                      ? "Select a panel"
                      : "Send to \(chosen.count) panel\(chosen.count == 1 ? "" : "s")",
                      systemImage: "paperplane.fill")
            }
            .keyboardShortcut(.defaultAction)
            .disabled(chosen.isEmpty || status == .pushing)
        }
        .padding(16)
    }

    // MARK: - Work

    private func connect() async {
        guard let client = settings.client else {
            status = .failed(TesseraeError.notConfigured.localizedDescription)
            return
        }
        status = .connecting
        do {
            let found = try await client.devices()
            devices = found.sorted { $0.name < $1.name }
            // Only the panels this document was last pushed to. Pre-selecting every
            // matching panel meant one careless Send repainted the whole house.
            if chosen.isEmpty {
                chosen = Set(store.doc.meta.deviceIDs).intersection(Set(devices.map(\.id)))
            }
            status = .ready
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    private func push() async {
        guard let client = settings.client else { return }
        status = .pushing
        log = ""
        let targets = Array(chosen)
        let canvas = store.doc.canvas
        let width = Int(canvas.w.rounded()), height = Int(canvas.h.rounded())
        let name = "PicPak Studio — " + FileActions.defaultName(store)

        do {
            let base64 = try Exporter.panelPNGBase64(store.doc)

            // Reuse this document's own page so repeated pushes don't pile up pages.
            var pageID = store.doc.meta.pageID
            if let existing = pageID, await !client.pageExists(existing) { pageID = nil }
            if pageID == nil {
                pageID = try await client.createPage(name: name, w: width, h: height)
                log = "Created page \(pageID ?? "?")"
            }
            guard let pageID else { throw TesseraeError.badResponse }

            try await client.setImageCanvas(pageID: pageID, name: name,
                                            w: width, h: height, pngBase64: base64)
            try await client.bind(pageID: pageID, devices: targets)
            let outcome = try await client.push(pageID: pageID, devices: targets)

            store.doc.meta.pageID = pageID
            store.doc.meta.deviceIDs = targets
            store.touch()

            if outcome.errors.isEmpty {
                status = .done("Sent to \(outcome.sent.count) panel\(outcome.sent.count == 1 ? "" : "s")")
                store.flash("Pushed to \(outcome.sent.count) panel\(outcome.sent.count == 1 ? "" : "s")")
            } else {
                status = .failed(outcome.errors.joined(separator: "; "))
            }
            log = "Page \(pageID) · \(base64.count / 1024) KB image"
        } catch {
            status = .failed(error.localizedDescription)
        }
    }
}
