import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// Private to the app: dragging a key between slots.
    static let pultKeySlot = UTType(exportedAs: "dev.pult.keyslot")
}

/// Edits whatever control is selected on the dock panel.
struct Inspector: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                switch state.selection {
                case .key(let slot):
                    KeyEditor(slot: slot)
                case .knob(let index, let part):
                    KnobEditor(index: index, part: part)
                case .button(let index):
                    ButtonEditor(index: index)
                case nil:
                    Hint()
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(.ultraThinMaterial)
    }
}

private struct Hint: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "hand.tap")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.tertiary)
            Text(T("inspector.hint"))
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 70)
    }
}

// MARK: - Key

private struct KeyEditor: View {
    @EnvironmentObject private var state: AppState
    let slot: Int

    private var key: Binding<Key> {
        Binding(
            get: { state.key(at: slot) ?? Key() },
            set: { state.setKey($0, at: slot) }
        )
    }

    var body: some View {
        Header(title: T("key.title"), subtitle: "\(slot + 1)")

        KeyPreview(key: key.wrappedValue)

        Field(T("key.label")) {
            TextField("", text: key.label)
                .textFieldStyle(.roundedBorder)
        }

        Field(T("key.icon")) {
            IconField(icon: key.icon)
        }

        HStack(spacing: 10) {
            Field(T("key.color")) { ColorField(hex: key.color, fallback: "#30363d") }
            Field(T("key.iconColor")) { ColorField(hex: key.icon_color, fallback: nil) }
        }

        Field(T("key.textColor")) { ColorField(hex: key.text_color, fallback: nil) }

        Field(T("key.animate")) {
            Picker("", selection: key.animate) {
                Text(T("key.animate.none")).tag(KeyAnimation?.none)
                ForEach(KeyAnimation.allCases) { value in
                    Label(value.label, systemImage: symbol(for: value))
                        .tag(KeyAnimation?.some(value))
                }
            }
            .labelsHidden()
        }

        Divider().padding(.vertical, 4)

        ActionEditor(action: key.action)

        Button(role: .destructive) {
            state.setKey(nil, at: slot)
        } label: {
            Label(T("key.clear"), systemImage: "eraser")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.glass)
        .padding(.top, 6)
    }

    private func symbol(for animation: KeyAnimation) -> String {
        switch animation {
        case .pulse: return "waveform.path"
        case .spin: return "arrow.triangle.2.circlepath"
        case .blink: return "light.beacon.max"
        }
    }
}

private struct KeyPreview: View {
    @EnvironmentObject private var state: AppState
    let key: Key

    var body: some View {
        HStack {
            Spacer()
            ZStack {
                RoundedRectangle(cornerRadius: 18).fill(.black.opacity(0.3))
                if let image = state.image(for: key, size: 160) {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 15))
                        .padding(3)
                }
            }
            .frame(width: 132, height: 132)
            .shadow(color: .black.opacity(0.3), radius: 8, y: 3)
            Spacer()
        }
        .padding(.bottom, 4)
        .task(id: key) { state.prefetch([key], size: 160) }
    }
}

// MARK: - Knob and button

private struct KnobEditor: View {
    @EnvironmentObject private var state: AppState
    let index: Int
    let part: Knob.Part

    var body: some View {
        Header(title: T("encoder.\(index)"), subtitle: nil)

        Picker("", selection: Binding(
            get: { part },
            set: { state.selection = .knob(index, $0) }
        )) {
            Text(T("encoder.ccw")).tag(Knob.Part.ccw)
            Text(T("encoder.cw")).tag(Knob.Part.cw)
            Text(T("encoder.press")).tag(Knob.Part.press)
        }
        .labelsHidden()
        .pickerStyle(.segmented)

        ActionEditor(action: binding(for: part))
    }

    private func binding(for part: Knob.Part) -> Binding<Action> {
        Binding(
            get: {
                let encoders = state.scene?.encoders ?? []
                guard index < encoders.count else { return Action() }
                switch part {
                case .cw: return encoders[index].cw
                case .ccw: return encoders[index].ccw
                case .press: return encoders[index].press
                }
            },
            set: { value in
                guard let name = state.selectedScene else { return }
                state.updateScene(name) { scene in
                    while scene.encoders.count <= index { scene.encoders.append(Knob()) }
                    switch part {
                    case .cw: scene.encoders[index].cw = value
                    case .ccw: scene.encoders[index].ccw = value
                    case .press: scene.encoders[index].press = value
                    }
                }
            }
        )
    }
}

private struct ButtonEditor: View {
    @EnvironmentObject private var state: AppState
    let index: Int

    var body: some View {
        Header(title: String(format: T("button.n"), "\(index + 1)"), subtitle: nil)
        ActionEditor(action: Binding(
            get: {
                let buttons = state.scene?.buttons ?? []
                return index < buttons.count ? buttons[index] : Action()
            },
            set: { value in
                guard let name = state.selectedScene else { return }
                state.updateScene(name) { scene in
                    while scene.buttons.count <= index { scene.buttons.append(Action()) }
                    scene.buttons[index] = value
                }
            }
        ))
    }
}

// MARK: - Pieces

private struct Header: View {
    let title: String
    let subtitle: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title).font(.title3.weight(.semibold))
            if let subtitle {
                Text(subtitle)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            Spacer()
        }
    }
}

struct Field<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct IconField: View {
    @EnvironmentObject private var state: AppState
    @Binding var icon: String?
    @State private var picking = false

    var body: some View {
        Button {
            picking = true
        } label: {
            HStack(spacing: 8) {
                IconThumb(name: icon, size: 22)
                Text(icon ?? T("key.icon.none"))
                    .lineLimit(1)
                Spacer()
                Image(systemName: "chevron.down").font(.caption2)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.glass)
        .popover(isPresented: $picking, arrowEdge: .leading) {
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
        HStack(spacing: 6) {
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
            .frame(minWidth: 70)

            if hex != nil {
                Button {
                    hex = nil
                } label: {
                    Image(systemName: "arrow.uturn.backward").font(.caption)
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
