import SwiftUI

/// Small shared pieces built on the design tokens.

extension View {
    /// A chip or a segmented container: the quiet raised surface, capsule cut.
    func chip() -> some View {
        modifier(Chip())
    }
}

private struct Chip: ViewModifier {
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        content
            .background(Capsule().fill(Design.surface2(scheme)))
            .overlay(Capsule().strokeBorder(Design.border(scheme), lineWidth: 1))
    }
}

/// A titled block of settings or information.
struct GlassCard<Content: View>: View {
    var title: String?
    var systemImage: String?
    @ViewBuilder let content: Content

    init(
        _ title: String? = nil,
        systemImage: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.systemImage = systemImage
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title {
                Label {
                    Text(title).font(.appHeadline)
                } icon: {
                    if let systemImage {
                        Image(systemName: systemImage).foregroundStyle(Design.accent)
                    }
                }
            }
            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}

/// Key/value line used in the device panel.
struct InfoRow: View {
    let title: String
    let value: String

    init(_ title: String, _ value: String) {
        self.title = title
        self.value = value
    }

    var body: some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.appCallout.monospaced())
        }
    }
}

/// Section heading used above the key grid, knobs and buttons.
struct SectionHeading: View {
    let title: String
    var systemImage: String?

    var body: some View {
        Label {
            Text(title).font(.appHeadline)
        } icon: {
            if let systemImage {
                Image(systemName: systemImage).foregroundStyle(Design.accent)
            }
        }
    }
}
