import SwiftUI

enum Panel: String, CaseIterable, Identifiable {
    case scenes, animations, screensaver, device, settings

    var id: String { rawValue }
    var label: String { T("nav.\(rawValue)") }

    /// ⌘1 to ⌘5 — the panes are few and fixed, so they get numbers.
    var shortcut: KeyEquivalent {
        switch self {
        case .scenes: return "1"
        case .animations: return "2"
        case .screensaver: return "3"
        case .device: return "4"
        case .settings: return "5"
        }
    }
    var symbol: String {
        switch self {
        case .scenes: return "square.grid.2x2"
        case .animations: return "waveform"
        case .screensaver: return "moon.stars"
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
        // Never having had a configuration is a different situation from
        // having lost one, and it gets its own screen: the ordinary window
        // rendered with nothing in it came up as an empty frame.
        if state.loaded {
            main
        } else {
            Welcome()
                .environmentObject(state)
                .environment(\.font, .appBody)
                .preferredColorScheme(theme.appearance.colorScheme)
                .id("\(theme.textSize.rawValue)-\(l10n.resolved.rawValue)")
        }
    }

    private var main: some View {
        NavigationSplitView {
            Sidebar(panel: $state.panel)
                .navigationSplitViewColumnWidth(min: 210, ideal: 240, max: 330)
        } detail: {
            ZStack {
                Backdrop()
                Group {
                    switch state.panel {
                    case .scenes: SceneEditor()
                    case .animations: AnimationsView()
                    case .screensaver: ScreensaverView()
                    case .device: DeviceView()
                    case .settings: SettingsView()
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .safeAreaInset(edge: .top, spacing: 0) { FirstRun() }
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
/// Shared with the first-run screen, so the window looks like the same app
/// before anything has loaded as it does afterwards.
struct Backdrop: View {
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
                        .keyboardShortcut(item.shortcut, modifiers: .command)
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
                    ForEach(state.config.keyScenes, id: \.self) { name in
                        SceneRow(name: name).tag(name)
                    }
                } header: {
                    SidebarHeading(T("nav.scenes"))
                }

                // Drawings are deliberately not listed here. They live in the
                // Animations pane, which both lists them and is the only place
                // that can edit one — a second list in the sidebar was the
                // same set of names twice, and the one in the sidebar opened
                // the pane anyway.
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

/// A scene wears the icon of the first application it claims: the browser
/// scene shows the browser. Scenes nothing claims fall back to a mark.
private struct SceneIcon: View {
    @EnvironmentObject private var state: AppState
    @StateObject private var installed = Installed.shared
    let name: String

    private var bundleID: String? {
        state.config.scenes[name]?.apps.first
    }

    var body: some View {
        Group {
            if let bundleID,
               let app = installed.apps.first(where: { $0.bundleID == bundleID }) {
                Image(nsImage: installed.icon(for: app))
                    .resizable()
                    .frame(width: 16, height: 16)
            } else if let bundleID, let icon = state.runningIcons[bundleID] {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 16, height: 16)
            } else {
                Image(systemName: "square.grid.2x2")
                    .font(.app(11))
                    .foregroundStyle(.tertiary)
                    .frame(width: 16, height: 16)
            }
        }
        .task { installed.load() }
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
        HStack(spacing: 8) {
            SceneIcon(name: name)
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

/// Shown when the dock is silent because nothing is driving it.
///
/// A copy dragged out of a disk image has an app and a daemon but no login
/// agent, so it comes up connected to nothing. Leaving that to be discovered
/// in Settings means the first thing a new copy does is look broken, so it
/// says what is wrong and fixes it in one press — and it is gone the moment
/// there is nothing to fix.
private struct FirstRun: View {
    @EnvironmentObject private var state: AppState
    @State private var working = false

    private var needed: Bool {
        !state.connected && (!Service.isInstalled || !Service.isCurrent)
    }

    var body: some View {
        if needed {
            HStack(spacing: 12) {
                Image(systemName: "bolt.horizontal.circle")
                    .font(.app(16, weight: .semibold))
                    .foregroundStyle(Design.warn)

                VStack(alignment: .leading, spacing: 2) {
                    Text(Service.isInstalled ? T("service.repair") : T("service.install"))
                        .font(.appHeadline)
                    Text(Service.isInstalled
                        ? T("service.repair.help")
                        : T("service.install.help"))
                        .font(.appCallout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 12)

                Button(Service.isInstalled ? T("service.repair.go") : T("service.install.go")) {
                    working = true
                    _ = Service.install()
                    // launchd has the job the moment bootstrap returns, but the
                    // daemon still has to open the device and the socket.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                        state.refresh()
                        working = false
                    }
                }
                .buttonStyle(.pultProminent)
                .disabled(working)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial)
            .overlay(alignment: .bottom) {
                Rectangle().fill(.white.opacity(0.10)).frame(height: 1)
            }
        }
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
