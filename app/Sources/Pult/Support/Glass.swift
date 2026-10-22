import SwiftUI

/// The app's surfaces, in one place.
///
/// Every panel goes through here rather than styling itself, so the whole
/// interface can be retuned by editing this file instead of hunting through
/// views.

extension View {
    /// A floating glass panel, the app's standard surface.
    func glassPanel(cornerRadius: CGFloat = 16, tint: Color? = nil) -> some View {
        let glass = tint.map { Glass.regular.tint($0.opacity(0.5)) } ?? .regular
        return self.glassEffect(glass, in: .rect(cornerRadius: cornerRadius))
    }

    /// A panel that reacts to the pointer, for things you click.
    func glassTile(cornerRadius: CGFloat = 14, tint: Color? = nil) -> some View {
        let base = tint.map { Glass.regular.tint($0.opacity(0.6)) } ?? .regular
        return self.glassEffect(base.interactive(), in: .rect(cornerRadius: cornerRadius))
    }
}

/// A titled block of settings.
struct GlassCard<Content: View>: View {
    var title: String?
    var systemImage: String?
    @ViewBuilder let content: Content

    init(_ title: String? = nil, systemImage: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.systemImage = systemImage
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title {
                Label {
                    Text(title).font(.headline)
                } icon: {
                    if let systemImage {
                        Image(systemName: systemImage).foregroundStyle(.tint)
                    }
                }
            }
            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassPanel(cornerRadius: 18)
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
            Text(value).font(.callout.monospaced())
        }
    }
}

/// Section heading used above the key grid, knobs and buttons.
struct SectionHeading: View {
    let title: String
    var systemImage: String?

    var body: some View {
        Label {
            Text(title).font(.headline)
        } icon: {
            if let systemImage {
                Image(systemName: systemImage).foregroundStyle(.tint)
            }
        }
    }
}
