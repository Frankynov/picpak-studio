import SwiftUI

/// The only colour control in the app: four flat swatches and, optionally, "none".
struct PaintPicker: View {
    let label: String
    @Binding var value: PPColor?
    var allowsNone = true
    var onBegin: () -> Void = {}

    var body: some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 58, alignment: .leading)
            HStack(spacing: 4) {
                if allowsNone {
                    swatch(nil)
                }
                ForEach(PPColor.allCases) { colour in
                    swatch(colour)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func swatch(_ colour: PPColor?) -> some View {
        let selected = value == colour
        return Button {
            onBegin()
            value = colour
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 4)
                    .fill(colour?.color ?? Color(nsColor: .textBackgroundColor))
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Color.primary.opacity(0.25), lineWidth: 0.5)
                if colour == nil {
                    Path { p in
                        p.move(to: CGPoint(x: 4, y: 18)); p.addLine(to: CGPoint(x: 18, y: 4))
                    }
                    .stroke(Color.red, lineWidth: 1.5)
                }
                if selected {
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.accentColor, lineWidth: 2.5)
                        .padding(-2)
                }
            }
            .frame(width: 22, height: 22)
        }
        .buttonStyle(.plain)
        .help(colour?.label ?? "None")
    }
}

/// Compact numeric field that commits on return or focus loss.
struct NumberField: View {
    let label: String
    @Binding var value: Double
    var range: ClosedRange<Double> = -10_000...10_000
    var step: Double = 1
    var suffix: String = ""
    var onBegin: () -> Void = {}

    @State private var text: String = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 16, alignment: .leading)
            TextField("", text: $text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11, design: .monospaced))
                .multilineTextAlignment(.trailing)
                .focused($focused)
                .onSubmit(commit)
                .onChange(of: focused) { _, isFocused in if !isFocused { commit() } }
            Stepper("") {
                onBegin(); value = clamp(value + step); sync()
            } onDecrement: {
                onBegin(); value = clamp(value - step); sync()
            }
            .labelsHidden()
        }
        .onAppear(perform: sync)
        .onChange(of: value) { _, _ in if !focused { sync() } }
    }

    private func clamp(_ v: Double) -> Double { min(max(v, range.lowerBound), range.upperBound) }

    private func sync() {
        text = value == value.rounded() ? String(Int(value.rounded())) : String(format: "%.1f", value)
    }

    private func commit() {
        guard let parsed = Double(text.replacingOccurrences(of: ",", with: ".")) else { sync(); return }
        onBegin()
        value = clamp(parsed)
        sync()
    }
}

struct SliderRow: View {
    let label: String
    @Binding var value: Double
    var range: ClosedRange<Double>
    var format: String = "%.2f"
    var onBegin: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack {
                Text(label).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(String(format: format, value))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range) { editing in if editing { onBegin() } }
                .controlSize(.mini)
        }
    }
}

struct InspectorSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .kerning(0.6)
            content
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        Divider()
    }
}

struct SegmentedIcons<T: Hashable>: View {
    let options: [(value: T, symbol: String, help: String)]
    @Binding var selection: T
    var onBegin: () -> Void = {}

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.value) { option in
                Button {
                    onBegin()
                    selection = option.value
                } label: {
                    Image(systemName: option.symbol)
                        .frame(width: 26, height: 20)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(selection == option.value ? Color.accentColor : Color.clear))
                        .foregroundStyle(selection == option.value ? Color.white : Color.primary)
                }
                .buttonStyle(.plain)
                .help(option.help)
            }
        }
    }
}
