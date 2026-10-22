import SwiftUI

/// The first screen, when nothing has ever answered.
///
/// A copy dragged out of a disk image has an application and a daemon but no
/// login agent, so nothing is driving the dock and no configuration has ever
/// arrived. Left to render the ordinary window with nothing in it, the app
/// came up as an empty frame — no sidebar, no status line, nothing to press —
/// which is the worst possible first impression and gives no clue what is
/// wrong.
///
/// So that state gets a screen of its own rather than being an accident of
/// what SwiftUI does with empty data. It says what is missing, fixes it in one
/// press, and names the permission that has to be granted by hand afterwards,
/// because that one genuinely cannot be automated.
struct Welcome: View {
    @EnvironmentObject private var state: AppState
    @State private var working = false
    @State private var tried = false

    private var repairing: Bool { Service.isInstalled && !Service.isCurrent }

    var body: some View {
        ZStack {
            Backdrop()

            VStack(spacing: 0) {
                Spacer(minLength: 20)

                VStack(spacing: 18) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 92, height: 92)

                    VStack(spacing: 6) {
                        Text(T("app.name")).font(.app(30, weight: .semibold))
                        Text(T("welcome.says"))
                            .font(.appBody)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: 440)
                    }

                    VStack(spacing: 10) {
                        Step(
                            number: 1,
                            title: repairing ? T("service.repair") : T("service.install"),
                            detail: repairing ? T("service.repair.help") : T("service.install.help"),
                            done: false
                        ) {
                            Button(repairing ? T("service.repair.go") : T("service.install.go")) {
                                start()
                            }
                            .buttonStyle(.pultProminent)
                            .disabled(working)
                        }

                        Step(
                            number: 2,
                            title: T("welcome.permission"),
                            detail: T("welcome.permission.says"),
                            done: false
                        ) {
                            Button(T("settings.permission.open")) {
                                NSWorkspace.shared.open(URL(
                                    string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
                                )!)
                            }
                            .buttonStyle(.pult)
                        }
                    }
                    .frame(maxWidth: 560)

                    if tried, !state.connected {
                        // Said only after a press that did not work: before
                        // that it would be a warning about nothing.
                        Label(T("welcome.still"), systemImage: "exclamationmark.triangle")
                            .font(.appCallout)
                            .foregroundStyle(Design.warn)
                    }
                }

                Spacer(minLength: 20)
            }
            .padding(40)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func start() {
        working = true
        _ = Service.install()
        // launchd has the job the moment it returns, but the daemon still has
        // to open the device and put its socket down.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            state.refresh()
            working = false
            tried = true
        }
    }
}

/// One numbered thing to do.
private struct Step<Control: View>: View {
    let number: Int
    let title: String
    let detail: String
    let done: Bool
    @ViewBuilder let control: Control

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                Circle()
                    .fill(done ? Design.good.opacity(0.2) : Design.accentSoft)
                    .frame(width: 26, height: 26)
                if done {
                    Image(systemName: "checkmark")
                        .font(.appCaption.weight(.bold))
                        .foregroundStyle(Design.good)
                } else {
                    Text("\(number)")
                        .font(.appCallout.weight(.semibold))
                        .foregroundStyle(Design.accent)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.appHeadline)
                Text(detail)
                    .font(.appCallout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Spacer(minLength: 12)
            control
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(radius: 16)
    }
}
