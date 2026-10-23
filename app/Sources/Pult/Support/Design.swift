import SwiftUI

/// The app's surfaces, colours and shapes, in one place.
///
/// The values follow the calm macOS 27 shape: a flat neutral window, a
/// translucent sidebar that runs to the edge, cards a step lighter than the
/// window, one blue accent, and concentric, modest corners — capsules only on
/// buttons.
enum Design {
    // Surfaces, from the deepest well to the most raised.
    static func surface(_ scheme: ColorScheme) -> Color { white(scheme, 0.04, 0.03) }
    static func surface2(_ scheme: ColorScheme) -> Color { white(scheme, 0.06, 0.05) }
    static func surface3(_ scheme: ColorScheme) -> Color { white(scheme, 0.10, 0.08) }
    /// The selected sidebar row.
    static func pill(_ scheme: ColorScheme) -> Color { white(scheme, 0.12, 0.10) }

    static func border(_ scheme: ColorScheme) -> Color { white(scheme, 0.10, 0.10) }
    static func borderStrong(_ scheme: ColorScheme) -> Color { white(scheme, 0.20, 0.18) }

    /// The window itself: flat and neutral, not a gradient. A busy backdrop is
    /// what made the first version look like a poster rather than an app.
    static func window(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.118, green: 0.118, blue: 0.125) : Color(white: 0.96)
    }

    static let accent = Color(red: 0.302, green: 0.639, blue: 1.0)
    static let accentFill = Color(red: 0.039, green: 0.447, blue: 0.910)
    static let accentSoft = Color(red: 0.039, green: 0.518, blue: 1.0).opacity(0.18)

    static let good = Color(red: 0.196, green: 0.816, blue: 0.455)
    static let warn = Color(red: 1.0, green: 0.702, blue: 0.251)
    static let bad = Color(red: 1.0, green: 0.412, blue: 0.380)

    static let muted = Color(red: 0.631, green: 0.631, blue: 0.659)

    /// The gutter between the pane's edge and the content.
    static let pagePadding: CGFloat = 28

    // Concentric and modest: each radius is the one outside it, less the
    // padding between them.
    static let radiusField: CGFloat = 8
    static let radiusCard: CGFloat = 14
    static let radiusPanel: CGFloat = 16

    private static func white(_ scheme: ColorScheme, _ dark: Double, _ light: Double) -> Color {
        scheme == .dark ? Color.white.opacity(dark) : Color.black.opacity(light)
    }
}

extension View {
    /// A content card: a step lighter than the window, a hairline border, and
    /// the bright top edge that keeps it from looking printed on.
    func card(radius: CGFloat = Design.radiusCard, tinted: Bool = false) -> some View {
        modifier(CardSurface(radius: radius, tinted: tinted))
    }

    /// A raised, floating surface — the dock panel, a preview.
    func panel(radius: CGFloat = Design.radiusPanel) -> some View {
        modifier(CardSurface(radius: radius, tinted: false, raised: true))
    }
}

private struct CardSurface: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    let radius: CGFloat
    var tinted: Bool
    var raised = false

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: radius)
                    .fill(tinted ? Design.accentSoft : Design.surface2(scheme))
            }
            .overlay {
                RoundedRectangle(cornerRadius: radius)
                    .strokeBorder(
                        tinted ? Design.accent.opacity(0.35) : Design.border(scheme),
                        lineWidth: 1
                    )
            }
            .overlay(alignment: .top) {
                // The one bright line along the top edge.
                RoundedRectangle(cornerRadius: radius)
                    .trim(from: 0.06, to: 0.44)
                    .stroke(Color.white.opacity(scheme == .dark ? 0.06 : 0.5), lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .shadow(color: .black.opacity(raised ? 0.30 : 0.18), radius: raised ? 14 : 2, y: raised ? 6 : 1)
    }
}

/// A quiet button: a capsule of the raised surface.
struct PultButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var scheme
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.appCallout)
            .foregroundStyle(prominent ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background {
                Capsule().fill(prominent ? Design.accentFill : Design.surface3(scheme))
            }
            .overlay {
                if !prominent {
                    Capsule().strokeBorder(Design.border(scheme), lineWidth: 1)
                }
            }
            .opacity(configuration.isPressed ? 0.75 : 1)
            .contentShape(.capsule)
    }
}

extension ButtonStyle where Self == PultButtonStyle {
    static var pult: PultButtonStyle { PultButtonStyle() }
    static var pultProminent: PultButtonStyle { PultButtonStyle(prominent: true) }
}
