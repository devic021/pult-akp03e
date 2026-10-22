import SwiftUI

/// The scene being edited: its applications, its keys laid out as the dock
/// lays them out, its knobs and its round buttons.
struct SceneEditor: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        if let name = state.selectedScene, let scene = state.config.scenes[name] {
            HSplitView {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        SceneHeader(name: name, scene: scene)
                        KeyGrid(scene: scene)
                        EncoderSection(name: name, scene: scene)
                        ButtonSection(name: name, scene: scene)
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minWidth: 520)

                KeyInspector()
                    .frame(minWidth: 300, idealWidth: 340, maxWidth: 420)
            }
        } else {
            ContentUnavailableView(T("nav.scenes"), systemImage: "square.grid.2x2")
        }
    }
}

private struct SceneHeader: View {
    @EnvironmentObject private var state: AppState
    let name: String
    let scene: DeckScene
    @State private var showApps = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(name).font(.largeTitle.weight(.semibold))
                if name == state.config.defaultScene {
                    Text(T("scene.isDefault"))
                        .font(.caption)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .glassEffect(in: .capsule)
                }
                Spacer()
                Button {
                    state.show(scene: name)
                } label: {
                    Label(T("status.scene"), systemImage: "play.rectangle")
                }
                .help(T("status.scene"))
            }

            VStack(alignment: .leading, spacing: 6) {
                SectionHeading(title: T("scene.apps"), systemImage: "app.badge")
                Text(T("scene.apps.help")).font(.caption).foregroundStyle(.secondary)

                FlowRow(spacing: 6) {
                    ForEach(Array(scene.apps.enumerated()), id: \.offset) { index, app in
                        HStack(spacing: 4) {
                            Text(app).font(.callout.monospaced())
                            Button {
                                state.updateScene(name) { $0.apps.remove(at: index) }
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .glassEffect(in: .capsule)
                    }

                    Menu {
                        ForEach(state.runningApps(), id: \.bundleID) { app in
                            Button("\(app.name) — \(app.bundleID)") {
                                state.updateScene(name) { scene in
                                    if !scene.apps.contains(app.bundleID) {
                                        scene.apps.append(app.bundleID)
                                    }
                                }
                            }
                        }
                    } label: {
                        Label(T("scene.apps.add"), systemImage: "plus")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
            }
        }
    }
}

/// The six keys, in the dock's own 2×3 arrangement, with the page strip above.
private struct KeyGrid: View {
    @EnvironmentObject private var state: AppState
    let scene: DeckScene

    private var pages: Int { scene.pages() }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SectionHeading(title: T("scene.keys"), systemImage: "square.grid.2x2")
                Spacer()

                if pages > 1 {
                    Picker("", selection: Binding(
                        get: { state.page },
                        set: { state.page = $0; state.selectedKey = nil }
                    )) {
                        ForEach(0..<pages, id: \.self) { index in
                            Text("\(T("scene.page")) \(index + 1)").tag(index)
                        }
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                }

                Button {
                    state.addPage()
                } label: {
                    Label(T("scene.page.add"), systemImage: "plus.rectangle.on.rectangle")
                }
                .buttonStyle(.glass)
            }

            GlassEffectContainer(spacing: 18) {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.fixed(132), spacing: 14), count: 3),
                    spacing: 14
                ) {
                    ForEach(0..<6, id: \.self) { slot in
                        KeyCell(slot: slot)
                    }
                }
            }
        }
    }
}

private struct KeyCell: View {
    @EnvironmentObject private var state: AppState
    let slot: Int

    private var key: Key? { state.key(at: slot) }
    private var selected: Bool { state.selectedKey == slot }
    private var pressed: Bool { state.livePress == slot }

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                if let key, !key.isBlank, let image = state.image(for: key) {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .padding(3)
                } else {
                    Image(systemName: "plus")
                        .font(.title2)
                        .foregroundStyle(.quaternary)
                }
            }
            .frame(width: 118, height: 118)
            .padding(5)
            .glassTile(cornerRadius: 18, tint: pressed ? .green : (selected ? .accentColor : nil))
            .scaleEffect(pressed ? 0.94 : 1)
            .animation(.spring(duration: 0.22), value: pressed)
            .animation(.smooth(duration: 0.2), value: selected)

            Text(key.map { $0.isBlank ? T("key.empty") : ($0.label.isEmpty ? ($0.icon ?? "—") : $0.label) } ?? T("key.empty"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .contentShape(.rect)
        .onTapGesture { state.selectedKey = slot }
    }
}

/// Knobs: three of them, each with two turns and a press.
private struct EncoderSection: View {
    @EnvironmentObject private var state: AppState
    let name: String
    let scene: DeckScene

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeading(title: T("scene.encoders"), systemImage: "dial.medium")

            HStack(alignment: .top, spacing: 14) {
                ForEach(0..<3, id: \.self) { index in
                    VStack(alignment: .leading, spacing: 8) {
                        Label(T("encoder.\(index)"), systemImage: index == 1 ? "dial.high" : "dial.low")
                            .font(.subheadline.weight(.medium))

                        ActionRow(title: T("encoder.ccw"), action: binding(index, \.ccw))
                        ActionRow(title: T("encoder.cw"), action: binding(index, \.cw))
                        ActionRow(title: T("encoder.press"), action: binding(index, \.press))
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .glassPanel(cornerRadius: 16)
                }
            }
        }
    }

    private func binding(_ index: Int, _ path: WritableKeyPath<Knob, Action>) -> Binding<Action> {
        Binding(
            get: {
                let encoders = state.config.scenes[name]?.encoders ?? []
                return index < encoders.count ? encoders[index][keyPath: path] : Action()
            },
            set: { value in
                state.updateScene(name) { scene in
                    while scene.encoders.count <= index { scene.encoders.append(Knob()) }
                    scene.encoders[index][keyPath: path] = value
                }
            }
        )
    }
}

private struct ButtonSection: View {
    @EnvironmentObject private var state: AppState
    let name: String
    let scene: DeckScene

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeading(title: T("scene.buttons"), systemImage: "circle.grid.3x1")

            HStack(alignment: .top, spacing: 14) {
                ForEach(0..<3, id: \.self) { index in
                    VStack(alignment: .leading, spacing: 8) {
                        Label(
                            String(format: T("button.n"), "\(index + 1)"),
                            systemImage: "circle"
                        )
                        .font(.subheadline.weight(.medium))

                        ActionRow(title: "", action: Binding(
                            get: {
                                let buttons = state.config.scenes[name]?.buttons ?? []
                                return index < buttons.count ? buttons[index] : Action()
                            },
                            set: { value in
                                state.updateScene(name) { scene in
                                    while scene.buttons.count <= index { scene.buttons.append(Action()) }
                                    scene.buttons[index] = value
                                }
                            }
                        ))
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .glassPanel(cornerRadius: 16)
                }
            }
        }
    }
}

/// Lays children out in rows, wrapping when the width runs out.
struct FlowRow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 400
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 {
                x = 0
                y += lineHeight + spacing
                lineHeight = 0
            }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: width, height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += lineHeight + spacing
                lineHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
