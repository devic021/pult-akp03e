import SwiftUI

enum Panel: String, CaseIterable, Identifiable {
    case scenes, device, settings

    var id: String { rawValue }
    var label: String { T("nav.\(rawValue)") }
    var symbol: String {
        switch self {
        case .scenes: return "square.grid.2x2"
        case .device: return "dial.medium"
        case .settings: return "gearshape"
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var l10n: L10n
    @EnvironmentObject private var theme: Theme
    @State private var panel: Panel = .scenes

    var body: some View {
        NavigationSplitView {
            Sidebar(panel: $panel)
                .navigationSplitViewColumnWidth(min: 210, ideal: 230, max: 300)
        } detail: {
            ZStack {
                Backdrop()
                Group {
                    switch panel {
                    case .scenes: SceneEditor()
                    case .device: DeviceView()
                    case .settings: SettingsView()
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .safeAreaInset(edge: .bottom, spacing: 0) { StatusBar() }
        }
        .preferredColorScheme(theme.appearance.colorScheme)
        .alert(T("error.title"), isPresented: .constant(state.error != nil)) {
            Button("OK") { state.error = nil }
        } message: {
            Text(state.error ?? "")
        }
    }
}

/// Something for the glass to refract. Flat panels on a flat background are
/// what made the first version look like a form.
private struct Backdrop: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            Rectangle().fill(.background)

            RadialGradient(
                colors: [Color.accentColor.opacity(scheme == .dark ? 0.22 : 0.14), .clear],
                center: .topLeading,
                startRadius: 10,
                endRadius: 760
            )

            RadialGradient(
                colors: [Color.purple.opacity(scheme == .dark ? 0.16 : 0.09), .clear],
                center: .bottomTrailing,
                startRadius: 10,
                endRadius: 680
            )
        }
        .ignoresSafeArea()
    }
}

private struct Sidebar: View {
    @EnvironmentObject private var state: AppState
    @Binding var panel: Panel
    @State private var newScene = ""
    @State private var adding = false

    var body: some View {
        List(selection: Binding(
            get: { state.selectedScene },
            set: { name in
                guard let name else { return }
                state.selectedScene = name
                state.page = 0
                state.selection = nil
                panel = .scenes
            }
        )) {
            Section {
                ForEach(Panel.allCases) { item in
                    HStack(spacing: 8) {
                        Image(systemName: item.symbol)
                            .frame(width: 18)
                            .foregroundStyle(panel == item ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                        Text(item.label)
                            .fontWeight(panel == item ? .semibold : .regular)
                        Spacer()
                    }
                    .contentShape(.rect)
                    .onTapGesture { panel = item }
                }
            }

            Section(T("nav.scenes")) {
                ForEach(state.config.sceneNames, id: \.self) { name in
                    SceneRow(name: name).tag(name)
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 8) {
                if adding {
                    TextField(T("scene.new"), text: $newScene)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(commit)
                        .onExitCommand { adding = false; newScene = "" }
                }
                Button {
                    if adding { commit() } else { adding = true }
                } label: {
                    Label(T("scene.new"), systemImage: "plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
            }
            .padding(10)
        }
    }

    private func commit() {
        state.addScene(named: newScene.trimmingCharacters(in: .whitespaces))
        newScene = ""
        adding = false
        panel = .scenes
    }
}

private struct SceneRow: View {
    @EnvironmentObject private var state: AppState
    let name: String

    private var scene: DeckScene? { state.config.scenes[name] }

    var body: some View {
        HStack(spacing: 7) {
            Text(name)
            Spacer()
            if let scene, scene.pages() > 1 {
                Text("\(scene.pages())")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            if name == state.config.defaultScene {
                Image(systemName: "star.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(.yellow.opacity(0.8))
            }
            if state.status?.scene == name {
                Circle().fill(.green).frame(width: 7, height: 7)
            }
        }
        .contextMenu {
            Button(T("scene.default")) { state.config.defaultScene = name }
            Button(T("scene.show")) { state.show(scene: name) }
            Divider()
            Button(T("scene.delete"), role: .destructive) { state.deleteScene(name) }
                .disabled(name == state.config.defaultScene)
        }
    }
}

/// The one line that is always visible: connection, what is in front, and the
/// state of unsaved work.
private struct StatusBar: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(state.connected ? Color.green : Color.secondary)
                .frame(width: 8, height: 8)
            Text(state.connected ? T("status.connected") : T("status.disconnected"))
                .foregroundStyle(.secondary)

            if let device = state.status?.device {
                Text("·").foregroundStyle(.quaternary)
                Text(device.kind).foregroundStyle(.tertiary)
            }
            if let app = state.status?.app {
                Text("·").foregroundStyle(.quaternary)
                Text(app).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
            }

            Spacer()

            if state.dirty {
                Label(T("status.unsaved"), systemImage: "pencil.circle.fill")
                    .foregroundStyle(.orange)
                Button(T("status.revert")) { state.revert() }
                    .buttonStyle(.glass)
                Button(T("status.save")) { state.save() }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut("s")
            } else {
                Label(T("status.saved"), systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .controlSize(.small)
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(.ultraThinMaterial)
    }
}
