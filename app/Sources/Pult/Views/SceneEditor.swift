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

                        VStack(spacing: 10) {
                            DevicePanel(name: name, scene: scene)
                            SceneSummary(scene: scene)
                                .frame(maxWidth: Dock.body.width)
                        }
                    }
                    .padding(.horizontal, 28)
                    .padding(.vertical, 24)
                    .frame(maxWidth: .infinity)
                }
                .scrollBounceBehavior(.basedOnSize)

                Divider().ignoresSafeArea()

                Inspector()
                    .frame(minWidth: 300, idealWidth: 340, maxWidth: 420)
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
            HStack(alignment: .center, spacing: 10) {
                if renaming {
                    TextField("", text: $draft)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 24, weight: .semibold))
                        .frame(maxWidth: 320)
                        .onSubmit {
                            state.renameScene(name, to: draft)
                            renaming = false
                        }
                        .onExitCommand { renaming = false }

                    Button(T("status.save")) {
                        state.renameScene(name, to: draft)
                        renaming = false
                    }
                    .buttonStyle(.glassProminent)
                    .controlSize(.small)
                } else {
                    Text(name)
                        .font(.system(size: 28, weight: .semibold))

                    Button {
                        draft = name
                        renaming = true
                    } label: {
                        Image(systemName: "pencil")
                    }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                    .help(T("scene.rename"))
                }

                if name == state.config.defaultScene {
                    Label(T("scene.isDefault"), systemImage: "star.fill")
                        .labelStyle(.iconOnly)
                        .foregroundStyle(.yellow)
                        .help(T("help.default"))
                }

                Spacer()

                if state.pages > 1 {
                    PagePicker()
                }

                Button {
                    state.addPage()
                } label: {
                    Label(T("scene.page.add"), systemImage: "plus.rectangle.on.rectangle")
                        .frame(height: headerControlHeight - 10)
                }
                .buttonStyle(.glass)
                .help(T("help.page"))

                Button {
                    state.show(scene: name)
                } label: {
                    Label(T("scene.show"), systemImage: "play.fill")
                        .frame(height: headerControlHeight - 10)
                }
                .buttonStyle(.glass)
                .help(T("help.showScene"))
            }

            AppChips(name: name, apps: scene.apps)
        }
    }
}

/// Height every control in the scene's header shares, so they line up.
private let headerControlHeight: CGFloat = 28

private struct PagePicker: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<state.pages, id: \.self) { index in
                let current = state.page == index
                Button {
                    state.page = index
                    state.selection = nil
                } label: {
                    Text("\(index + 1)")
                        .font(.callout.weight(.medium))
                        // The whole chip is the target, not the digit: aiming
                        // at a numeral is not a way to turn a page.
                        .frame(minWidth: 30, maxHeight: .infinity)
                        .padding(.horizontal, 4)
                        .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .background {
                    if current {
                        Capsule().fill(Color.accentColor.opacity(0.9))
                    }
                }
                .foregroundStyle(current ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                .help("\(T("scene.page")) \(index + 1)")
            }
        }
        .padding(3)
        .frame(height: headerControlHeight)
        .glassEffect(in: .capsule)
    }
}

