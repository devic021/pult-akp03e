import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var l10n: L10n
    @EnvironmentObject private var theme: Theme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text(T("nav.settings")).font(.largeTitle.weight(.semibold))

                GlassCard(T("settings.theme"), systemImage: "paintbrush") {
                    Picker("", selection: $theme.appearance) {
                        ForEach(Appearance.allCases) { appearance in
                            Label(appearance.label, systemImage: appearance.symbol)
                                .tag(appearance)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 320)
                }

                GlassCard(T("settings.textSize"), systemImage: "textformat.size") {
                    Picker("", selection: $theme.textSize) {
                        ForEach(TextSize.allCases) { size in
                            Text(size.label).tag(size)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 380)
                    Text(T("settings.textSize.help"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                GlassCard(T("settings.language"), systemImage: "globe") {
                    Picker("", selection: l10n.languageBinding) {
                        ForEach(Language.allCases) { language in
                            Text(language.label).tag(language)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 320)
                }

                GlassCard(T("nav.settings"), systemImage: "slider.horizontal.3") {
                    Toggle(T("settings.pressFeedback"), isOn: $state.config.press_feedback)

                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(T("settings.poll"))
                            Spacer()
                            Text("\(state.config.poll_ms) ms").monospacedDigit()
                        }
                        Slider(
                            value: Binding(
                                get: { Double(state.config.poll_ms) },
                                set: { state.config.poll_ms = Int($0) }
                            ),
                            in: 100...1000,
                            step: 50
                        )
                        Text(T("settings.poll.help")).font(.caption).foregroundStyle(.secondary)
                    }
                }

                GlassCard(T("settings.permission"), systemImage: "lock.shield") {
                    let allowed = state.status?.keystrokes_allowed ?? false
                    HStack {
                        Image(systemName: allowed ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(allowed ? .green : .orange)
                        Text(allowed ? T("settings.permission.ok") : T("settings.permission.missing"))
                        Spacer()
                        if !allowed {
                            Button(T("settings.permission.open")) {
                                NSWorkspace.shared.open(URL(
                                    string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
                                )!)
                            }
                            .buttonStyle(.glass)
                        }
                    }
                }

                ServiceCard()

                GlassCard(T("settings.config"), systemImage: "doc.text") {
                    HStack {
                        Text(state.status?.config_path ?? "–")
                            .font(.callout.monospaced())
                            .lineLimit(1)
                            .truncationMode(.head)
                        Spacer()
                        Button(T("settings.config.reveal")) {
                            if let path = state.status?.config_path {
                                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                            }
                        }
                    }
                }

                AboutCard()
            }
            .padding(24)
            .frame(maxWidth: 680, alignment: .leading)
        }
    }
}

/// Starting, stopping and watching the daemon.
private struct ServiceCard: View {
    @EnvironmentObject private var state: AppState
    @State private var loaded = true

    var body: some View {
        GlassCard(T("service.title"), systemImage: "gearshape.arrow.trianglehead.2.clockwise.rotate.90") {
            HStack(spacing: 8) {
                Circle()
                    .fill(state.connected ? Color.green : Color.orange)
                    .frame(width: 8, height: 8)
                Text(state.connected ? T("service.running") : T("service.stopped"))
                    .foregroundStyle(.secondary)
                Spacer()
                Button(T("service.restart")) {
                    Service.restart()
                }
                .buttonStyle(.glass)
                .help(T("service.restart.help"))
            }

            Toggle(T("service.login"), isOn: Binding(
                get: { loaded },
                set: { value in
                    loaded = value
                    Service.setLoaded(value)
                }
            ))
            .help(T("service.login.help"))

            HStack {
                Text(Service.logPath.path)
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                Spacer()
                Button(T("service.log.open")) {
                    NSWorkspace.shared.open(Service.logPath)
                }
                .buttonStyle(.glass)
            }
        }
        .task {
            // Asking launchd runs a process, so it is done once on appearing.
            loaded = Service.isLoaded()
        }
    }
}

/// What this is, who made it, and what it is built out of.
private struct AboutCard: View {
    var body: some View {
        GlassCard(T("about.title"), systemImage: "info.circle") {
            HStack(alignment: .top, spacing: 14) {
                if let icon = NSApp.applicationIconImage {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 56, height: 56)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text("Pult").font(.title2.weight(.semibold))
                    Text(T("about.summary"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.bottom, 4)

            InfoRow(T("about.version"), "\(About.version) (\(About.build))")
            InfoRow(T("about.author"), About.author)
            InfoRow(T("about.device"), About.device)

            Divider().padding(.vertical, 2)

            Text(T("about.credits"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
                .textCase(.uppercase)

            ForEach(About.credits, id: \.0) { name, terms in
                InfoRow(name, terms)
            }
        }
    }
}
