import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The screensaver: what the dock does once you have stopped using it.
///
/// Its own pane because it is the one part of the configuration that is not
/// about a scene at all. It names scenes, but it belongs to the dock.
///
/// Two things are said here rather than left to be discovered. Nothing in Pult
/// keeps the Mac awake, the dock asks to paint one last frame before sleep
/// and then lets go. And when the Mac does sleep, nothing can animate: the
/// daemon is frozen with everything else, so the still picture below is what
/// stays on the keys until it wakes.
struct ScreensaverView: View {
    @EnvironmentObject private var state: AppState

    private var idle: Idle? { state.config.idle }

    var body: some View {
        GeometryReader { geometry in
            let content = max(260, geometry.size.width - 56)

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Head(width: content)

                    Section2(T("rest.when"), symbol: "clock") {
                        ActionCard(
                            T("rest.on"),
                            symbol: "moon.stars",
                            detail: T("rest.on.says")
                        ) {
                            Toggle("", isOn: Binding(
                                get: { idle != nil },
                                set: { on in
                                    state.config.idle = on
                                        ? Idle(scene: state.config.drawingScenes.first ?? "")
                                        : nil
                                }
                            ))
                            .labelsHidden()
                            .toggleStyle(.switch)
                        }

                        if idle != nil {
                            ActionCard(T("rest.after"), symbol: "timer", detail: T("rest.after.says")) {
                                DurationField(
                                    text: bind(\.after, or: "3m"),
                                    suggestions: ["30s", "1m", "2m", "3m", "5m", "10m", "15m", "30m"]
                                )
                            }

                            ActionCard(T("rest.wake"), symbol: "hand.tap", detail: T("rest.wake.says")) {
                                Picker("", selection: Binding(
                                    get: { idle?.wake_on ?? "any" },
                                    // "any" is the default, so it is written
                                    // as nothing at all: the file should say
                                    // only what was actually chosen.
                                    set: { value in edit { $0.wake_on = value == "any" ? nil : value } }
                                )) {
                                    Text(T("option.any")).tag("any")
                                    Text(T("option.dock")).tag("dock")
                                }
                                .labelsHidden()
                                .frame(width: 180)
                            }

                            ActionCard(T("rest.swallow"), symbol: "hand.raised", detail: T("rest.swallow.says")) {
                                Toggle("", isOn: bind(\.swallow_first_press, or: true))
                                    .labelsHidden()
                                    .toggleStyle(.switch)
                            }
                        }
                    }

                    if idle != nil {
                        Section2(T("rest.what"), symbol: "rectangle.on.rectangle") {
                            Playlist()
                            ActionCard(T("rest.hold"), symbol: "hourglass", detail: T("rest.hold.says")) {
                                DurationField(
                                    text: Binding(
                                        get: { idle?.hold ?? "5m" },
                                        set: { value in edit { $0.hold = value } }
                                    ),
                                    suggestions: ["1m", "2m", "5m", "10m", "30m"]
                                )
                            }
                            NumberCard(
                                title: T("rest.fade"), symbol: "circle.lefthalf.filled",
                                detail: T("rest.fade.says"),
                                value: Binding(
                                    get: { idle?.fade ?? 2.5 },
                                    set: { value in edit { $0.fade = value } }
                                ),
                                range: 0...30, step: 0.5, unit: "s"
                            )
                            NumberCard(
                                title: T("rest.fadein"), symbol: "sun.min",
                                detail: T("rest.fadein.says"),
                                value: Binding(
                                    get: { idle?.fade_in ?? 1.5 },
                                    set: { value in edit { $0.fade_in = value } }
                                ),
                                range: 0...30, step: 0.5, unit: "s"
                            )
                        }

                        Section2(T("rest.light"), symbol: "light.max") {
                            NumberCard(
                                title: T("rest.brightness"), symbol: "sun.max",
                                detail: T("rest.brightness.says"),
                                value: Binding(
                                    get: { Double(idle?.brightness ?? 35) },
                                    set: { value in edit { $0.brightness = Int(value.rounded()) } }
                                ),
                                range: 10...100, step: 5, unit: "%"
                            )

                            ActionCard(T("rest.dark"), symbol: "display", detail: T("rest.dark.says")) {
                                Toggle("", isOn: bind(\.dark_when_display_sleeps, or: false))
                                    .labelsHidden()
                                    .toggleStyle(.switch)
                            }

                            SleepImage()
                        }
                    }
                }
                .padding(28)
                .frame(width: geometry.size.width, alignment: .leading)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    private func edit(_ change: (inout Idle) -> Void) {
        guard var next = state.config.idle else { return }
        change(&next)
        state.config.idle = next
    }

    private func bind<Value>(
        _ path: WritableKeyPath<Idle, Value>,
        or fallback: Value
    ) -> Binding<Value> {
        Binding(
            get: { state.config.idle?[keyPath: path] ?? fallback },
            set: { value in edit { $0[keyPath: path] = value } }
        )
    }
}

private struct Head: View {
    let width: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "moon.stars")
                    .font(.app(18, weight: .semibold))
                    .foregroundStyle(Design.accent)
                Text(T("nav.screensaver")).font(.app(24, weight: .semibold))
            }
            Text(T("rest.says"))
                .font(.appCallout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: width, alignment: .leading)
    }
}

// MARK: - The playlist