/// Which applications bring this scene up. Named, not spelled out in
/// reverse-DNS, and introduced by a sentence saying what the row is for.
private struct AppChips: View {
    @EnvironmentObject private var state: AppState
    let name: String
    let apps: [String]
    @State private var adding = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.right.circle").foregroundStyle(.tint)
                Text(T("scene.apps.intro"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            FlowRow(spacing: 8) {
                ForEach(Array(apps.enumerated()), id: \.offset) { index, app in
                    AppChip(bundleID: app) {
                        state.updateScene(name) { $0.apps.remove(at: index) }
                    }
                }

                Button {
                    adding = true
                } label: {
                    Label(T("scene.apps.add"), systemImage: "plus")
                        .font(.callout)
                }
                .buttonStyle(.glass)
                .controlSize(.small)
                .help(T("help.apps"))
                .popover(isPresented: $adding, arrowEdge: .bottom) {
                    AppPickerPopover(chosen: Set(apps)) { app in
                        state.updateScene(name) { scene in
                            if !scene.apps.contains(app.bundleID) {
                                scene.apps.append(app.bundleID)
                            }
                        }
                        adding = false
                    }
                }
            }

            if apps.isEmpty && name != state.config.defaultScene {
                Text(T("scene.apps.none"))
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }
}

// MARK: - The dock

/// The hardware, drawn where the hardware's parts are: six keys to the left,
/// three plain buttons under them, the big knob to the right with the two
/// small ones below it. Positions come from the device itself, so what is on
/// screen matches what is under your hand.
private struct DevicePanel: View {
    @EnvironmentObject private var state: AppState
    let name: String
    let scene: DeckScene

    var body: some View {
        DockBody {
            ZStack(alignment: .topLeading) {
                VStack(spacing: 0) {
                    DockBadge(scale: Dock.scale)
                    Spacer()
                }
                .frame(width: Dock.body.width, height: Dock.body.height)
                .padding(.top, 15 * Dock.scale)

                ForEach(0..<6, id: \.self) { slot in
                    let frame = Dock.keyFrame(slot)
                    KeyCap(slot: slot)
                        .frame(width: frame.width, height: frame.height)
                        .help(keyHelp(slot))
                        .offset(x: frame.minX, y: frame.minY)
                }

                Control(centre: Dock.bigKnobCenter, size: Dock.bigKnob, label: T("encoder.1")) {
                    KnobFace(diameter: Dock.bigKnob, selected: knobSelected(1))
                        .onTapGesture { state.selection = .knob(1, .cw) }
                        .help(knobHelp(1))
                }

                ForEach(Array(Dock.smallKnobCenters.enumerated()), id: \.offset) { position, centre in
                    let index = position == 0 ? 0 : 2
                    Control(centre: centre, size: Dock.smallKnob, label: T("encoder.\(index)")) {
                        KnobFace(diameter: Dock.smallKnob, selected: knobSelected(index))
                            .onTapGesture { state.selection = .knob(index, .cw) }
                            .help(knobHelp(index))
                    }
                }

                ForEach(Array(Dock.buttonCenters.enumerated()), id: \.offset) { index, centre in
                    Control(centre: centre, size: Dock.button, label: "\(index + 1)") {
                        ButtonFace(
                            diameter: Dock.button,
                            bound: index < scene.buttons.count && !scene.buttons[index].isEmpty,
                            selected: state.selection == .button(index)
                        )
                        .onTapGesture { state.selection = .button(index) }
                        .help(buttonHelp(index))
                    }
                }
            }
            .frame(width: Dock.body.width, height: Dock.body.height, alignment: .topLeading)
        }
    }

    private func knobSelected(_ index: Int) -> Bool {
        if case .knob(let knob, _) = state.selection { return knob == index }
        return false
    }

    // Tooltips carry what the drawing deliberately leaves out: the device has
    // no labels on its knobs and no marks on its buttons, so hovering is how
    // you find out what a control is bound to without clicking it.

    private func keyHelp(_ slot: Int) -> String {
        guard let key = state.key(at: slot), !key.isBlank else { return T("key.empty") }
        let name = key.label.isEmpty ? (key.icon ?? T("key.title")) : key.label
        return "\(name)\n\(key.action.summary)"
    }

    private func knobHelp(_ index: Int) -> String {
        let knob = index < scene.encoders.count ? scene.encoders[index] : Knob()
        return [
            T("encoder.\(index)"),
            "\(T("encoder.ccw")): \(knob.ccw.summary)",
            "\(T("encoder.cw")): \(knob.cw.summary)",
            "\(T("encoder.press")): \(knob.press.summary)",
        ].joined(separator: "\n")
    }

    private func buttonHelp(_ index: Int) -> String {
        let action = index < scene.buttons.count ? scene.buttons[index] : Action()
        return "\(String(format: T("button.n"), "\(index + 1)"))\n\(action.summary)"
    }
}

/// Width of the invisible column a part and its caption are centred in.
private let controlLane: CGFloat = 150

/// A part of the dock, placed by its centre, with its name in the shell's
/// bottom margin where the real device has bare plastic.
private struct Control<Content: View>: View {
    let centre: CGPoint
    /// Needed to place the part by its middle rather than its top edge.
    let size: CGFloat
    let label: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 5) {
            content
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(.white.opacity(0.38))
                .lineLimit(1)
                .fixedSize()
        }
        .frame(width: controlLane)
        .offset(x: centre.x - controlLane / 2, y: centre.y - size / 2)
    }
}

/// One key with a display, showing exactly what the dock shows.
private struct KeyCap: View {
    @EnvironmentObject private var state: AppState
    let slot: Int

    private var key: Key? { state.key(at: slot) }
    private var selected: Bool { state.selection == .key(slot) }
    private var pressed: Bool { state.livePress == slot }

    var body: some View {
        ZStack {
            // The cap: dark, with a single bright edge. A wide pale frame is
            // what made these read as grey bands rather than as key caps.
            RoundedRectangle(cornerRadius: Dock.keyCorner)
                .fill(Color(white: 0.10))
                .overlay {
                    RoundedRectangle(cornerRadius: Dock.keyCorner)
                        .strokeBorder(
                            LinearGradient(
                                colors: [.white.opacity(0.40), .white.opacity(0.10)],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            lineWidth: 1
                        )
                }

            // The display sits inside the cap, with a thin dark border.
            ZStack {
                RoundedRectangle(cornerRadius: Dock.keyCorner - 4).fill(.black)

                if let key, !key.isBlank, let image = state.image(for: key) {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: Dock.keyCorner - 5))
                } else {
                    Image(systemName: "plus")
                        .font(.system(size: 15, weight: .light))
                        .foregroundStyle(.white.opacity(0.16))
                }
            }
            .padding(Dock.keyBezel)
        }
        .overlay {
            RoundedRectangle(cornerRadius: Dock.keyCorner)
                .strokeBorder(
                    selected ? Color.accentColor : (pressed ? Color.green : .clear),
                    lineWidth: 2.5
                )
        }
        .shadow(color: .black.opacity(0.6), radius: 3, y: 1)
        .scaleEffect(pressed ? 0.93 : 1)
        .animation(.spring(duration: 0.2), value: pressed)
        .animation(.smooth(duration: 0.18), value: selected)
        .contentShape(.rect)
        .onTapGesture { state.selection = .key(slot) }
        .draggable(KeySlot(slot: slot)) {
            if let key, let image = state.image(for: key) {
                Image(nsImage: image).resizable().frame(width: 60, height: 60)
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
}

/// Dragging a key between slots carries only which slot it came from.
struct KeySlot: Codable, Transferable {
    let slot: Int

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .pultKeySlot)
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
