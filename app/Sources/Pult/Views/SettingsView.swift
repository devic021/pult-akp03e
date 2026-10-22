import SwiftUI
import UniformTypeIdentifiers

/// Settings as cards, not as a form.
///
/// Every setting is one card: an icon, what it is called, a line saying what it
/// does, and its control on the right. There is no column of labels to collide
/// with the controls — which it did, twice — and each setting can explain
/// itself in place.
struct SettingsView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case look, behaviour, service, about

        var id: String { rawValue }
        var label: String { T("settings.tab.\(rawValue)") }
    }

    @State private var tab: Tab = .look

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                PageHeader(T("nav.settings"), symbol: "gearshape", intro: T("settings.intro"))

                Picker("", selection: $tab) {
                    ForEach(Tab.allCases) { tab in
                        Text(tab.label).tag(tab)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(maxWidth: 420)

                VStack(spacing: 12) {
                    switch tab {
                    case .look: LookTab()
                    case .behaviour: BehaviourTab()
                    case .service: ServiceTab()
                    case .about: AboutTab()
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: 860, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollBounceBehavior(.basedOnSize)
    }
}

// MARK: - Tabs

private struct LookTab: View {
    @EnvironmentObject private var l10n: L10n
    @EnvironmentObject private var theme: Theme

    var body: some View {
        ActionCard(T("settings.theme"), symbol: "circle.lefthalf.filled", detail: T("settings.theme.help")) {
            Picker("", selection: $theme.appearance) {
                ForEach(Appearance.allCases) { appearance in
                    Text(appearance.label).tag(appearance)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .fixedSize()
        }

        ActionCard(T("settings.textSize"), symbol: "textformat.size", detail: T("settings.textSize.help")) {
            Picker("", selection: $theme.textSize) {
                ForEach(TextSize.allCases) { size in
                    Text(size.label).tag(size)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .fixedSize()
        }

        ActionCard(T("settings.language"), symbol: "globe", detail: T("settings.language.help")) {
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
}

private struct BehaviourTab: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
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
                .frame(width: 160)

                Text("\(state.config.poll_ms) ms")
                    .font(.appCallout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 58, alignment: .trailing)
            }
        }

        StatsCard()
    }
}

private struct ServiceTab: View {
    @EnvironmentObject private var state: AppState
    @State private var loaded = true
    @State private var exportMessage: String?

    private var allowed: Bool { state.status?.keystrokes_allowed ?? false }

    var body: some View {
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
                    Button(T("settings.config.reveal")) {
                        if let path = state.status?.config_path {
                            NSWorkspace.shared.activateFileViewerSelecting([
                                URL(fileURLWithPath: path)
                            ])
                        }
                    }
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

        ActionCard(T("settings.log.short"), symbol: "list.bullet.rectangle", detail: Service.logPath.path) {
            Button(T("service.log.open")) { NSWorkspace.shared.open(Service.logPath) }
                .buttonStyle(.pult)
        }

        ActionCard(T("settings.socket"), symbol: "cable.connector", detail: T("settings.socket.help")) {
            Text(ControlClient.socketPath)
                .font(.appCaption.monospaced())
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.head)
                .frame(maxWidth: 240, alignment: .trailing)
        }
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
            let data = try Data(contentsOf: URL(fileURLWithPath: source))
            try data.write(to: target)
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
            let data = try Data(contentsOf: source)
            try data.write(to: URL(fileURLWithPath: target))
            exportMessage = T("settings.export.loaded")
        } catch {
            exportMessage = error.localizedDescription
        }
    }
}

private struct AboutTab: View {
    var body: some View {
        VStack(spacing: 12) {
            HStack(alignment: .center, spacing: 16) {
                if let icon = NSApp.applicationIconImage {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 72, height: 72)
                        .shadow(color: .black.opacity(0.4), radius: 12, y: 5)
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text("Pult").font(.app(24, weight: .semibold))
                    Text("\(T("about.version")) \(About.version) (\(About.build)) · \(About.author)")
                        .font(.appCallout)
                        .foregroundStyle(.secondary)
                    Text(About.device)
                        .font(.appCaption)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .card()

            ActionCard(T("about.title"), symbol: "info.circle", detail: T("about.summary")) {
                EmptyView()
            }

            ForEach(About.credits, id: \.0) { name, terms in
                ActionCard(name, symbol: "shippingbox", detail: terms) {
                    EmptyView()
                }
            }
        }
    }
}

/// What the configuration adds up to: a reason to open this page and learn
/// something, rather than only to change one switch.
private struct StatsCard: View {
    @EnvironmentObject private var state: AppState

    private var scenes: Int { state.config.scenes.count }
    private var keys: Int {
        state.config.scenes.values.reduce(0) { $0 + $1.keys.filter { !$0.isBlank }.count }
    }
    private var apps: Int {
        Set(state.config.scenes.values.flatMap(\.apps)).count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label {
                Text(T("settings.stats")).font(.appHeadline)
            } icon: {
                Image(systemName: "chart.bar").foregroundStyle(Design.accent)
            }

            Text(T("settings.stats.help"))
                .font(.appCallout)
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                Stat(value: scenes, label: T("stats.scenes"))
                Stat(value: keys, label: T("stats.keys"))
                Stat(value: apps, label: T("stats.apps"))
                Stat(value: state.icons.count, label: T("stats.icons"))
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private struct Stat: View {
        @Environment(\.colorScheme) private var scheme
        let value: Int
        let label: String

        var body: some View {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(value)")
                    .font(.app(22, weight: .semibold).monospacedDigit())
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
