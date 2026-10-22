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
            }
            .padding(24)
            .frame(maxWidth: 680, alignment: .leading)
        }
    }
}
