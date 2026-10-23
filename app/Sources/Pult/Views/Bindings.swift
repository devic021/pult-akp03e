import SwiftUI

/// A line of counts under the dock: enough to know the shape of a scene at a
/// glance, without the whole table being in the way.
struct SceneSummary: View {
    @EnvironmentObject private var state: AppState
    let scene: DeckScene
    @State private var showingTable = false

    private var boundKeys: Int { scene.keys.filter { !$0.isBlank }.count }
    private var boundKnobs: Int {
        scene.encoders.filter { !$0.cw.isEmpty || !$0.ccw.isEmpty || !$0.press.isEmpty }.count
    }
    private var boundButtons: Int { scene.buttons.filter { !$0.isEmpty }.count }

    var body: some View {
        HStack(spacing: 10) {
            Text(T("hint.device"))
                .font(.appCaption)
                .foregroundStyle(.secondary)

            Spacer()

            Text(counts)
                .font(.appCaption.monospacedDigit())
                .foregroundStyle(.tertiary)

            Button {
                showingTable = true
            } label: {
                Label(T("bindings.open"), systemImage: "list.bullet.rectangle")
                    .font(.appCaption)
            }
            .buttonStyle(.pult)
            .controlSize(.small)
            .help(T("bindings.title"))
        }
        .sheet(isPresented: $showingTable) {
            BindingsTable(scene: scene, dismiss: { showingTable = false })
        }
    }

    private var counts: String {
        var parts = ["\(boundKeys) \(T("count.keys"))"]
        if boundKnobs > 0 { parts.append("\(boundKnobs) \(T("count.knobs"))") }
        if boundButtons > 0 { parts.append("\(boundButtons) \(T("count.buttons"))") }
        if scene.pages() > 1 { parts.append("\(scene.pages()) \(T("count.pages"))") }
        return parts.joined(separator: " · ")
    }
}

/// Everything this scene is bound to, on demand.
///
/// The dock panel shows where the controls are; this shows what they do,
/// without hovering over nine of them one at a time.
struct BindingsTable: View {
    @EnvironmentObject private var state: AppState
    let scene: DeckScene
    let dismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label(T("bindings.title"), systemImage: "list.bullet.rectangle")
                    .font(.appHeadline)
                Spacer()
                Button(T("close")) { dismiss() }
                    .buttonStyle(.pult)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(16)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    keys
                    knobs
                    buttons
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(
            minWidth: 460, idealWidth: 580, maxWidth: 820,
            minHeight: 380, idealHeight: 560, maxHeight: 760
        )
        .background(.ultraThinMaterial)
    }

    @ViewBuilder
    private var keys: some View {
        let bound = scene.keys.enumerated().filter { !$0.element.isBlank }
        if !bound.isEmpty {
            Group(T("scene.keys")) {
                ForEach(bound, id: \.offset) { index, key in
                    Row(
                        lead: place(forKey: index),
                        name: key.label.isEmpty ? (key.icon ?? "-") : key.label,
                        detail: key.action.summary
                    ) {
                        state.page = index / 6
                        state.selection = .key(index % 6)
                        dismiss()
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var knobs: some View {
        let bound = scene.encoders.enumerated().filter {
            !$0.element.cw.isEmpty || !$0.element.ccw.isEmpty || !$0.element.press.isEmpty
        }
        if !bound.isEmpty {
            Group(T("scene.encoders")) {
                ForEach(bound, id: \.offset) { index, knob in
                    // The knob is named once, with its three bindings under it,
                    // rather than repeated on every line.
                    Text(T("encoder.\(index)"))
                        .font(.appCallout.weight(.medium))
                        .padding(.top, 2)

                    ForEach(parts(of: knob), id: \.0) { part, action in
                        Row(lead: symbol(part), name: T("encoder.\(part)"), detail: action.summary) {
                            state.selection = .knob(index, knobPart(part))
                            dismiss()
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var buttons: some View {
        let bound = scene.buttons.enumerated().filter { !$0.element.isEmpty }
        if !bound.isEmpty {
            Group(T("scene.buttons")) {
                ForEach(bound, id: \.offset) { index, action in
                    Row(lead: "\(index + 1)", name: "", detail: action.summary) {
                        state.selection = .button(index)
                        dismiss()
                    }
                }
            }
        }
    }

    /// Which page and slot a key sits on, since a scene can run to several.
    private func place(forKey index: Int) -> String {
        let page = index / 6 + 1
        let slot = index % 6 + 1
        return scene.pages() > 1 ? "\(page)·\(slot)" : "\(slot)"
    }

    private func parts(of knob: Knob) -> [(String, Action)] {
        [("ccw", knob.ccw), ("cw", knob.cw), ("press", knob.press)].filter { !$0.1.isEmpty }
    }

    private func symbol(_ part: String) -> String {
        switch part {
        case "ccw": return "↺"
        case "cw": return "↻"
        default: return "⌾"
        }
    }

    private func knobPart(_ name: String) -> Knob.Part {
        switch name {
        case "ccw": return .ccw
        case "press": return .press
        default: return .cw
        }
    }

    private struct Group<Content: View>: View {
        let title: String
        @ViewBuilder let rows: Content

        init(_ title: String, @ViewBuilder rows: () -> Content) {
            self.title = title
            self.rows = rows()
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.appCaption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .textCase(.uppercase)
                rows
            }
        }
    }

    private struct Row: View {
        let lead: String
        let name: String
        let detail: String
        let reveal: () -> Void

        var body: some View {
            Button(action: reveal) {
                HStack(spacing: 12) {
                    Text(lead)
                        .font(.appCallout.monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .frame(width: 30, alignment: .leading)

                    Text(name)
                        .font(.appCallout)
                        .frame(minWidth: 90, idealWidth: 130, maxWidth: 160, alignment: .leading)
                        .lineLimit(1)

                    Text(detail)
                        .font(.appCallout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.appCaption2)
                        .foregroundStyle(.quaternary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
        }
    }
}
