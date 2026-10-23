import SwiftUI

/// The dock's parts, drawn to match the hardware.
///
/// Each part is one `Canvas` rather than a stack of shapes: a knurled knob is
/// fifty-odd marks, and fifty views per knob is both slower to lay out and
/// harder to read than the drawing code.

/// Proportions taken off the device.
///
/// Everything derives from one scale, so the parts cannot drift out of
/// proportion with each other when any of it is adjusted. The base numbers are
/// the device's own, measured off it with a body 640 wide.
enum Dock {
    /// Drawn larger than life: the window has the room, and a key at 80 points
    /// makes its label too small to read.
    static let scale: CGFloat = 1.14

    private static func u(_ value: CGFloat) -> CGFloat { value * scale }
    private static func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(x: x * scale, y: y * scale)
    }

    static var body: CGSize { CGSize(width: u(640), height: u(376)) }
    static var corner: CGFloat { u(26) }

    static var key: CGFloat { u(80) }
    static var keyGap: CGFloat { u(10) }
    static var keyCorner: CGFloat { u(10) }
    /// The display is inset in the cap; thin, like the moulding on the device.
    static var keyBezel: CGFloat { u(4) }
    static var keysOrigin: CGPoint { p(74, 52) }

    static var bigKnob: CGFloat { u(146) }
    static var bigKnobCenter: CGPoint { p(476, 124) }

    static var button: CGFloat { u(58) }
    static var buttonCenters: [CGPoint] { [p(113, 300), p(206, 300), p(299, 300)] }

    static var smallKnob: CGFloat { u(70) }
    static var smallKnobCenters: [CGPoint] { [p(420, 300), p(532, 300)] }

    /// Where a key sits, by slot.
    static func keyFrame(_ slot: Int) -> CGRect {
        let row = CGFloat(slot / 3)
        let column = CGFloat(slot % 3)
        return CGRect(
            x: keysOrigin.x + column * (key + keyGap),
            y: keysOrigin.y + row * (key + keyGap),
            width: key,
            height: key
        )
    }
}

/// A knurled aluminium knob.
struct KnobFace: View {
    var diameter: CGFloat
    var selected: Bool

    var body: some View {
        Canvas { context, size in
            let radius = min(size.width, size.height) / 2
            let centre = CGPoint(x: size.width / 2, y: size.height / 2)

            // The rim, lit from the upper left like the rest of the window.
            let rim = Path(ellipseIn: CGRect(origin: .zero, size: size))
            context.fill(
                rim,
                with: .linearGradient(
                    Gradient(colors: [
                        Color(white: 0.34),
                        Color(white: 0.17),
                        Color(white: 0.09),
                    ]),
                    startPoint: CGPoint(x: size.width * 0.2, y: 0),
                    endPoint: CGPoint(x: size.width * 0.8, y: size.height)
                )
            )

            // Knurling: fine marks around the rim, fading towards the sides so
            // the knob reads as round rather than as a striped disc.
            let marks = 56
            let outer = radius * 0.995
            let inner = radius * 0.80
            for index in 0..<marks {
                let angle = Double(index) / Double(marks) * 2 * .pi
                let fade = 0.18 + 0.22 * abs(cos(angle))
                var mark = Path()
                mark.move(to: CGPoint(
                    x: centre.x + cos(angle) * inner,
                    y: centre.y + sin(angle) * inner
                ))
                mark.addLine(to: CGPoint(
                    x: centre.x + cos(angle) * outer,
                    y: centre.y + sin(angle) * outer
                ))
                context.stroke(
                    mark,
                    with: .color(.white.opacity(fade * 0.5)),
                    lineWidth: max(0.7, diameter / 90)
                )
            }

            // The flat top, inset, with concentric turning marks.
            let capRadius = radius * 0.735
            let cap = Path(ellipseIn: CGRect(
                x: centre.x - capRadius, y: centre.y - capRadius,
                width: capRadius * 2, height: capRadius * 2
            ))
            context.fill(
                cap,
                with: .radialGradient(
                    Gradient(colors: [Color(white: 0.20), Color(white: 0.07)]),
                    center: CGPoint(x: centre.x - capRadius * 0.3, y: centre.y - capRadius * 0.35),
                    startRadius: 0,
                    endRadius: capRadius * 1.6
                )
            )

            var ring = capRadius * 0.86
            while ring > capRadius * 0.12 {
                let circle = Path(ellipseIn: CGRect(
                    x: centre.x - ring, y: centre.y - ring,
                    width: ring * 2, height: ring * 2
                ))
                context.stroke(circle, with: .color(.white.opacity(0.045)), lineWidth: 0.7)
                ring -= max(2.4, diameter / 26)
            }

            // A highlight along the top edge, which is what makes metal read.
            var sheen = Path()
            sheen.addArc(
                center: centre,
                radius: radius * 0.93,
                startAngle: .degrees(196),
                endAngle: .degrees(318),
                clockwise: false
            )
            context.stroke(
                sheen,
                with: .color(.white.opacity(0.16)),
                style: StrokeStyle(lineWidth: max(1, diameter / 60), lineCap: .round)
            )
        }
        .frame(width: diameter, height: diameter)
        .overlay {
            Circle().strokeBorder(
                selected ? Color.accentColor : .black.opacity(0.55),
                lineWidth: selected ? 2.5 : 1
            )
        }
        .shadow(color: .black.opacity(0.55), radius: selected ? 9 : 4, y: 2)
    }
}

