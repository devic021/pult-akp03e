import SwiftUI

/// The scene being edited, shown as the dock itself: the keys where the keys
/// are, the knobs where the knobs are. Clicking a control selects it; the
/// inspector beside it does the editing. Nothing here starts work — the grid
/// asks for its art once per page through `prefetch`.
struct SceneEditor: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        if let name = state.selectedScene, let scene = state.config.scenes[name] {
            HStack(spacing: 0) {
                ScrollView {
                    VStack(spacing: 24) {
                        SceneHeader(name: name, scene: scene)
                        DevicePanel(name: name, scene: scene)
                    }
                    .padding(.horizontal, 28)
                    .padding(.vertical, 24)
                    .frame(maxWidth: .infinity)
                }
                .scrollBounceBehavior(.basedOnSize)

                Divider().ignoresSafeArea()

                Inspector()
                    .frame(width: 330)
            }
            .task(id: TaskKey(scene: name, page: state.page, keys: scene.keys)) {
                state.prefetchCurrentPage()
            }
        } else {
            ContentUnavailableView(T("nav.scenes"), systemImage: "square.grid.2x2")
        }
    }

    /// Changes to any of these mean the page needs new art.
    private struct TaskKey: Equatable {
        let scene: String
        let page: Int
        let keys: [Key]
    }
}

// MARK: - Header

private struct SceneHeader: View {
    @EnvironmentObject private var state: AppState
    let name: String
    let scene: DeckScene
    @State private var renaming = false
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                if renaming {
                    TextField("", text: $draft)
                        .textFieldStyle(.plain)
                        .font(.system(size: 28, weight: .semibold))
                        .onSubmit {
                            state.renameScene(name, to: draft)
                            renaming = false
                        }
                        .frame(maxWidth: 320)
                } else {
                    Text(name)
                        .font(.system(size: 28, weight: .semibold))
                        .onTapGesture(count: 2) {
                            draft = name
                            renaming = true
                        }
                }

                if name == state.config.defaultScene {
                    Label(T("scene.isDefault"), systemImage: "star.fill")
                        .labelStyle(.iconOnly)
                        .foregroundStyle(.yellow)
                        .help(T("scene.isDefault"))
                }

                Spacer()

                if state.pages > 1 {
                    PagePicker()
                }

                Button {
                    state.addPage()
                } label: {
                    Image(systemName: "plus.rectangle.on.rectangle")
                }
                .buttonStyle(.glass)
                .help(T("scene.page.add"))

                Button {
                    state.show(scene: name)
                } label: {
                    Image(systemName: "play.fill")
                }
                .buttonStyle(.glass)
                .help(T("scene.show"))
            }

            AppChips(name: name, apps: scene.apps)
        }
    }
}

private struct PagePicker: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<state.pages, id: \.self) { index in
                Button {
                    state.page = index
                    state.selection = nil
                } label: {
                    Text("\(index + 1)")
                        .font(.callout.weight(.medium))
                        .frame(width: 26, height: 22)
                }
                .buttonStyle(.plain)
                .background {
                    if state.page == index {
                        Capsule().fill(Color.accentColor.opacity(0.85))
                    }
                }
                .foregroundStyle(state.page == index ? .white : .secondary)
            }
        }
        .padding(4)
        .glassEffect(in: .capsule)
    }
}

private struct AppChips: View {
    @EnvironmentObject private var state: AppState
    let name: String
    let apps: [String]

    var body: some View {
        FlowRow(spacing: 8) {
            ForEach(Array(apps.enumerated()), id: \.offset) { index, app in
                HStack(spacing: 6) {
                    Image(systemName: "app.fill").font(.caption2).foregroundStyle(.tint)
                    Text(app).font(.callout)
                    Button {
                        state.updateScene(name) { $0.apps.remove(at: index) }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .glassEffect(in: .capsule)
            }

            Menu {
                ForEach(state.running) { app in
                    Button(app.name) {
                        state.updateScene(name) { scene in
                            if !scene.apps.contains(app.bundleID) {
                                scene.apps.append(app.bundleID)
                            }
                        }
                    }
                }
            } label: {
                Label(T("scene.apps.add"), systemImage: "plus")
                    .font(.callout)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .glassEffect(in: .capsule)
        }
    }
}

// MARK: - The dock

/// The hardware, laid out as it sits on the desk.
private struct DevicePanel: View {
    @EnvironmentObject private var state: AppState
    let name: String
    let scene: DeckScene

    var body: some View {
        GlassEffectContainer(spacing: 22) {
            HStack(alignment: .top, spacing: 34) {
                VStack(spacing: 22) {
                    KeyGrid()
                    RoundButtons(name: name, scene: scene)
                }

                VStack(spacing: 26) {
                    KnobControl(index: 1, diameter: 104)
                    HStack(spacing: 22) {
                        KnobControl(index: 0, diameter: 62)
                        KnobControl(index: 2, diameter: 62)
                    }
                }
                .padding(.top, 4)
            }
            .padding(30)
            .background {
                RoundedRectangle(cornerRadius: 30)
                    .fill(.black.opacity(0.22))
                    .overlay {
                        RoundedRectangle(cornerRadius: 30)
                            .strokeBorder(.white.opacity(0.07), lineWidth: 1)
                    }
            }
            .glassPanel(cornerRadius: 30)
        }
    }
}

private struct KeyGrid: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.fixed(104), spacing: 14), count: 3),
            spacing: 14
        ) {
            ForEach(0..<6, id: \.self) { slot in
                KeyTile(slot: slot)
            }
        }
    }
}

