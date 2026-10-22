import SwiftUI
import UniformTypeIdentifiers

/// What can actually be set on the dock itself: brightness, the boot logo it
/// keeps when unplugged, and sleep. There is nothing else — the device stores
/// no profiles of its own, which the page says rather than leaving you to
/// wonder where the rest of the settings went.
struct DeviceView: View {
    @EnvironmentObject private var state: AppState
    @State private var logoMessage: String?
    @State private var brightness: Double = 70

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                PageHeader(T("device.title"), symbol: "dial.medium", intro: T("device.intro"))

                if let device = state.status?.device {
                    HStack(alignment: .center, spacing: 16) {
                        ZStack {
                            Circle().fill(Design.accentSoft)
                            Image(systemName: "dial.medium")
                                .font(.app(24, weight: .medium))
                                .foregroundStyle(Design.accent)
                        }
                        .frame(width: 60, height: 60)

                        VStack(alignment: .leading, spacing: 4) {
                            Text(About.device).font(.app(20, weight: .semibold))
                            Text("\(device.serial) · \(device.firmware)")
                                .font(.appCallout.monospaced())
                                .foregroundStyle(.secondary)
                            Text("\(device.keys) + \(device.buttons) \(T("count.keys")) · \(device.encoders) \(T("count.knobs"))")
                                .font(.appCaption)
                                .foregroundStyle(.tertiary)
                        }

                        Spacer()

                        HStack(spacing: 7) {
                            Circle()
                                .fill(state.connected ? Design.good : Design.warn)
                                .frame(width: 8, height: 8)
                            Text(state.connected ? T("status.connected") : T("status.disconnected"))
                                .font(.appCallout)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .card()
                } else {
                    ActionCard(
                        T("device.disconnected"),
                        symbol: "exclamationmark.triangle",
                        detail: T("help.disconnected"),
                        tinted: true
                    ) {
                        EmptyView()
                    }
                }

                ActionCard(T("device.brightness"), symbol: "sun.max", detail: T("help.brightness")) {
                    HStack(spacing: 10) {
                        Image(systemName: "sun.min").foregroundStyle(.tertiary)
                        // Driven by local state: binding a control to a
                        // published value the same view rebuilds from makes it
                        // fight the drag.
                        Slider(value: $brightness, in: 0...100) { editing in
                            if !editing {
                                state.config.brightness = Int(brightness.rounded())
                                state.setBrightness(Int(brightness.rounded()), final: true)
                            }
                        }
                        .frame(width: 170)
                        .onChange(of: brightness) { _, value in
                            state.setBrightness(Int(value.rounded()))
                        }
                        Text("\(Int(brightness.rounded()))%")
                            .font(.appCallout.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 42, alignment: .trailing)
                    }
                }

                ActionCard(T("device.sleep"), symbol: "moon", detail: T("help.sleep")) {
                    HStack(spacing: 8) {
                        Button(T("device.sleep")) { state.sleepDock() }
                            .buttonStyle(.pult)
                        Button(T("device.wake")) { state.wakeDock() }
                            .buttonStyle(.pult)
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
                            Text(logoMessage).font(.appCaption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(Design.pagePadding)
            // No content cap: the boxes run the full width of the pane, which
            // is what was asked for on a wide display.
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
