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
    @State private var section: Panel = .scenes

    var body: some View {
        NavigationSplitView {
            Sidebar(section: $section)
                .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
        } detail: {
            Group {
                switch section {
                case .scenes: SceneEditor()
                case .device: DeviceView()
                case .settings: SettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                // The window's own backdrop, so glass has something to refract.
                LinearGradient(
                    colors: [Color(nsColor: .windowBackgroundColor), Color(nsColor: .underPageBackgroundColor)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { StatusBar() }
        }
        .alert(T("error.title"), isPresented: .constant(state.error != nil && !state.connected)) {
            Button("OK") { state.error = nil }
        } message: {
            Text(state.error ?? "")
        }
    }
}

/// Sections on top, scenes underneath, so the list is one column rather than
/// a tab bar plus a list.
private struct Sidebar: View {
    @EnvironmentObject private var state: AppState
    @Binding var section: Panel
    @State private var newScene = ""
    @State private var adding = false

    var body: some View {
        List(selection: Binding(
            get: { state.selectedScene },
            set: { if let value = $0 { state.selectedScene = value; state.page = 0; section = .scenes } }
        )) {
            Section {
                ForEach(Panel.allCases) { item in
                    Label(item.label, systemImage: item.symbol)
                        .foregroundStyle(section == item ? Color.accentColor : .primary)
                        .contentShape(.rect)
                        .onTapGesture { section = item }
                }
            }

            Section(T("nav.scenes")) {
                ForEach(state.config.sceneNames, id: \.self) { name in
                    SceneRow(name: name)
                        .tag(name)
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 6) {
                if adding {
                    TextField(T("scene.new"), text: $newScene)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit {
                            state.addScene(named: newScene.trimmingCharacters(in: .whitespaces))
                            newScene = ""
                            adding = false
                            section = .scenes
                        }
                }
                Button {
                    adding.toggle()
                } label: {
                    Label(T("scene.new"), systemImage: "plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
            }
            .padding(8)
        }
    }
}

private struct SceneRow: View {
    @EnvironmentObject private var state: AppState
    let name: String

    var body: some View {
        HStack(spacing: 6) {
            Text(name)
            Spacer()
            if name == state.config.defaultScene {
                Image(systemName: "star.fill")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            if state.status?.scene == name {
                Circle()
                    .fill(Color.green)
                    .frame(width: 7, height: 7)
            }
        }
        .contextMenu {
            Button(T("scene.default")) { state.config.defaultScene = name }
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
        HStack(spacing: 12) {
            Circle()
                .fill(state.connected ? Color.green : Color.secondary)
                .frame(width: 8, height: 8)
            Text(state.connected ? T("status.connected") : T("status.disconnected"))
                .foregroundStyle(.secondary)

            if let device = state.status?.device {
                Text("· \(device.kind)").foregroundStyle(.tertiary)
            }
            if let app = state.status?.app {
                Text("· \(app)").foregroundStyle(.tertiary).lineLimit(1)
            }

            Spacer()

            if state.dirty {
                Text(T("status.unsaved")).foregroundStyle(.orange)
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
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
    }
}
