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
                .navigationSplitViewColumnWidth(min: 210, ideal: 240, max: 330)
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
        .environment(\.dynamicTypeSize, theme.textSize.dynamicTypeSize)
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
                    // A plain tap gesture inside a List loses the first click
                    // to the list's own selection; a button does not.
                    Button {
                        panel = item
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: item.symbol)
                                .frame(width: 18)
                                .foregroundStyle(
                                    panel == item ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary)
                                )
                            Text(item.label)
                                .fontWeight(panel == item ? .semibold : .regular)
                            Spacer()
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(
                        panel == item
                            ? AnyView(RoundedRectangle(cornerRadius: 6).fill(.selection))
                            : AnyView(Color.clear)
                    )
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
    @State private var hovering = false

    private var scene: DeckScene? { state.config.scenes[name] }

    var body: some View {
        HStack(spacing: 7) {
            Text(name)
            Spacer()

            if let scene, scene.pages() > 1 {
                Text("\(scene.pages())")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .help(T("help.page"))
            }
            if name == state.config.defaultScene {
                Image(systemName: "star.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(.yellow.opacity(0.8))
                    .help(T("help.default"))
            }
            if state.status?.scene == name {
                Circle()
                    .fill(.green)
                    .frame(width: 7, height: 7)
                    .help(T("help.activeScene"))
            }

            // A visible menu, not only a right click: a context menu is a
            // feature you have to already know about.
            Menu {
                menuItems
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 16)
            .opacity(hovering ? 1 : 0.25)
            .help(T("scene.menu"))
        }
        .onHover { hovering = $0 }
        .contextMenu { menuItems }
    }

    @ViewBuilder
    private var menuItems: some View {
        Button(T("scene.show")) { state.show(scene: name) }
        Button(T("scene.default")) { state.config.defaultScene = name }
        Divider()
        Button(T("scene.delete"), role: .destructive) { state.deleteScene(name) }
            .disabled(name == state.config.defaultScene)
    }
}

/// The line along the bottom. Every part of it says what it is: three bare
/// values with no labels is what the first version showed, and it read as
/// trivia rather than as the state of the system.
private struct StatusBar: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        HStack(spacing: 14) {
            HStack(spacing: 6) {
                Circle()
                    .fill(state.connected ? Color.green : Color.orange)
                    .frame(width: 8, height: 8)
                Text(state.connected ? T("status.connected") : T("status.disconnected"))
                    .foregroundStyle(state.connected ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
            }
            .help(state.connected ? T("help.connected") : T("help.disconnected"))

            if let device = state.status?.device {
                Divider().frame(height: 12)
                HStack(spacing: 5) {
                    Image(systemName: "dial.medium").foregroundStyle(.tertiary)
                    Text(device.kind).foregroundStyle(.secondary)
                }
                .help("\(T("help.device")) \(device.serial), \(device.firmware)")
            }

            if let bundleID = state.status?.app {
                Divider().frame(height: 12)
                HStack(spacing: 6) {
                    if let icon = state.runningIcons[bundleID] {
                        Image(nsImage: icon).resizable().frame(width: 15, height: 15)
                    }
                    Text("\(T("status.front")): \(state.name(ofApp: bundleID))")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .help("\(T("help.front"))\n\(bundleID)")
            }

            if let scene = state.status?.scene {
                Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.quaternary)
                HStack(spacing: 5) {
                    Image(systemName: "square.grid.2x2").foregroundStyle(.tint)
                    Text(scene).foregroundStyle(.secondary)
                    if let pages = state.status?.pages, pages > 1 {
                        Text("\((state.status?.page ?? 0) + 1)/\(pages)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                }
                .help(T("help.activeScene"))
            }

            Spacer()

            if state.dirty {
                Label(T("status.unsaved"), systemImage: "pencil.circle.fill")
                    .foregroundStyle(.orange)
                Button(T("status.revert")) { state.revert() }
                    .buttonStyle(.glass)
                    .help(T("help.revert"))
                Button(T("status.save")) { state.save() }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut("s")
                    .help(T("help.save"))
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
