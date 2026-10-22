import AppKit
import SwiftUI

/// The app's typeface, and the text styles that honour the size setting.
///
/// Two problems are solved here. `dynamicTypeSize` is an iOS mechanism — on
/// macOS the system text styles do not follow it, so a size setting built on it
/// does nothing; these styles are sized in points and multiplied by the chosen
/// scale instead. And the faces are Inter rather than the system font: drawn
/// for interfaces, with the whole of Latin Extended-A that Serbian needs, and
/// the same face the daemon draws the keys in.
///
/// The drawing of the dock does not use these styles on purpose: its captions
/// are sized to the plastic, not to the reader.
enum Typeface {
    static let family = "Inter"

    /// Registered from the app bundle at launch. If the files are missing —
    /// running the executable straight out of the build directory, say — every
    /// `.custom` call quietly falls back to the system font.
    static func register() {
        guard let resources = Bundle.main.resourceURL?.appending(path: "Fonts") else { return }
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: resources,
            includingPropertiesForKeys: nil
        ) else { return }

        for file in files where file.pathExtension.lowercased() == "ttf" {
            CTFontManagerRegisterFontsForURL(file as CFURL, .process, nil)
        }
    }

    /// The PostScript name for a weight, so the real face is used rather than
    /// a synthesised one.
    static func name(for weight: Font.Weight) -> String {
        switch weight {
        case .ultraLight, .thin, .light: return "Inter-Light"
        case .medium: return "Inter-Medium"
        case .semibold: return "Inter-SemiBold"
        case .bold, .heavy, .black: return "Inter-Bold"
        default: return "Inter-Regular"
        }
    }
}

extension Font {
    static var appLargeTitle: Font { .app(26, weight: .semibold) }
    static var appTitle: Font { .app(22) }
    static var appTitle2: Font { .app(17, weight: .semibold) }
    static var appTitle3: Font { .app(15, weight: .medium) }
    static var appHeadline: Font { .app(13, weight: .semibold) }
    static var appBody: Font { .app(13) }
    static var appCallout: Font { .app(12) }
    static var appSubheadline: Font { .app(11) }
    static var appFootnote: Font { .app(10) }
    static var appCaption: Font { .app(10) }
    static var appCaption2: Font { .app(9) }

    /// A size in points, in Inter, scaled by the text-size setting.
    static func app(_ size: CGFloat, weight: Weight = .regular) -> Font {
        .custom(Typeface.name(for: weight), fixedSize: size * Theme.shared.textScale)
    }
}
