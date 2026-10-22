import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The surface panel: what a scene paints with, and every setting the daemon
/// says that motion honours.
///
/// Not one control is written out by hand. The daemon answers `effects` with
/// its catalogue and, for each effect, the rows it actually reads — so adding
/// an effect to the daemon grows this panel with no change here, and no
/// control can outlive the thing it drives.
struct SurfaceSection: View {
    let name: String
    let width: CGFloat

    @EnvironmentObject private var state: AppState

    private var surface: Surface {
        state.config.scenes[name]?.surface ?? Surface()
    }

    private var effect: EffectInfo? {
        state.catalogue.effect(surface.effect) ?? state.catalogue.effects.first
    }

    var body: some View {
        Section2(T("section.surface"), symbol: "rectangle.on.rectangle") {
            ActionCard(
                T("surface.whole"),
                symbol: "rectangle.inset.filled",
                detail: T("surface.whole.says")
            ) {
                Toggle("", isOn: Binding(
                    get: { surface.isCanvas },
                    set: { whole in
                        edit { surface in
                            surface.kind = whole ? "canvas" : "keys"
                            // A canvas with nothing named paints nothing, and
                            // the daemon refuses to load it, so switching on
                            // picks the first effect rather than leaving a
                            // scene the configuration will not accept.
                            if whole, surface.effect == nil, !surface.paintsAFile {
                                surface.effect = state.catalogue.effects.first?.name
                            }
                        }
                    }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
            }

            if surface.isCanvas {
                if surface.paintsAFile {
                    FileCard(name: name, surface: surface, edit: edit)
                } else {
                    EffectGallery(
                        width: width,
                        chosen: surface.effect,
                        choose: { chosen in edit { $0.effect = chosen } }
                    )
                }

                TrialCard(surface: surface)

                if let effect, !surface.paintsAFile {
                    ForEach(effect.knobs) { knob in
                        KnobRow(knob: knob, effect: effect, surface: surface, edit: edit)
                    }
                }
            }
        }
        .task(id: state.catalogue.effects.isEmpty) {
            state.loadCatalogue()
        }
    }

    private func edit(_ change: (inout Surface) -> Void) {
        var next = state.config.scenes[name]?.surface ?? Surface()
        change(&next)
        // An empty canvas is not a surface worth keeping: dropping it back to
        // nil is what makes a scene that was never a canvas stay out of the
        // written file entirely.
        state.config.scenes[name]?.surface =
            next.kind == "keys" && next.values.isEmpty && next.effect == nil && next.source == nil
            ? nil
            : next
    }
}

// MARK: - Choosing an effect by looking at it

/// The catalogue as pictures, not as a list of names.
///
/// Each tile is the real dock — six keys with the real plastic between them —
/// running the real motion. That is the only honest way to choose one: on a
/// flat rectangle every effect looks fine, and the question is what survives
/// being cut into six.
private struct EffectGallery: View {
    let width: CGFloat
    let chosen: String?
    let choose: (String) -> Void

    @EnvironmentObject private var state: AppState

    private var columns: [GridItem] {
        // Two across in a narrow window, three when there is room. Measured
        // against the tile's own width rather than a breakpoint, so it holds
        // at every text size.
        let tile: CGFloat = 230
        let fits = max(1, Int(width / tile))
        return Array(repeating: GridItem(.flexible(), spacing: 12), count: min(3, fits))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(state.catalogue.effects) { effect in
                    EffectTile(
                        effect: effect,
                        film: state.strips[effect.name],
                        selected: effect.name == chosen
                    ) {
                        choose(effect.name)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: state.catalogue.effects.count) {
            state.loadStrips()
        }
    }
}

private struct EffectTile: View {
    let effect: EffectInfo
    let film: Film?
    let selected: Bool
    let tap: () -> Void

    var body: some View {
        Button(action: tap) {
            VStack(alignment: .leading, spacing: 8) {
                DockFilm(film: film)
                    .frame(height: 76)
                    .frame(maxWidth: .infinity)

                VStack(alignment: .leading, spacing: 2) {
                    Text(effect.shownTitle).font(.appHeadline)
                    Text(effect.shownSentence)
                        .font(.appCaption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .card(radius: 14)
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(selected ? Design.accent : .clear, lineWidth: 2)
        }
        .help(effect.shownSentence)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

/// A short loop of the dock, drawn with its real seams.
///
/// The gaps are the point. A tile that showed one flat 212x136 rectangle would
/// flatter every effect equally and tell you nothing about the one thing that
/// separates them on this device.
struct DockFilm: View {
    let film: Film?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0 / 15.0)) { timeline in
            Canvas { context, size in
                let key = size.width / 3.52
                let gap = key * 0.26
                let width = 3 * key + 2 * gap
                let height = 2 * key + gap
                let left = (size.width - width) / 2
                let top = (size.height - height) / 2

                let frame = film?.frame(at: timeline.date.timeIntervalSinceReferenceDate)
                for index in 0..<6 {
                    let rect = CGRect(
                        x: left + CGFloat(index % 3) * (key + gap),
                        y: top + CGFloat(index / 3) * (key + gap),
                        width: key,
                        height: key
                    )
                    let shape = RoundedRectangle(cornerRadius: key * 0.18, style: .continuous)
                        .path(in: rect)

                    if let tile = frame?[safe: index] {
                        // A copy, because clipping is permanent on the context
                        // it is applied to and the next key needs a clean one.
                        var window = context
                        window.clip(to: shape)
                        window.draw(Image(nsImage: tile), in: rect)
                    } else {
                        context.fill(shape, with: .color(.black.opacity(0.55)))
                    }
                }
            }
        }
        .drawingGroup()
    }
}

/// Frames of six tiles, and how long the loop runs.
struct Film: Equatable {
    let frames: [[NSImage]]
    let seconds: Double

    func frame(at time: TimeInterval) -> [NSImage]? {
        guard !frames.isEmpty else { return nil }
        let loop = max(0.1, seconds)
        let step = (time.truncatingRemainder(dividingBy: loop)) / loop
        return frames[Swift.min(frames.count - 1, Int(step * Double(frames.count)))]
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

// MARK: - One knob

/// One row, built from what the daemon said about this knob.
private struct KnobRow: View {
    let knob: KnobInfo
    let effect: EffectInfo
    let surface: Surface
    let edit: ((inout Surface) -> Void) -> Void

    /// What the row shows when nothing has been set: the effect's own answer
    /// where the knob defers to it, and the knob's own default otherwise.
    private var unset: String {
        if knob.followsEffect { return effect.own(knob.name) ?? "—" }
        switch knob.preset {
        case .number(let value): return knob.reading(value)
        case .string(let text): return text.isEmpty ? T("key.auto") : text
        case .bool(let flag): return flag ? T("yes") : T("no")
        case .array: return (knob.presetPair ?? []).map { knob.reading($0) }.joined(separator: " · ")
        default: return "—"
        }
    }

    private var isSet: Bool { surface.values[knob.name] != nil }

    var body: some View {
        ActionCard(knob.label, symbol: symbol, detail: knob.detail) {
            HStack(spacing: 8) {
                control
                if isSet {
                    Button {
                        edit { $0.set(knob.name, nil) }
                    } label: {
                        Image(systemName: "arrow.uturn.backward").font(.appCaption)
                    }
                    .buttonStyle(.borderless)
                    .help(T("knob.clear"))
                }
            }
        }
    }

    @ViewBuilder
    private var control: some View {
        switch knob.control {
        case .range:
            HStack(spacing: 10) {
                Slider(
                    value: Binding(
                        get: { surface.number(knob.name) ?? knob.presetNumber ?? knob.min },
                        set: { value in edit { surface in surface.set(knob.name, number: value) } }
                    ),
                    in: knob.min...knob.max,
                    step: knob.step
                )
                .frame(width: 150)

                Text(surface.number(knob.name).map(knob.reading) ?? unset)
                    .font(.appCallout.monospacedDigit())
                    .foregroundStyle(isSet ? .primary : .secondary)
                    .frame(minWidth: 44, alignment: .trailing)
            }

        case .choice:
            Picker("", selection: Binding(
                get: { surface.text(knob.name) ?? "" },
                set: { text in
                    edit { surface in surface.set(knob.name, text: text.isEmpty ? nil : text) }
                }
            )) {
                // The empty choice is the honest one: it says the effect
                // decides, which is different from naming the value the
                // effect happens to choose today.
                Text(unset + " · " + T("knob.own")).tag("")
                Divider()
                ForEach(knob.options, id: \.self) { option in
                    Text(T("option.\(option)", or: option)).tag(option)
                }
            }
            .labelsHidden()
            .frame(minWidth: 150)

        case .color:
            ColorField(
                hex: Binding(
                    get: { surface.text(knob.name) },
                    set: { text in edit { surface in surface.set(knob.name, text: text) } }
                ),
                fallback: knob.presetText?.isEmpty == false ? knob.presetText : nil
            )

        case .flag:
            Toggle("", isOn: Binding(
                get: { surface.flag(knob.name) ?? knob.presetFlag ?? false },
                set: { flag in edit { surface in surface.set(knob.name, flag: flag) } }
            ))
            .labelsHidden()
            .toggleStyle(.switch)

        case .pair:
            HStack(spacing: 6) {
                ForEach(0..<2, id: \.self) { slot in
                    TextField("", value: Binding(
                        get: {
                            surface.pair(knob.name)?[safe: slot]
                                ?? knob.presetPair?[safe: slot]
                                ?? knob.min
                        },
                        set: { value in
                            var pair = surface.pair(knob.name) ?? knob.presetPair ?? [knob.min, knob.min]
                            while pair.count < 2 { pair.append(knob.min) }
                            pair[slot] = Swift.min(Swift.max(value, knob.min), knob.max)
                            edit { surface in surface.set(knob.name, pair: pair) }
                        }
                    ), format: .number)
                    .textFieldStyle(.roundedBorder)
                    .font(.appCallout.monospacedDigit())
                    .frame(width: 58)
                }
            }

        case .duration:
            TextField("", text: Binding(
                get: { surface.text(knob.name) ?? "" },
                set: { text in
                    edit { surface in surface.set(knob.name, text: text.isEmpty ? nil : text) }
                }
            ), prompt: Text(unset))
            .textFieldStyle(.roundedBorder)
            .font(.appCallout.monospaced())
            .frame(width: 90)
        }
    }

    private var symbol: String {
        switch knob.name {
        case "speed": return "hare"
        case "direction": return "arrow.triangle.turn.up.right.diamond"
        case "cycle": return "repeat"
        case "scale": return "arrow.up.left.and.arrow.down.right"
        case "density": return "circle.grid.3x3"
        case "softness": return "drop"
        case "origin": return "scope"
        case "color", "color2": return "paintpalette"
        case "background": return "square.fill"
        case "color_cycle": return "timelapse"
        case "opacity": return "sun.max"
        case "seed": return "dice"
        case "mapping": return "squares.below.rectangle"
        case "fps": return "film"
        case "stop_after": return "pause.circle"
        case "reduce_motion": return "figure.walk.motion"
        case "trail": return "wind"
        case "lobes": return "infinity"
        case "shape": return "waveform.path.ecg"
        case "height", "floor": return "ruler"
        case "smoke": return "smoke"
        case "threshold": return "slider.horizontal.below.square.filled.and.square"
        default: return "slider.horizontal.3"
        }
    }
}

// MARK: - Putting it on the real dock

/// The only honest judge of a motion is the dock itself.
///
/// A trial expires on its own, so a crashed editor cannot leave the dock
/// showing something nobody saved.
private struct TrialCard: View {
    let surface: Surface
    @EnvironmentObject private var state: AppState

    var body: some View {
        ActionCard(
            T("surface.try"),
            symbol: "play.rectangle",
            detail: T("surface.try.says"),
            tinted: true
        ) {
            HStack(spacing: 8) {
                if state.trialing {
                    Button(T("surface.try.stop")) { state.stopTrial() }
                        .buttonStyle(.pult)
                }
                Button(T("surface.try.go")) { state.tryOnDock(surface) }
                    .buttonStyle(.pultProminent)
                    .disabled(!state.connected)
            }
        }
    }
}

private extension Array where Element == Double {
    subscript(safe index: Int) -> Double? {
        indices.contains(index) ? self[index] : nil
    }
}

// MARK: - A file of your own

/// When a scene paints a file, the effect gallery is not what you are choosing
/// from, so it gets out of the way and the file's own settings take its place.
private struct FileCard: View {
    let name: String
    let surface: Surface
    let edit: ((inout Surface) -> Void) -> Void

    var body: some View {
        ActionCard(
            T("surface.file"),
            symbol: "photo.on.rectangle.angled",
            detail: surface.source ?? T("surface.file.says")
        ) {
            HStack(spacing: 8) {
                Button(T("surface.file.choose")) { pick() }
                    .buttonStyle(.pult)
                Button(T("surface.file.drop")) {
                    edit { $0.source = nil }
                }
                .buttonStyle(.pult)
            }
        }
    }

    private func pick() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        // A folder of numbered frames is one of the shapes the daemon reads,
        // so it has to be selectable as a thing in its own right.
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.gif, .png, .jpeg, .webP]
        panel.message = T("surface.file.says")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        edit { $0.source = url.path }
    }
}
