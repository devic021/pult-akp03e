import SwiftUI

@main
struct PultApp: App {
    @StateObject private var state = AppState()
    @StateObject private var l10n = L10n.shared
    @StateObject private var theme = Theme.shared

    init() {
        Typeface.register()

        // `Pult --selftest` checks the one thing a screenshot is needed for
        // otherwise: that everything the daemon sends still decodes here. The
        // two sides share a JSON contract and nothing but a run proves it.
        if CommandLine.arguments.contains("--selftest") {
            SelfTest.run()
        }
    }

    var body: some Scene {
        Window(T("app.name"), id: "main") {
            RootView()
                .environmentObject(state)
                .environmentObject(l10n)
                .environmentObject(theme)
                .frame(minWidth: 1000, minHeight: 640)
                .task {
                    state.start()
                    state.watchRunningApps()
                }
        }
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1180, height: 760)

        MenuBarExtra(T("app.name"), systemImage: "square.grid.2x2.fill") {
            MenuContent()
                .environmentObject(state)
                .environmentObject(l10n)
                .environmentObject(theme)
        }
    }
}

/// The menu bar item: what is on screen right now, and a way back to the window.
private struct MenuContent: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if let status = state.status {
            Text("\(T("status.scene")): \(status.scene ?? "–")")
            if let app = status.app {
                Text("\(T("status.front")): \(app)")
            }
            Divider()
        }

        Button(T("menu.open")) {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Divider()
        Button(T("menu.quit")) { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }
}
