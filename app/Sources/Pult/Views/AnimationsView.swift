import SwiftUI

/// Animations: what a scene paints across the whole dock, and every setting
/// the motion honours.
///
/// Its own pane rather than a section inside the scene editor. A scene editor
/// is about what the six keys *do*; this is about what the dock *looks like*,
/// and the two are rarely changed in the same sitting — a canvas is chosen
/// once and then tuned, while bindings are edited constantly.
struct AnimationsView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        GeometryReader { geometry in
            let content = max(260, geometry.size.width - 56)

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Header(width: content)

                    if let name = state.drawing {
                        SurfaceSection(name: name, width: content)
                    } else {
                        Empty()
                    }
                }
                .padding(28)
                .frame(width: geometry.size.width, alignment: .leading)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }
}

/// Which drawing is being edited, and everything you can do to it.
///
/// The picker and the menu are here rather than in the sidebar because the
/// sidebar is about applications. A drawing is not one, and listing drawings
/// there too was the same names in two places, where the sidebar copy only
/// opened this pane anyway.
private struct Header: View {
    let width: CGFloat
    @EnvironmentObject private var state: AppState

    @State private var naming = false
    @State private var draft = ""
    @State private var renaming = false

    private var chosen: String? { state.drawing }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "waveform")
                    .font(.app(18, weight: .semibold))
                    .foregroundStyle(Design.accent)

                Text(T("nav.animations"))
                    .font(.app(24, weight: .semibold))

                Spacer(minLength: 16)

                Picker("", selection: Binding(
                    get: { chosen ?? "" },
                    set: { state.selectedDrawing = $0.isEmpty ? nil : $0 }
                )) {
                    // Drawings first and under their own heading: an
                    // application's scene can have a backdrop too, but that is
                    // the unusual case and should not head the list.
                    if !state.config.drawingScenes.isEmpty {
                        Section(T("nav.animations")) {
                            ForEach(state.config.drawingScenes, id: \.self) { name in
                                Text(name).tag(name)
                            }
                        }
                    }
                    Section(T("nav.scenes")) {
                        ForEach(state.config.keyScenes, id: \.self) { name in
                            Text(name).tag(name)
                        }
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 220)

                Menu {
                    Button(T("animations.new")) {
                        draft = ""
                        renaming = false
                        naming = true
                    }
                    if let chosen {
                        Button(T("animations.rename")) {
                            draft = chosen
                            renaming = true
                            naming = true
                        }
                        Button(T("scene.show")) { state.show(scene: chosen) }
                        Divider()
                        Button(T("scene.delete"), role: .destructive) {
                            state.deleteScene(chosen)
                        }
                        .disabled(chosen == state.config.defaultScene)
                    }
                } label: {
                    Image(systemName: "ellipsis.circle").font(.app(15))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help(T("scene.menu"))
            }

            Text(T("animations.says"))
                .font(.appCallout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: width, alignment: .leading)
        .popover(isPresented: $naming) {
            VStack(alignment: .leading, spacing: 10) {
                Text(renaming ? T("animations.rename") : T("animations.new"))
                    .font(.appHeadline)
                TextField(T("animations.name"), text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
                    .onSubmit { commit() }
                HStack {
                    Spacer()
                    Button(T("close")) { naming = false }
                        .buttonStyle(.pult)
                        .keyboardShortcut(.cancelAction)
                    Button(renaming ? T("animations.rename") : T("animations.new")) { commit() }
                        .buttonStyle(.pultProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(16)
        }
    }

    private func commit() {
        let name = draft.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        if renaming, let chosen {
            state.renameScene(chosen, to: name)
        } else {
            state.addDrawing(named: name)
        }
        naming = false
    }
}

private struct Empty: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "rectangle.on.rectangle")
                .font(.app(30, weight: .light))
                .foregroundStyle(.tertiary)
            Text(T("animations.none"))
                .font(.appCallout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }
}