private struct KeyTile: View {
    @EnvironmentObject private var state: AppState
    let slot: Int

    private var key: Key? { state.key(at: slot) }
    private var selected: Bool { state.selection == .key(slot) }
    private var pressed: Bool { state.livePress == slot }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14)
                .fill(.black.opacity(0.35))

            if let key, !key.isBlank, let image = state.image(for: key) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .padding(2)
            } else {
                Image(systemName: "plus")
                    .font(.system(size: 18, weight: .light))
                    .foregroundStyle(.white.opacity(0.22))
            }
        }
        .frame(width: 104, height: 104)
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(ring, lineWidth: selected || pressed ? 2.5 : 1)
        }
        .shadow(color: .black.opacity(0.35), radius: selected ? 10 : 4, y: 2)
        .scaleEffect(pressed ? 0.94 : 1)
        .animation(.spring(duration: 0.2), value: pressed)
        .animation(.smooth(duration: 0.18), value: selected)
        .contentShape(.rect)
        .onTapGesture { state.selection = .key(slot) }
        .draggable(KeySlot(slot: slot)) {
            if let key, let image = state.image(for: key) {
                Image(nsImage: image).resizable().frame(width: 64, height: 64)
            } else {
                Color.clear.frame(width: 1, height: 1)
            }
        }
        .dropDestination(for: KeySlot.self) { items, _ in
            guard let from = items.first?.slot, from != slot else { return false }
            state.moveKey(from: from, to: slot)
            state.selection = .key(slot)
            return true
        }
    }

    private var ring: Color {
        if pressed { return .green }
        if selected { return .accentColor }
        return .white.opacity(0.08)
    }
}

/// Dragging a key between slots carries only which slot it came from.
struct KeySlot: Codable, Transferable {
    let slot: Int

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .pultKeySlot)
    }
}

private struct RoundButtons: View {
    @EnvironmentObject private var state: AppState
    let name: String
    let scene: DeckScene

    var body: some View {
        HStack(spacing: 20) {
            ForEach(0..<3, id: \.self) { index in
                let bound = index < scene.buttons.count && !scene.buttons[index].isEmpty
                let selected = state.selection == .button(index)

                VStack(spacing: 6) {
                    Circle()
                        .fill(.black.opacity(0.35))
                        .frame(width: 46, height: 46)
                        .overlay {
                            Circle().strokeBorder(
                                selected ? Color.accentColor : .white.opacity(bound ? 0.3 : 0.08),
                                lineWidth: selected ? 2.5 : 1
                            )
                        }
                        .overlay {
                            if bound {
                                Circle().fill(.tint).frame(width: 7, height: 7)
                            }
                        }
                    Text("\(index + 1)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .contentShape(.rect)
                .onTapGesture { state.selection = .button(index) }
                .animation(.smooth(duration: 0.18), value: selected)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

private struct KnobControl: View {
    @EnvironmentObject private var state: AppState
    let index: Int
    let diameter: CGFloat

    private var selected: Bool {
        if case .knob(let knob, _) = state.selection { return knob == index }
        return false
    }

    private var knob: Knob {
        let encoders = state.scene?.encoders ?? []
        return index < encoders.count ? encoders[index] : Knob()
    }

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [.white.opacity(0.10), .black.opacity(0.40)],
                            center: .topLeading,
                            startRadius: 2,
                            endRadius: diameter
                        )
                    )
                Circle()
                    .strokeBorder(
                        selected ? Color.accentColor : .white.opacity(0.12),
                        lineWidth: selected ? 2.5 : 1
                    )

                // The knurling, suggested rather than drawn.
                ForEach(0..<24, id: \.self) { tick in
                    Capsule()
                        .fill(.white.opacity(0.10))
                        .frame(width: 1.2, height: diameter * 0.07)
                        .offset(y: -diameter / 2 + diameter * 0.055)
                        .rotationEffect(.degrees(Double(tick) / 24 * 360))
                }

                Circle()
                    .fill(.black.opacity(0.25))
                    .frame(width: diameter * 0.42, height: diameter * 0.42)
            }
            .frame(width: diameter, height: diameter)
            .shadow(color: .black.opacity(0.4), radius: selected ? 10 : 5, y: 2)
            .contentShape(.circle)
            .onTapGesture { state.selection = .knob(index, .cw) }
            .animation(.smooth(duration: 0.18), value: selected)

            Text(T("encoder.\(index)"))
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: diameter + 20)
                .multilineTextAlignment(.center)
        }
    }
}

// MARK: - Layout helper

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
