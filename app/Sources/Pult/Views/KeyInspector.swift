import SwiftUI

/// Everything about the selected key: its art on the left of the window, its
/// settings here.
struct KeyInspector: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        ScrollView {
            if let slot = state.selectedKey {
                VStack(alignment: .leading, spacing: 16) {
                    let binding = keyBinding(slot)

                    Preview(key: binding.wrappedValue)

                    Group {
                        LabeledField(T("key.label")) {
                            TextField("", text: binding.label)
                                .textFieldStyle(.roundedBorder)
                        }

                        LabeledField(T("key.icon")) {
                            IconField(icon: binding.icon)
                        }

                        LabeledField(T("key.color")) {
                            ColorField(hex: binding.color, fallback: "#30363d")
                        }

                        LabeledField(T("key.iconColor")) {
                            ColorField(hex: binding.icon_color, fallback: nil)
                        }

                        LabeledField(T("key.textColor")) {
                            ColorField(hex: binding.text_color, fallback: nil)
                        }

                        LabeledField(T("key.animate")) {
                            Picker("", selection: binding.animate) {
                                Text(T("key.animate.none")).tag(KeyAnimation?.none)
                                ForEach(KeyAnimation.allCases) { value in
                                    Text(value.label).tag(KeyAnimation?.some(value))
                                }
                            }
                            .labelsHidden()
                        }
                    }

                    Divider()
                    ActionEditor(action: binding.action)

                    Button(role: .destructive) {
                        state.setKey(nil, at: slot)
                    } label: {
                        Label(T("key.clear"), systemImage: "trash")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glass)
                }
                .padding(16)
            } else {
                ContentUnavailableView(T("key.empty"), systemImage: "hand.tap")
                    .padding(.top, 60)
            }
        }
        .background(.ultraThinMaterial)
    }

    /// A binding straight into the configuration, so edits are live.
    private func keyBinding(_ slot: Int) -> Binding<Key> {
        Binding(
            get: { state.key(at: slot) ?? Key() },
            set: { state.setKey($0, at: slot) }
        )
    }
}

private struct Preview: View {
    @EnvironmentObject private var state: AppState
    let key: Key

    var body: some View {
        HStack {
            Spacer()
            ZStack {
                if let image = state.image(for: key, size: 180) {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .padding(4)
                }
            }
            .frame(width: 140, height: 140)
            .padding(6)
            .glassPanel(cornerRadius: 22)
            Spacer()
        }
    }
}

private struct LabeledField<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            content
        }
    }
}

private struct IconField: View {
    @Binding var icon: String?
    @State private var picking = false

    var body: some View {
        Button {
            picking = true
        } label: {
            HStack {
                IconThumb(name: icon, size: 22)
                Text(icon ?? T("key.icon.none"))
                    .lineLimit(1)
                Spacer()
                Image(systemName: "chevron.down").font(.caption)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.glass)
        .popover(isPresented: $picking, arrowEdge: .bottom) {
            IconPicker(selection: $icon, dismiss: { picking = false })
        }
    }
}

/// A colour well that can also mean "let the daemon choose".
private struct ColorField: View {
    @Binding var hex: String?
    /// Shown as the placeholder when nothing is set.
    let fallback: String?

    var body: some View {
        HStack(spacing: 8) {
            ColorPicker("", selection: Binding(
                get: { Color(hex: hex ?? fallback ?? "#808080") },
                set: { hex = $0.hexString }
            ), supportsOpacity: false)
            .labelsHidden()

            TextField("", text: Binding(
                get: { hex ?? "" },
                set: { hex = $0.isEmpty ? nil : $0 }
            ), prompt: Text(fallback ?? T("key.auto")))
            .textFieldStyle(.roundedBorder)
            .font(.callout.monospaced())

            if hex != nil {
                Button {
                    hex = nil
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .buttonStyle(.borderless)
                .help(T("key.auto"))
            }
        }
    }
}

extension Color {
    init(hex: String) {
        var text = hex.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("#") { text.removeFirst() }
        if text.count == 3 {
            text = text.map { "\($0)\($0)" }.joined()
        }
        let value = UInt64(text, radix: 16) ?? 0x808080
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }

    var hexString: String {
        let color = NSColor(self).usingColorSpace(.sRGB) ?? .gray
        return String(
            format: "#%02x%02x%02x",
            Int(round(color.redComponent * 255)),
            Int(round(color.greenComponent * 255)),
            Int(round(color.blueComponent * 255))
        )
    }
}
