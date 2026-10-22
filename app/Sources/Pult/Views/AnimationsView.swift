import SwiftUI

/// Animations: what a scene paints across the whole dock, and every setting
/// the motion honours.
///
/// Its own pane rather than a section inside the scene editor. A scene editor
/// is about what the six keys *do*; this is about what the dock *looks like*,
/// and the two are rarely changed in the same sitting — a canvas is chosen
/// once and then tuned, while bindings are edited constantly.
struct AnimationsView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        GeometryReader { geometry in
            let content = max(260, geometry.size.width - 56)

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Header(width: content)

                    if let name = state.selectedScene, state.config.scenes[name] != nil {
                        SurfaceSection(name: name, width: content)
                    } else {
                        Empty()
                    }
                }
                .padding(28)
                .frame(width: geometry.size.width, alignment: .leading)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }
}

/// Which scene is being painted, and a way to change it without going back.
private struct Header: View {
    let width: CGFloat
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "waveform")
                    .font(.app(18, weight: .semibold))
                    .foregroundStyle(Design.accent)

                Text(T("nav.animations"))
                    .font(.app(24, weight: .semibold))

                Spacer(minLength: 16)

                Picker("", selection: Binding(
                    get: { state.selectedScene ?? "" },
                    set: { state.selectedScene = $0.isEmpty ? nil : $0 }
                )) {
                    ForEach(state.config.sceneNames, id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 220)
            }

            Text(T("animations.says"))
                .font(.appCallout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: width, alignment: .leading)
    }
}

private struct Empty: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "rectangle.on.rectangle")
                .font(.app(30, weight: .light))
                .foregroundStyle(.tertiary)
            Text(T("animations.none"))
                .font(.appCallout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }
}