/// One of the three keys without a display: a rubber dome in a recess.
struct ButtonFace: View {
    var diameter: CGFloat
    var bound: Bool
    var selected: Bool

    var body: some View {
        Canvas { context, size in
            let rect = CGRect(origin: .zero, size: size)
            let centre = CGPoint(x: size.width / 2, y: size.height / 2)

            // The recess it sits in.
            context.fill(
                Path(ellipseIn: rect),
                with: .linearGradient(
                    Gradient(colors: [Color(white: 0.06), Color(white: 0.16)]),
                    startPoint: .zero,
                    endPoint: CGPoint(x: 0, y: size.height)
                )
            )

            // The dome, a little smaller, lit from above.
            let domeRadius = size.width * 0.40
            context.fill(
                Path(ellipseIn: CGRect(
                    x: centre.x - domeRadius, y: centre.y - domeRadius,
                    width: domeRadius * 2, height: domeRadius * 2
                )),
                with: .radialGradient(
                    Gradient(colors: [Color(white: 0.26), Color(white: 0.11)]),
                    center: CGPoint(x: centre.x - domeRadius * 0.35, y: centre.y - domeRadius * 0.4),
                    startRadius: 0,
                    endRadius: domeRadius * 1.7
                )
            )
        }
        .frame(width: diameter, height: diameter)
        .overlay {
            Circle().strokeBorder(
                selected ? Color.accentColor : .black.opacity(0.6),
                lineWidth: selected ? 2.5 : 1
            )
        }
        .overlay {
            // A bound button is left looking exactly like the hardware; what it
            // does belongs in its tooltip, not painted on the plastic.
            if bound && !selected {
                Circle().strokeBorder(.white.opacity(0.16), lineWidth: 1)
            }
        }
        .shadow(color: .black.opacity(0.45), radius: 3, y: 1)
    }
}

/// Our mark where the manufacturer's goes: the same six keys as the app icon,
/// in grey, with the name set the way a wordmark is, thin, wide, upper case.
struct DockBadge: View {
    var scale: CGFloat = 1

    var body: some View {
        HStack(spacing: 7 * scale) {
            Canvas { context, size in
                let key = size.width / 3.6
                let gap = key * 0.26
                let width = 3 * key + 2 * gap
                let height = 2 * key + gap
                let originX = (size.width - width) / 2
                let originY = (size.height - height) / 2

                for row in 0..<2 {
                    for column in 0..<3 {
                        let rect = CGRect(
                            x: originX + CGFloat(column) * (key + gap),
                            y: originY + CGFloat(row) * (key + gap),
                            width: key,
                            height: key
                        )
                        // One key lit, as on the icon, but in grey: this is a
                        // mark on plastic, not a lit display.
                        let lit = row == 0 && column == 1
                        context.fill(
                            Path(roundedRect: rect, cornerRadius: key * 0.26),
                            with: .color(.white.opacity(lit ? 0.52 : 0.22))
                        )
                    }
                }
            }
            .frame(width: 19 * scale, height: 15 * scale)

            Text("PULT")
                .font(.system(size: 13 * scale, weight: .light))
                .tracking(6 * scale)
                .foregroundStyle(.white.opacity(0.34))
        }
    }
}

/// The dock's shell.
struct DockBody<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .frame(width: Dock.body.width, height: Dock.body.height)
            .background {
                RoundedRectangle(cornerRadius: Dock.corner)
                    .fill(
                        LinearGradient(
                            colors: [Color(white: 0.21), Color(white: 0.135), Color(white: 0.115)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .overlay {
                        // A single bright line along the top edge: the one cue
                        // that turns a grey rectangle into a moulded shell.
                        RoundedRectangle(cornerRadius: Dock.corner)
                            .strokeBorder(
                                LinearGradient(
                                    colors: [.white.opacity(0.22), .white.opacity(0.03), .clear],
                                    startPoint: .top,
                                    endPoint: .bottom
                                ),
                                lineWidth: 1
                            )
                    }
            }
            .shadow(color: .black.opacity(0.5), radius: 26, y: 12)
    }
}
