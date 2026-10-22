import SwiftUI

/// Edits one action. Every place a key can be bound uses this, so adding an
/// action kind later shows up everywhere at once.
struct ActionEditor: View {
    @Binding var action: Action
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker(compact ? "" : T("action.title"), selection: Binding(
                get: { action.kind },
                set: { action.become($0) }
            )) {
                ForEach(Action.Kind.allCases) { kind in
                    Text(kind.label).tag(kind)
                }
            }
            .labelsHidden(compact)

            switch action.kind {
            case .none:
                EmptyView()

            case .run:
                TextField("", text: Binding(
                    get: { action.run ?? "" },
                    set: { action.run = $0 }
                ), prompt: Text("open -a Finder"))
                .textFieldStyle(.roundedBorder)
                .font(.callout.monospaced())
                if !compact {
                    Text(T("action.run.help")).font(.caption).foregroundStyle(.secondary)
                }

            case .shortcut:
                TextField("", text: Binding(
                    get: { action.shortcut ?? "" },
                    set: { action.shortcut = $0 }
                ), prompt: Text("cmd+shift+4"))
                .textFieldStyle(.roundedBorder)
                .font(.callout.monospaced())
                if !compact {
                    Text(T("action.shortcut.help")).font(.caption).foregroundStyle(.secondary)
                }

            case .volume:
                Stepper(value: Binding(
                    get: { action.volume ?? 5 },
                    set: { action.volume = $0 }
                ), in: -50...50, step: 1) {
                    Text("\(action.volume ?? 5 > 0 ? "+" : "")\(action.volume ?? 5)")
                        .font(.callout.monospacedDigit())
                }

            case .scene:
                SceneChooser(selection: Binding(
                    get: { action.scene ?? "" },
                    set: { action.scene = $0 }
                ))

            case .page:
                Picker("", selection: Binding(
                    get: { action.page ?? .next },
                    set: { action.page = $0 }
                )) {
                    ForEach(PageTurn.allCases) { turn in
                        Text(turn.label).tag(turn)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }
        }
    }
}

private struct SceneChooser: View {
    @EnvironmentObject private var state: AppState
    @Binding var selection: String

    var body: some View {
        Picker("", selection: $selection) {
            Text("—").tag("")
            ForEach(state.config.sceneNames, id: \.self) { name in
                Text(name).tag(name)
            }
        }
        .labelsHidden()
    }
}

/// A labelled action, for the knob and button grids.
struct ActionRow: View {
    let title: String
    @Binding var action: Action

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !title.isEmpty {
                Text(title).font(.caption).foregroundStyle(.secondary)
            }
            ActionEditor(action: $action, compact: true)
        }
    }
}

extension View {
    /// `labelsHidden()` takes no argument, but half these controls are drawn
    /// twice: once with a label in the inspector, once bare in a grid.
    @ViewBuilder
    func labelsHidden(_ hidden: Bool) -> some View {
        if hidden { labelsHidden() } else { self }
    }
}
