import SwiftUI
import UniformTypeIdentifiers

/// What can actually be set on the dock itself: brightness, the boot logo it
/// keeps when unplugged, and sleep. There is nothing else — the device stores
/// no profiles of its own, which the page says out loud rather than leaving
/// you to wonder where the rest of the settings are.
struct DeviceView: View {
    @EnvironmentObject private var state: AppState
    @State private var logoMessage: String?
    @State private var brightness: Double = 70

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                PageHeader(T("device.title"), symbol: "dial.medium", intro: T("device.intro"))

                if let device = state.status?.device {
                    SettingsCard(title: T("about.device")) {
                        SettingsRow(T("device.model")) {
                            Text(device.kind).font(.appCallout.monospaced())
                        }
                        SettingsRow(T("device.serial")) {
                            Text(device.serial).font(.appCallout.monospaced())
                        }
                        SettingsRow(T("device.firmware")) {
                            Text(device.firmware).font(.appCallout.monospaced())
                        }
                        SettingsRow(T("device.keys")) {
                            Text("\(device.keys) + \(device.buttons) · \(device.encoders) ⟳")
                                .font(.appCallout.monospaced())
                        }
                    }
                } else {
                    SettingsCard {
                        SettingsRow(T("status.device")) {
                            Label(T("device.disconnected"), systemImage: "exclamationmark.triangle")
                                .font(.appCallout)
                                .foregroundStyle(.orange)
                        }
                    }
                }

                SettingsCard(title: T("device.brightness")) {
                    SettingsRow(T("device.brightness"), help: T("help.brightness")) {
                        HStack(spacing: 12) {
                            Image(systemName: "sun.min").foregroundStyle(.secondary)
                            // Driven by local state: binding a control to a
                            // published value the same view rebuilds from makes
                            // it fight the drag.
                            Slider(value: $brightness, in: 0...100) { editing in
                                if !editing {
                                    state.config.brightness = Int(brightness.rounded())
                                    state.setBrightness(Int(brightness.rounded()), final: true)
                                }
                            }
                            .frame(minWidth: 140, maxWidth: 320)
                            .onChange(of: brightness) { _, value in
                                state.setBrightness(Int(value.rounded()))
                            }
                            Image(systemName: "sun.max").foregroundStyle(.secondary)
                            Text("\(Int(brightness.rounded()))%")
                                .font(.appCallout.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }

                    SettingsDivider()

                    SettingsRow(T("device.sleep")) {
                        HStack(spacing: 8) {
                            Button(T("device.sleep")) { state.sleepDock() }
                                .buttonStyle(.pult)
                                .controlSize(.small)
                                .help(T("help.sleep"))
                            Button(T("device.wake")) { state.wakeDock() }
                                .buttonStyle(.pult)
                                .controlSize(.small)
                        }
                    }
                }

                ActionCard(
                    T("device.bootLogo"),
                    symbol: "photo",
                    detail: T("device.bootLogo.help")
                ) {
                    VStack(alignment: .trailing, spacing: 6) {
                        Button(T("device.bootLogo.choose")) { chooseLogo() }
                            .buttonStyle(.pult)
                        if let size = state.status?.device?.boot_logo, size.count == 2 {
                            Text("\(size[0])×\(size[1])")
                                .font(.appCaption.monospacedDigit())
                                .foregroundStyle(.tertiary)
                        }
                        if let logoMessage {
                            Text(logoMessage)
                                .font(.appCaption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollBounceBehavior(.basedOnSize)
        .task { brightness = Double(state.config.brightness) }
    }

    private func chooseLogo() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        state.writeBootLogo(url) { failure in
            logoMessage = failure ?? T("device.bootLogo.written")
        }
    }
}