/// Which scenes it cycles through.
///
/// A list rather than one scene, because each member is a whole scene and
/// keeps its own motion, colours, geometry and frame rate, so a playlist is
/// not a slideshow of pictures but a rotation of entirely different things.
private struct Playlist: View {
    @EnvironmentObject private var state: AppState

    private var chosen: [String] { state.config.idle?.playlist ?? [] }

    var body: some View {
        VStack(spacing: 10) {
        ActionCard(T("rest.playlist"), symbol: "list.bullet", detail: T("rest.playlist.says")) {
            Menu {
                // Drawings only. A scene of six labelled keys is a controller,
                // and a controller is not what you want to be looking at from
                // across the room, nor does it stop the dock burning the same
                // six pictures into the same six screens, which is half of why
                // this exists. A hand-written config naming one still works;
                // the editor simply will not suggest it.
                if state.config.drawingScenes.isEmpty {
                    Text(T("rest.playlist.none"))
                } else {
                    ForEach(state.config.drawingScenes, id: \.self) { name in
                        Button(name) { add(name) }
                    }
                }
            } label: {
                Label(T("rest.playlist.add"), systemImage: "plus")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }

        if !chosen.isEmpty {
            VStack(spacing: 6) {
                ForEach(Array(chosen.enumerated()), id: \.offset) { index, name in
                    HStack(spacing: 10) {
                        Text("\(index + 1)")
                            .font(.appCaption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 18, alignment: .trailing)

                        Text(name).font(.appBody)

                        if state.config.scenes[name] == nil {
                            // Named but not defined: the daemon refuses the
                            // whole file for this, so it is worth saying here
                            // rather than at save.
                            Label(T("rest.playlist.missing"), systemImage: "exclamationmark.triangle")
                                .font(.appCaption)
                                .foregroundStyle(.orange)
                        }

                        Spacer(minLength: 12)

                        Button { move(index, by: -1) } label: {
                            Image(systemName: "chevron.up").font(.appCaption)
                        }
                        .buttonStyle(.borderless)
                        .disabled(index == 0)

                        Button { move(index, by: 1) } label: {
                            Image(systemName: "chevron.down").font(.appCaption)
                        }
                        .buttonStyle(.borderless)
                        .disabled(index == chosen.count - 1)

                        Button { remove(index) } label: {
                            Image(systemName: "minus.circle").font(.appCaption)
                        }
                        .buttonStyle(.borderless)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .card(radius: 12)
                }
            }
        }
        }
    }

    private func write(_ list: [String]) {
        guard var idle = state.config.idle else { return }
        // One member is written as `scene`, not as a playlist of one: the file
        // should read the way a person would have written it by hand.
        if list.count <= 1 {
            idle.scenes = []
            idle.scene = list.first ?? ""
        } else {
            idle.scenes = list
            idle.scene = list[0]
        }
        state.config.idle = idle
    }

    private func add(_ name: String) {
        var list = chosen
        guard !list.contains(name) else { return }
        list.append(name)
        write(list)
    }

    private func remove(_ index: Int) {
        var list = chosen
        guard list.indices.contains(index) else { return }
        list.remove(at: index)
        write(list)
    }

    private func move(_ index: Int, by step: Int) {
        var list = chosen
        let target = index + step
        guard list.indices.contains(index), list.indices.contains(target) else { return }
        list.swapAt(index, target)
        write(list)
    }
}

// MARK: - The picture the Mac sleeps under

private struct SleepImage: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        ActionCard(
            T("rest.sleepimage"),
            symbol: "powersleep",
            detail: state.config.idle?.sleep_image ?? T("rest.sleepimage.says")
        ) {
            HStack(spacing: 8) {
                Button(T("surface.file.choose")) { pick() }
                    .buttonStyle(.pult)
                if state.config.idle?.sleep_image != nil {
                    Button(T("surface.file.drop")) {
                        state.config.idle?.sleep_image = nil
                    }
                    .buttonStyle(.pult)
                }
            }
        }
    }

    private func pick() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.png, .jpeg]
        panel.message = T("rest.sleepimage.says")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        state.config.idle?.sleep_image = url.path
    }
}

// MARK: - Shared rows

/// A length of time, typed the way a person says it, with the usual answers
/// one click away.
private struct DurationField: View {
    @Binding var text: String
    let suggestions: [String]

    var body: some View {
        HStack(spacing: 6) {
            TextField("", text: $text)
                .textFieldStyle(.roundedBorder)
                .font(.appCallout.monospaced())
                .frame(width: 70)

            Menu {
                ForEach(suggestions, id: \.self) { value in
                    Button(value) { text = value }
                }
            } label: {
                Image(systemName: "chevron.down").font(.appCaption)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }
}

private struct NumberCard: View {
    let title: String
    let symbol: String
    let detail: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let unit: String

    var body: some View {
        ActionCard(title, symbol: symbol, detail: detail) {
            HStack(spacing: 10) {
                Slider(value: $value, in: range, step: step)
                    .frame(width: 150)
                Text(reading)
                    .font(.appCallout.monospacedDigit())
                    .frame(minWidth: 48, alignment: .trailing)
            }
        }
    }

    private var reading: String {
        let number = step >= 1
            ? String(Int(value.rounded()))
            : String(format: "%.1f", value)
        return number + unit
    }
}
