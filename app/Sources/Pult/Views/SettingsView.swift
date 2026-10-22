import SwiftUI

/// Settings in four short pages.
///
/// The rows are a `Grid`, not stacked frames: a column that is told its width
/// can be overrun by a control that needs more, which is how the label ended up
/// printed over the picker. A grid negotiates the columns instead.
struct SettingsView: View {
    enum Page: String, CaseIterable, Identifiable {
        case look, behaviour, service, about

        var id: String { rawValue }
        var label: String { T("settings.tab.\(rawValue)") }
        var symbol: String {
            switch self {
            case .look: return "paintbrush"
            case .behaviour: return "slider.horizontal.3"
            case .service: return "bolt.horizontal"
            case .about: return "info.circle"
            }
        }
    }

    @State private var page: Page = .look

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PageHeader(T("nav.settings"), symbol: "gearshape", intro: T("settings.intro"))

                Picker("", selection: $page) {
                    ForEach(Page.allCases) { page in
                        Text(page.label).tag(page)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(maxWidth: 440)

                switch page {
                case .look: LookPage()
                case .behaviour: BehaviourPage()
                case .service: ServicePage()
                case .about: AboutPage()
                }
            }
            .padding(28)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollBounceBehavior(.basedOnSize)
    }
}

// MARK: - Pages

private struct LookPage: View {
    @EnvironmentObject private var l10n: L10n
    @EnvironmentObject private var theme: Theme

    var body: some View {
        SettingsCard {
            SettingsRow(T("settings.theme")) {
                Picker("", selection: $theme.appearance) {
                    ForEach(Appearance.allCases) { appearance in
                        Text(appearance.label).tag(appearance)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(maxWidth: 300)
            }

            SettingsDivider()

            SettingsRow(T("settings.textSize"), help: T("settings.textSize.help")) {
                Picker("", selection: $theme.textSize) {
                    ForEach(TextSize.allCases) { size in
                        Text(size.label).tag(size)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(maxWidth: 360)
            }

            SettingsDivider()

            SettingsRow(T("settings.language")) {
                Picker("", selection: l10n.languageBinding) {
                    ForEach(Language.allCases) { language in
                        Text(language.label).tag(language)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(maxWidth: 300)
            }
        }
    }
}

private struct BehaviourPage: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        SettingsCard {
            SettingsRow(T("settings.pressFeedback.short")) {
                Toggle("", isOn: $state.config.press_feedback)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }

            SettingsDivider()

            SettingsRow(T("settings.poll.short"), help: T("settings.poll.help")) {
                HStack(spacing: 12) {
                    Slider(
                        value: Binding(
                            get: { Double(state.config.poll_ms) },
                            set: { state.config.poll_ms = Int($0) }
                        ),
                        in: 100...1000,
                        step: 50
                    )
                    .frame(minWidth: 120, maxWidth: 260)

                    Text("\(state.config.poll_ms) ms")
                        .font(.appCallout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct ServicePage: View {
    @EnvironmentObject private var state: AppState
    @State private var loaded = true

    private var allowed: Bool { state.status?.keystrokes_allowed ?? false }

    var body: some View {
        SettingsCard {
            SettingsRow(T("status.daemon")) {
                HStack(spacing: 10) {
                    Circle()
                        .fill(state.connected ? Color.green : Color.orange)
                        .frame(width: 8, height: 8)
                    Text(state.connected ? T("service.running") : T("service.stopped"))
                        .font(.appCallout)
                        .foregroundStyle(.secondary)
                    Button(T("service.restart")) { Service.restart() }
                        .buttonStyle(.pult)
                        .controlSize(.small)
                        .help(T("service.restart.help"))
                }
            }

            SettingsDivider()

            SettingsRow(T("service.login"), help: T("service.login.help")) {
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

            SettingsDivider()

            SettingsRow(T("settings.permission")) {
                HStack(spacing: 8) {
                    Image(systemName: allowed ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(allowed ? .green : .orange)
                    Text(allowed ? T("settings.permission.ok") : T("settings.permission.missing"))
                        .font(.appCallout)
                        .foregroundStyle(allowed ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
                        .fixedSize(horizontal: false, vertical: true)
                    if !allowed {
                        Button(T("settings.permission.open")) {
                            NSWorkspace.shared.open(URL(
                                string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
                            )!)
                        }
                        .buttonStyle(.pult)
                        .controlSize(.small)
                    }
                }
            }

            SettingsDivider()

            SettingsRow(T("settings.config.short")) {
                PathValue(path: state.status?.config_path, action: T("settings.config.reveal")) {
                    if let path = state.status?.config_path {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                    }
                }
            }

            SettingsDivider()

            SettingsRow(T("settings.log.short")) {
                PathValue(path: Service.logPath.path, action: T("service.log.open")) {
                    NSWorkspace.shared.open(Service.logPath)
                }
            }
        }
        .task { loaded = Service.isLoaded() }
    }
}

private struct AboutPage: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsCard {
                HStack(alignment: .center, spacing: 16) {
                    if let icon = NSApp.applicationIconImage {
                        Image(nsImage: icon).resizable().frame(width: 64, height: 64)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Pult").font(.appTitle2)
                        Text("\(About.version) · \(About.author)")
                            .font(.appCallout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }

                Text(T("about.summary"))
                    .font(.appCallout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                SettingsDivider()

                SettingsRow(T("about.version")) {
                    Text("\(About.version) (\(About.build))").font(.appCallout.monospacedDigit())
                }
                SettingsRow(T("about.author")) {
                    Text(About.author).font(.appCallout)
                }
                SettingsRow(T("about.device")) {
                    Text(About.device).font(.appCallout)
                }
            }

            SettingsCard(title: T("about.credits")) {
                ForEach(About.credits, id: \.0) { name, terms in
                    SettingsRow(name) {
                        Text(terms).font(.appCallout).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

// MARK: - Form pieces

/// A card whose rows line up, because they are one grid rather than many
/// stacks. Everything inside is laid out by `SettingsRow`.
struct SettingsCard<Content: View>: View {
    var title: String?
    @ViewBuilder let content: Content

    init(title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                Text(title)
                    .font(.appCaption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .textCase(.uppercase)
            }

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 20, verticalSpacing: 14) {
                content
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(radius: 18)
    }
}

/// One row of a settings grid: label, then control, with any explanation
/// under the control.
struct SettingsRow<Control: View>: View {
    let title: String
    var help: String?
    @ViewBuilder let control: Control

    init(_ title: String, help: String? = nil, @ViewBuilder control: () -> Control) {
        self.title = title
        self.help = help
        self.control = control()
    }

    var body: some View {
        GridRow {
            Text(title)
                .font(.appBody)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
                .gridColumnAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 5) {
                control
                if let help {
                    Text(help)
                        .font(.appCaption)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .gridColumnAlignment(.leading)
        }
    }
}

/// A line across the whole grid.
struct SettingsDivider: View {
    var body: some View {
        GridRow {
            Divider().gridCellColumns(2)
        }
    }
}

struct PathValue: View {
    let path: String?
    let action: String
    let reveal: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text(path ?? "—")
                .font(.appCaption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.head)
            Button(action, action: reveal)
                .buttonStyle(.pult)
                .controlSize(.small)
        }
    }
}
