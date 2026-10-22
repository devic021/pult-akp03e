import SwiftUI
import UniformTypeIdentifiers

/// Settings as one page: titled sections, run down the page, each holding
/// full-width rows. A row carries its icon, its name and a line saying what it
/// does on the left, and its control — switch, button, slider — on the right.
///
/// No tabs: a page you scroll is one thing to read, where tabs are four things
/// to find, and nothing here is long enough to need hiding.
struct SettingsView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var l10n: L10n
    @EnvironmentObject private var theme: Theme

    @State private var loaded = true
    @State private var exportMessage: String?

    private var allowed: Bool { state.status?.keystrokes_allowed ?? false }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                PageHeader(T("nav.settings"), symbol: "gearshape", intro: T("settings.intro"))

                Section2(T("section.look"), symbol: "paintbrush") {
                    ActionCard(
                        T("settings.theme"),
                        symbol: "circle.lefthalf.filled",
                        detail: T("settings.theme.help")
                    ) {
                        Picker("", selection: $theme.appearance) {
                            ForEach(Appearance.allCases) { appearance in
                                Text(appearance.label).tag(appearance)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .fixedSize()
                    }

                    ActionCard(
                        T("settings.textSize"),
                        symbol: "textformat.size",
                        detail: T("settings.textSize.help")
                    ) {
                        Picker("", selection: $theme.textSize) {
                            ForEach(TextSize.allCases) { size in
                                Text(size.label).tag(size)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .fixedSize()
                    }

                    ActionCard(
                        T("settings.language"),
                        symbol: "globe",
                        detail: T("settings.language.help")
                    ) {
                        Picker("", selection: l10n.languageBinding) {
                            ForEach(Language.allCases) { language in
                                Text(language.label).tag(language)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .fixedSize()
                    }
                }

                Section2(T("section.behaviour"), symbol: "slider.horizontal.3") {
                    ActionCard(
                        T("settings.pressFeedback.short"),
                        symbol: "hand.tap",
                        detail: T("settings.pressFeedback.help")
                    ) {
                        Toggle("", isOn: $state.config.press_feedback)
                            .labelsHidden()
                            .toggleStyle(.switch)
                    }

                    ActionCard(T("settings.poll.short"), symbol: "timer", detail: T("settings.poll.help")) {
                        HStack(spacing: 10) {
                            Slider(
                                value: Binding(
                                    get: { Double(state.config.poll_ms) },
                                    set: { state.config.poll_ms = Int($0) }
                                ),
                                in: 100...1000,
                                step: 50
                            )
                            .frame(width: 150)

                            Text("\(state.config.poll_ms) ms")
                                .font(.appCallout.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 58, alignment: .trailing)
                        }
                    }
                }

                Section2(T("section.service"), symbol: "bolt.horizontal") {
                    ActionCard(
                        T("service.title"),
                        symbol: "bolt.horizontal",
                        detail: state.connected ? T("help.connected") : T("help.disconnected"),
                        tinted: !state.connected
                    ) {
                        HStack(spacing: 10) {
                            Circle()
                                .fill(state.connected ? Design.good : Design.warn)
                                .frame(width: 8, height: 8)
                            Text(state.connected ? T("service.running") : T("service.stopped"))
                                .font(.appCallout)
                                .foregroundStyle(.secondary)
                            Button(T("service.restart")) { Service.restart() }
                                .buttonStyle(.pult)
                                .help(T("service.restart.help"))
                        }
                    }

                    ActionCard(T("service.login"), symbol: "power", detail: T("service.login.help")) {
                        Toggle("", isOn: Binding(
                            get: { loaded },
                            set: { value in
                                loaded = value
                                Service.setLoaded(value)
                            }
                        ))
                        .labelsHidden()
                        .toggleStyle(.switch)
                    }
                    .task { loaded = Service.isLoaded() }
                }

                Section2(T("section.files"), symbol: "folder") {
                    ActionCard(
                        T("settings.permission"),
                        symbol: allowed ? "checkmark.seal" : "exclamationmark.triangle",
                        detail: allowed ? T("settings.permission.ok") : T("settings.permission.missing"),
                        tinted: !allowed
                    ) {
                        if allowed {
                            Image(systemName: "checkmark.seal.fill")
                                .font(.app(18))
                                .foregroundStyle(Design.good)
                        } else {
                            Button(T("settings.permission.open")) {
                                NSWorkspace.shared.open(URL(
                                    string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
                                )!)
                            }
                            .buttonStyle(.pultProminent)
                        }
                    }

                    ActionCard(T("settings.export"), symbol: "doc.text", detail: T("settings.export.help")) {
                        VStack(alignment: .trailing, spacing: 6) {
                            HStack(spacing: 8) {
                                Button(T("settings.config.reveal")) { reveal() }
                                    .buttonStyle(.pult)
                                Button(T("settings.export.save")) { export() }
                                    .buttonStyle(.pult)
                                Button(T("settings.export.load")) { load() }
                                    .buttonStyle(.pult)
                            }
                            if let exportMessage {
                                Text(exportMessage).font(.appCaption).foregroundStyle(.secondary)
                            }
                        }
                    }

                    ActionCard(
                        T("settings.log.short"),
                        symbol: "list.bullet.rectangle",
                        detail: Service.logPath.path
                    ) {
                        Button(T("service.log.open")) { NSWorkspace.shared.open(Service.logPath) }
                            .buttonStyle(.pult)
                    }

                    ActionCard(T("settings.socket"), symbol: "cable.connector", detail: T("settings.socket.help")) {
                        Text(ControlClient.socketPath)
                            .font(.appCaption.monospaced())
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.head)
                            .frame(maxWidth: 230, alignment: .trailing)
                    }
                }

                Section2(T("section.overview"), symbol: "chart.bar") {
                    StatsCard()
                }

                Section2(T("section.about"), symbol: "info.circle") {
                    AboutRows()
                }
            }
            .padding(28)
            .frame(maxWidth: 880, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    private func reveal() {
        guard let path = state.status?.config_path else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    /// The configuration is one readable file; moving it between Macs should
    /// not mean hunting through a hidden directory.
    private func export() {
        guard let source = state.status?.config_path else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "pult-config.toml"
        panel.allowedContentTypes = [UTType(filenameExtension: "toml") ?? .plainText]
        guard panel.runModal() == .OK, let target = panel.url else { return }
        do {
            try Data(contentsOf: URL(fileURLWithPath: source)).write(to: target)
            exportMessage = T("settings.export.done")
        } catch {
            exportMessage = error.localizedDescription
        }
    }

    private func load() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "toml") ?? .plainText]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let source = panel.url,
              let target = state.status?.config_path
        else { return }

        do {
            // Written through the daemon's own path, so its watcher reloads it
            // and reports anything wrong with it.
            try Data(contentsOf: source).write(to: URL(fileURLWithPath: target))
            exportMessage = T("settings.export.loaded")
        } catch {
            exportMessage = error.localizedDescription
        }
    }
}

/// What the configuration adds up to.
private struct StatsCard: View {
    @EnvironmentObject private var state: AppState

    private var scenes: Int { state.config.scenes.count }
    private var keys: Int {
        state.config.scenes.values.reduce(0) { $0 + $1.keys.filter { !$0.isBlank }.count }
    }
    private var apps: Int { Set(state.config.scenes.values.flatMap(\.apps)).count }

    var body: some View {
        HStack(spacing: 10) {
            Stat(value: scenes, label: T("stats.scenes"))
            Stat(value: keys, label: T("stats.keys"))
            Stat(value: apps, label: T("stats.apps"))
            Stat(value: state.icons.count, label: T("stats.icons"))
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private struct Stat: View {
        @Environment(\.colorScheme) private var scheme
        let value: Int
        let label: String

        var body: some View {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(value)").font(.app(22, weight: .semibold).monospacedDigit())
                Text(label)
                    .font(.appCaption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 10).fill(Design.surface(scheme)))
        }
    }
}

private struct AboutRows: View {
    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            if let icon = NSApp.applicationIconImage {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 60, height: 60)
                    .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Pult").font(.app(20, weight: .semibold))
                Text("\(T("about.version")) \(About.version) (\(About.build)) · \(About.author)")
                    .font(.appCallout)
                    .foregroundStyle(.secondary)
                Text(About.device).font(.appCaption).foregroundStyle(.tertiary)
            }
            Spacer()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()

        ActionCard(T("about.title"), symbol: "text.alignleft", detail: T("about.summary")) {
            EmptyView()
        }

        ForEach(About.credits, id: \.0) { name, terms in
            ActionCard(name, symbol: "shippingbox", detail: terms) {
                EmptyView()
            }
        }
    }
}
