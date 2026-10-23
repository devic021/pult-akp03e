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
                .font(.app(34, weight: .light))
                .foregroundStyle(.tertiary)
            Text(T("inspector.hint"))
                .font(.appCallout)
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
        .help(T("help.label"))

        Field(T("key.icon")) {
            IconField(icon: key.icon)
        }
        .help(T("help.icon"))

        HStack(spacing: 10) {
            Field(T("key.color")) { ColorField(hex: key.color, fallback: "#30363d") }
                .help(T("help.color"))
            Field(T("key.iconColor")) { ColorField(hex: key.icon_color, fallback: nil) }
                .help(T("help.iconColor"))
        }

        Field(T("key.textColor")) { ColorField(hex: key.text_color, fallback: nil) }
            .help(T("help.textColor"))

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
        .help(T("help.animate"))

        Divider().padding(.vertical, 4)

        ReadingEditor(key: key)

        Divider().padding(.vertical, 4)

        // A key that reports cannot also act: the daemon refuses the pair,
        // because a press can only mean one thing. So the action editor steps
        // aside rather than offering something that would be rejected at load.
        if key.wrappedValue.reads {
            Text(T("key.reads.says"))
                .font(.appCaption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            ActionEditor(action: key.action)
                .help(T("help.action"))
        }

        Button(role: .destructive) {
            state.setKey(nil, at: slot)
        } label: {
            Label(T("key.clear"), systemImage: "eraser")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.pult)
        .help(T("help.clear"))
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

/// Turns a key into a readout, and edits what it reports.
private struct ReadingEditor: View {
    @Binding var key: Key

    var body: some View {
        Toggle(isOn: Binding(
            get: { key.reads },
            set: { on in
                if on {
                    key.value = key.value ?? ""
                    // The action goes with it. Leaving one behind would write
                    // a file the daemon refuses, and finding that out at load
                    // is worse than losing it while somebody is watching.
                    key.action = Action()
                } else {
                    key.value = nil
                    key.caption = nil
                    key.ramp = nil
                    key.cycle = []
                }
            }
        )) {
            Text(T("key.reads")).font(.appCallout)
        }
        .toggleStyle(.switch)

        if key.reads {
            Field(T("key.value")) {
                TextField(
                    "",
                    text: Binding(get: { key.value ?? "" }, set: { key.value = $0 }),
                    prompt: Text("{vreme.temp|round}\u{00b0}")
                )
                .textFieldStyle(.roundedBorder)
                .font(.appCallout.monospaced())
            }
            .help(T("key.value.help"))

            Field(T("key.caption")) {
                TextField(
                    "",
                    text: Binding(
                        get: { key.caption ?? "" },
                        set: { key.caption = $0.isEmpty ? nil : $0 }
                    ),
                    prompt: Text(T("key.caption"))
                )
                .textFieldStyle(.roundedBorder)
            }
            .help(T("key.caption.help"))

            Field(T("key.iconRotate")) {
                TextField(
                    "",
                    text: Binding(
                        get: { key.icon_rotate ?? "" },
                        set: { key.icon_rotate = $0.isEmpty ? nil : $0 }
                    ),
                    prompt: Text("{vreme.bearing|compass16}")
                )
                .textFieldStyle(.roundedBorder)
                .font(.appCallout.monospaced())
            }
            .help(T("key.iconRotate.help"))

            RampEditor(ramp: $key.ramp)
            CycleEditor(cycle: $key.cycle)
        }
    }
}

/// The background as a reading of its own.
private struct RampEditor: View {
    @Binding var ramp: Ramp?

    var body: some View {
        Field(T("key.ramp")) {
            VStack(alignment: .leading, spacing: 8) {
                Toggle(isOn: Binding(
                    get: { ramp != nil },
                    set: { on in
                        ramp = on
                            ? Ramp(
                                field: "",
                                stops: [
                                    Ramp.Stop(value: 0, color: "#1f6feb"),
                                    Ramp.Stop(value: 30, color: "#d93025"),
                                ]
                            )
                            : nil
                    }
                )) {
                    Text(ramp == nil ? T("key.ramp.off") : T("key.ramp.field")).font(.appCaption)
                }
                .toggleStyle(.switch)

                if ramp != nil {
                    TextField(
                        "",
                        text: Binding(get: { ramp?.field ?? "" }, set: { ramp?.field = $0 }),
                        prompt: Text("vreme.temp")
                    )
                    .textFieldStyle(.roundedBorder)
                    .font(.appCallout.monospaced())

                    ForEach(Array((ramp?.stops ?? []).enumerated()), id: \.element.id) { index, _ in
                        HStack(spacing: 6) {
                            TextField("", value: Binding(
                                get: { ramp?.stops[index].value ?? 0 },
                                set: { ramp?.stops[index].value = $0 }
                            ), format: .number)
                            .textFieldStyle(.roundedBorder)
                            .font(.appCallout.monospacedDigit())
                            .frame(width: 60)

                            ColorField(
                                hex: Binding(
                                    get: { ramp?.stops[index].color },
                                    set: { ramp?.stops[index].color = $0 ?? "#4da3ff" }
                                ),
                                fallback: "#4da3ff"
                            )

                            Button {
                                ramp?.stops.remove(at: index)
                            } label: {
                                Image(systemName: "minus.circle").font(.appCaption)
                            }
                            .buttonStyle(.plain)
                            .help(T("key.cycle.remove"))
                        }
                    }

                    Button {
                        let last = ramp?.stops.last
                        ramp?.stops.append(
                            Ramp.Stop(
                                value: (last?.value ?? 0) + 10,
                                color: last?.color ?? "#4da3ff"
                            )
                        )
                    } label: {
                        Label(T("key.ramp.add"), systemImage: "plus")
                    }
                    .buttonStyle(.pult)
                }
            }
        }
        .help(T("key.ramp.help"))
    }
}

/// The other readings a press moves through.
private struct CycleEditor: View {
    @Binding var cycle: [KeyView]

    var body: some View {
        Field(T("key.cycle")) {
            VStack(alignment: .leading, spacing: 8) {
                Text(T("key.cycle.help"))
                    .font(.appCaption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                ForEach(Array(cycle.enumerated()), id: \.element.id) { index, _ in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 6) {
                            Text("\(index + 2)")
                                .font(.appCaption.monospacedDigit())
                                .foregroundStyle(.tertiary)
                            TextField("", text: Binding(
                                get: { cycle[index].value ?? "" },
                                set: { cycle[index].value = $0.isEmpty ? nil : $0 }
                            ), prompt: Text(T("key.value")))
                            .textFieldStyle(.roundedBorder)
                            .font(.appCallout.monospaced())

                            Button {
                                cycle.remove(at: index)
                            } label: {
                                Image(systemName: "minus.circle").font(.appCaption)
                            }
                            .buttonStyle(.plain)
                            .help(T("key.cycle.remove"))
                        }

                        TextField("", text: Binding(
                            get: { cycle[index].caption ?? "" },
                            set: { cycle[index].caption = $0.isEmpty ? nil : $0 }
                        ), prompt: Text(T("key.caption")))
                        .textFieldStyle(.roundedBorder)
                        .padding(.leading, 16)
                    }
                }

                Button {
                    cycle.append(KeyView())
                } label: {
                    Label(T("key.cycle.add"), systemImage: "plus")
                }
                .buttonStyle(.pult)
            }
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
            Text(title).font(.appTitle3.weight(.semibold))
            if let subtitle {
                Text(subtitle)
                    .font(.appCallout.monospacedDigit())
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
                .font(.appCaption)
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
                Image(systemName: "chevron.down").font(.appCaption2)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.pult)
        .popover(isPresented: $picking, arrowEdge: .leading) {
            IconPicker(selection: $icon, dismiss: { picking = false })
        }
    }
}

/// A colour well that can also mean "let the daemon choose".
struct ColorField: View {
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
            .font(.appCallout.monospaced())
            .frame(minWidth: 56)

            if hex != nil {
                Button {
                    hex = nil
                } label: {
                    Image(systemName: "arrow.uturn.backward").font(.appCaption)
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
