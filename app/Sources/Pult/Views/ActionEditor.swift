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

            case .app:
                AppField(bundleID: Binding(
                    get: { action.app ?? "" },
                    set: { action.app = $0 }
                ))

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

/// Picks an installed application, and offers to dress the key in its icon.
private struct AppField: View {
    @EnvironmentObject private var state: AppState
    @StateObject private var installed = Installed.shared
    @Binding var bundleID: String
    @State private var picking = false
    @State private var search = ""

    private var chosen: Installed.App? {
        installed.apps.first { $0.bundleID == bundleID }
    }

    private var matches: [Installed.App] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        return query.isEmpty
            ? installed.apps
            : installed.apps.filter {
                $0.name.lowercased().contains(query) || $0.bundleID.lowercased().contains(query)
            }
    }

    var body: some View {
        Button {
            picking = true
        } label: {
            HStack(spacing: 8) {
                if let chosen {
                    Image(nsImage: installed.icon(for: chosen))
                        .resizable().frame(width: 20, height: 20)
                    Text(chosen.name).lineLimit(1)
                } else {
                    Image(systemName: "app.dashed").foregroundStyle(.tertiary)
                    Text(bundleID.isEmpty ? T("action.app.choose") : bundleID).lineLimit(1)
                }
                Spacer()
                Image(systemName: "chevron.down").font(.caption2)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.glass)
        .task { installed.load() }
        .popover(isPresented: $picking, arrowEdge: .leading) {
            VStack(spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField(T("action.app.choose"), text: $search)
                        .textFieldStyle(.plain)
                }
                .padding(.horizontal, 10).padding(.vertical, 7)
                .glassEffect(in: .capsule)

                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(matches) { app in
                            Button {
                                choose(app)
                            } label: {
                                HStack(spacing: 9) {
                                    Image(nsImage: installed.icon(for: app))
                                        .resizable().frame(width: 22, height: 22)
                                    VStack(alignment: .leading, spacing: 0) {
                                        Text(app.name).lineLimit(1)
                                        Text(app.bundleID)
                                            .font(.caption2)
                                            .foregroundStyle(.tertiary)
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                }
                                .padding(.horizontal, 7).padding(.vertical, 4)
                                .contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                            .background {
                                if app.bundleID == bundleID {
                                    RoundedRectangle(cornerRadius: 7)
                                        .fill(Color.accentColor.opacity(0.3))
                                }
                            }
                        }
                    }
                }
            }
            .padding(12)
            .frame(width: 340, height: 400)
        }
    }

    /// Picking an application also names the key and gives it the real icon:
    /// typing a label and hunting for a picture is work the app can do.
    private func choose(_ app: Installed.App) {
        bundleID = app.bundleID
        picking = false

        guard case .key(let slot) = state.selection, var key = state.key(at: slot) else { return }
        key.app = app.bundleID
        if key.label.isEmpty { key.label = app.name }
        if key.icon == nil, let path = installed.exportIcon(for: app) {
            key.icon = path
        }
        state.setKey(key, at: slot)
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
