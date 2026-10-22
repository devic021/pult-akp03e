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
    var body: some View {
        NavigationSplitView {
            Sidebar(panel: $state.panel)
                .navigationSplitViewColumnWidth(min: 210, ideal: 240, max: 330)
        } detail: {
            ZStack {
                Backdrop()
                Group {
                    switch state.panel {
                    case .scenes: SceneEditor()
                    case .device: DeviceView()
                    case .settings: SettingsView()
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .safeAreaInset(edge: .bottom, spacing: 0) { StatusBar() }
        }
        // Anything that does not name a font inherits this one, which is how
        // list rows, menus and button labels follow the text-size setting too.
        .environment(\.font, .appBody)
        .preferredColorScheme(theme.appearance.colorScheme)
        // Both the text and its size are resolved by functions rather than by
        // the environment, so SwiftUI cannot know a view depends on them: the
        // tree is rebuilt when either changes. Which pane is open lives in
        // AppState precisely so that it survives this.
        .id("\(theme.textSize.rawValue)-\(l10n.resolved.rawValue)")
        .alert(T("error.title"), isPresented: .constant(state.error != nil)) {
            Button("OK") { state.error = nil }
        } message: {
            Text(state.error ?? "")
        }
    }
}

/// The window itself: flat and neutral. A gradient behind everything is what
/// made the first version read as a poster rather than as an application.
private struct Backdrop: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Design.window(scheme).ignoresSafeArea()
    }
}

private struct Sidebar: View {
    @EnvironmentObject private var state: AppState
    @Binding var panel: Panel
    @State private var newScene = ""
    @State private var adding = false

    var body: some View {
        VStack(spacing: 0) {
            Identity()
            DockCard()
                .padding(.horizontal, 10)
                .padding(.bottom, 10)

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
                        // A tap gesture inside a List loses the first click to
                        // the list's own selection; a button does not.
                        Button {
                            panel = item
                        } label: {
                            HStack(spacing: 9) {
                                Image(systemName: item.symbol)
                                    .frame(width: 18)
                                    .foregroundStyle(
                                        panel == item ? AnyShapeStyle(Design.accent) : AnyShapeStyle(.secondary)
                                    )
                                Text(item.label)
                                    .font(.appBody.weight(panel == item ? .semibold : .regular))
                                Spacer()
                            }
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(
                            panel == item
                                ? AnyView(RoundedRectangle(cornerRadius: 7).fill(Design.pill(.dark)))
                                : AnyView(Color.clear)
                        )
                    }
                } header: {
                    SidebarHeading(T("sidebar.setup"))
                }

                Section {
                    ForEach(state.config.sceneNames, id: \.self) { name in
                        SceneRow(name: name).tag(name)
                    }
                } header: {
                    SidebarHeading(T("nav.scenes"))
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 8) {
                if adding {
                    TextField(T("scene.new"), text: $newScene)
                        .textFieldStyle(.roundedBorder)
                        .font(.appBody)
                        .onSubmit(commit)
                        .onExitCommand { adding = false; newScene = "" }
                }
                Button {
                    if adding { commit() } else { adding = true }
                } label: {
                    Label(T("scene.new"), systemImage: "plus")
                        .font(.appBody)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.pult)
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

/// The app, named and versioned, at the top of the sidebar where the reference
/// interface puts it: you always know what you are looking at.
private struct Identity: View {
    var body: some View {
        HStack(spacing: 10) {
            if let icon = NSApp.applicationIconImage {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 30, height: 30)
                    .clipShape(RoundedRectangle(cornerRadius: 7))
            }
            VStack(alignment: .leading, spacing: 0) {
                Text("Pult").font(.app(15, weight: .semibold))
                Text("v\(About.version)")
                    .font(.appCaption)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 12)
    }
}

/// The dock being driven, as a card: what it is, and whether it is answering.
private struct DockCard: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(Design.accentSoft)
                Image(systemName: "dial.medium")
                    .font(.app(13, weight: .medium))
                    .foregroundStyle(Design.accent)
            }
            .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 1) {
                Text(state.status?.device?.kind ?? T("device.disconnected"))
                    .font(.appCallout.weight(.medium))
                    .lineLimit(1)
                if let device = state.status?.device {
                    Text(device.serial)
                        .font(.appCaption2.monospaced())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }

            Spacer()

            Circle()
                .fill(state.connected ? Design.good : Design.warn)
                .frame(width: 7, height: 7)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .card(radius: 10)
        .help(state.connected ? T("help.connected") : T("help.disconnected"))
    }
}

/// The small upper-case label above a group of sidebar rows.
private struct SidebarHeading: View {
    let title: String

    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title)
            .font(.appCaption2.weight(.semibold))
            .foregroundStyle(.tertiary)
            .textCase(.uppercase)
            .tracking(0.6)
    }
}

private struct SceneRow: View {
    @EnvironmentObject private var state: AppState
    let name: String
    @State private var hovering = false

    private var scene: DeckScene? { state.config.scenes[name] }

    var body: some View {
        HStack(spacing: 7) {
            Text(name).font(.appBody)
            Spacer()

            if let scene, scene.pages() > 1 {
                Text("\(scene.pages())")
                    .font(.appCaption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .help(T("help.page"))
            }
            if name == state.config.defaultScene {
                Image(systemName: "star.fill")
                    .font(.app(8))
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
                Image(systemName: "arrow.right").font(.appCaption2).foregroundStyle(.quaternary)
                HStack(spacing: 5) {
                    Image(systemName: "square.grid.2x2").foregroundStyle(.tint)
                    Text(scene).foregroundStyle(.secondary)
                    if let pages = state.status?.pages, pages > 1 {
                        Text("\((state.status?.page ?? 0) + 1)/\(pages)")
                            .font(.appCaption.monospacedDigit())
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
                    .buttonStyle(.pult)
                    .help(T("help.revert"))
                Button(T("status.save")) { state.save() }
                    .buttonStyle(.pultProminent)
                    .keyboardShortcut("s")
                    .help(T("help.save"))
            } else {
                Label(T("status.saved"), systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.appCallout)
        .controlSize(.small)
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(.ultraThinMaterial)
    }
}
