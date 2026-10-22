import SwiftUI
import UniformTypeIdentifiers

/// What can actually be set on the dock itself: brightness, the boot logo it
/// keeps when unplugged, and sleep. There is nothing else; the device stores
/// no profiles of its own.
struct DeviceView: View {
    @EnvironmentObject private var state: AppState
    @State private var logoMessage: String?
    @State private var brightness: Double = 70

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text(T("device.title")).font(.largeTitle.weight(.semibold))

                if let device = state.status?.device {
                    GlassCard(T("device.title"), systemImage: "dial.medium") {
                        InfoRow(T("device.model"), device.kind)
                        InfoRow(T("device.serial"), device.serial)
                        InfoRow(T("device.firmware"), device.firmware)
                        InfoRow(T("device.keys"), "\(device.keys) + \(device.buttons) · \(device.encoders) ⟳")
                    }
                } else {
                    Label(T("device.disconnected"), systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }

                GlassCard(T("device.brightness"), systemImage: "sun.max") {
                    HStack {
                        Image(systemName: "sun.min")
                        // The slider is driven by local state, not by the
                        // configuration: binding a control to a published value
                        // that the same view rebuilds from makes it fight the
                        // drag.
                        Slider(value: $brightness, in: 0...100) { editing in
                            if !editing {
                                state.config.brightness = Int(brightness.rounded())
                                state.setBrightness(Int(brightness.rounded()), final: true)
                            }
                        }
                        .onChange(of: brightness) { _, value in
                            state.setBrightness(Int(value.rounded()))
                        }
                        Image(systemName: "sun.max")
                        Text("\(Int(brightness.rounded()))%")
                            .monospacedDigit()
                            .frame(width: 46, alignment: .trailing)
                    }

                    HStack {
                        Button(T("device.sleep")) { state.sleepDock() }.buttonStyle(.glass)
                        Button(T("device.wake")) { state.wakeDock() }.buttonStyle(.glass)
                    }
                }

                GlassCard(T("device.bootLogo"), systemImage: "photo") {
                    Text(T("device.bootLogo.help"))
                        .font(.caption).foregroundStyle(.secondary)

                    HStack {
                        Button(T("device.bootLogo.choose")) { chooseLogo() }.buttonStyle(.glass)
                        if let logoMessage {
                            Text(logoMessage).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let size = state.status?.device?.boot_logo, size.count == 2 {
                            Text("\(size[0])×\(size[1])")
                                .font(.callout.monospacedDigit())
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 680, alignment: .leading)
        }
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

