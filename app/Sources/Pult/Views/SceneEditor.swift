import SwiftUI

/// The scene being edited, shown as the dock itself: the keys where the keys
/// are, the knobs where the knobs are. Clicking a control selects it; the
/// inspector beside it does the editing. Nothing here starts work — the grid
/// asks for its art once per page through `prefetch`.
struct SceneEditor: View {
    @EnvironmentObject private var state: AppState

    /// Below this, the inspector stops being a column and becomes a sheet:
    /// two panes in 400 points is two unusable panes.
    private static let inspectorThreshold: CGFloat = 820

    var body: some View {
        if let name = state.selectedScene, let scene = state.config.scenes[name] {
            // One reader decides every width. Measuring inside a split view
            // made the measurement depend on the content being measured, which
            // is why the drawing kept overflowing the pane it was sized from.
            GeometryReader { geometry in
                let showsInspector = geometry.size.width >= Self.inspectorThreshold
                let inspectorWidth = showsInspector
                    ? min(380, max(280, geometry.size.width * 0.28))
                    : 0
                let editorWidth = geometry.size.width - inspectorWidth

                HStack(spacing: 0) {
                    Editor(name: name, scene: scene, width: editorWidth)
                        .frame(width: editorWidth)

                    if showsInspector {
                        Divider()
                        Inspector()
                            .frame(width: inspectorWidth)
                    }
                }
                .sheet(isPresented: .constant(!showsInspector && state.selection != nil)) {
                    NarrowInspector()
                }
            }
            .task(id: TaskKey(scene: name, page: state.page, keys: scene.keys)) {
                state.prefetchCurrentPage()
            }
        } else {
            EmptyState(symbol: "square.grid.2x2", title: T("nav.scenes"))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Changes to any of these mean the page needs new art.
    private struct TaskKey: Equatable {
        let scene: String
        let page: Int
        let keys: [Key]
    }
}

/// The editor pane. Every child is bounded by the width handed down, so
/// nothing can push the page out from under the sidebar.
private struct Editor: View {
    let name: String
    let scene: DeckScene
    let width: CGFloat

    private var content: CGFloat { max(260, width - 56) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                SceneHeader(name: name, scene: scene, width: content)

                // The dock and the line under it stay centred at every scale:
                // it is a picture of a thing on a desk, not a paragraph.
                VStack(spacing: 10) {
                    FittedDock(available: content) {
                        DevicePanel(name: name, scene: scene)
                    }

                    SceneSummary(scene: scene)
                        .frame(width: min(content, Dock.body.width))
                }
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .padding(28)
            .frame(width: width, alignment: .leading)
        }
        .scrollBounceBehavior(.basedOnSize)
    }
}

/// The inspector as a sheet, for windows too narrow to hold a second column.
private struct NarrowInspector: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button(T("close")) { state.selection = nil }
                    .buttonStyle(.pult)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(12)

            Divider()
            Inspector()
        }
        .frame(width: 380, height: 560)
    }
}

/// Scales the drawing of the dock to whatever width there is.
///
/// Its proportions are the hardware's, so it cannot reflow like text; it
/// shrinks as one piece instead. The second frame matters: `scaleEffect` only
/// changes what is drawn, not the space the view asks for, so without it the
/// drawing keeps demanding its full width and pushes the whole page out from
/// under the sidebar.
private struct FittedDock<Content: View>: View {
    /// How much room there is, measured by whoever owns the pane.
    let available: CGFloat
    @ViewBuilder let content: Content

    private var factor: CGFloat {
        guard available > 0 else { return 1 }
        return min(1, available / Dock.body.width)
    }

    var body: some View {
        content
            .frame(width: Dock.body.width, height: Dock.body.height)
            .scaleEffect(factor, anchor: .topLeading)
            // `scaleEffect` only changes what is drawn, not the space the view
            // asks for, so the scaled size has to be stated again here.
            // Aligned, not centred: the scale runs from the top-leading corner,
            // so a centred box would let the drawing ride up over the row above.
            .frame(
                width: Dock.body.width * factor,
                height: Dock.body.height * factor,
                alignment: .topLeading
            )
    }
}

// MARK: - Header

private struct SceneHeader: View {
    @EnvironmentObject private var state: AppState
    let name: String
    let scene: DeckScene
    let width: CGFloat
    @State private var renaming = false
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Wide enough and it is one row; narrow and the controls drop to a
            // row of their own rather than squeezing the title into "gene ral".
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 10) {
                    title
                    Spacer(minLength: 16)
                    controls
                }
                .frame(width: width, alignment: .leading)

                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 10) { title; Spacer(minLength: 0) }
                    HStack(spacing: 8) { controls; Spacer(minLength: 0) }
                }
                .frame(width: width, alignment: .leading)
            }

            AppChips(name: name, apps: scene.apps)
                .frame(width: width, alignment: .leading)
        }
    }

    @ViewBuilder
    private var title: some View {
        if renaming {
            TextField("", text: $draft)
                .textFieldStyle(.roundedBorder)
                .font(.app(22, weight: .semibold))
                .frame(maxWidth: 280)
                .onSubmit {
                    state.renameScene(name, to: draft)
                    renaming = false
                }
                .onExitCommand { renaming = false }
        } else {
            HStack(spacing: 10) {
                Badge(symbol: "square.grid.2x2", size: 34)
                Text(name)
                    .font(.app(26, weight: .semibold))
                    .lineLimit(1)
                    .fixedSize()

                Button {
                    draft = name
                    renaming = true
                } label: {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.pult)
                .controlSize(.small)
                .help(T("scene.rename"))

                if name == state.config.defaultScene {
                    Image(systemName: "star.fill")
                        .font(.app(11))
                        .foregroundStyle(.yellow)
                        .help(T("help.default"))
                }
            }
        }
    }

    @ViewBuilder
    private var controls: some View {
        if state.pages > 1 {
            PagePicker()
        }

        Button {
            state.addPage()
        } label: {
            Label(T("scene.page.add"), systemImage: "plus.rectangle.on.rectangle")
                .font(.appCallout)
                .fixedSize()
        }
        .buttonStyle(.pult)
        .help(T("help.page"))

        Button {
            state.show(scene: name)
        } label: {
            Label(T("scene.show"), systemImage: "play.fill")
                .font(.appCallout)
                .fixedSize()
        }
        .buttonStyle(.pult)
        .help(T("help.showScene"))
    }
}

/// Height the page chips share with the buttons beside them.
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
                        .font(.appCallout.weight(.medium))
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
        .chip()
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
                    .font(.appSubheadline)
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
                        .font(.appCallout)
                        .padding(.horizontal, 4)
                        .frame(height: chipHeight - 8)
                }
                .buttonStyle(.pult)
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
                    .font(.appCaption)
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
