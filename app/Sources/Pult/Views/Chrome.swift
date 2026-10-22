import SwiftUI

/// The furniture every page is built from: a titled header with a round badge,
/// an introduction, and empty states that explain themselves.
///
/// Having these in one place is what keeps three different panes looking like
/// one application rather than three forms.

/// A page's heading: round icon, title, and a sentence saying what the page is.
struct PageHeader: View {
    let title: String
    let symbol: String
    var intro: String?
    /// Shown on the right of the title, for the page's own controls.
    var trailing: AnyView?

    init(_ title: String, symbol: String, intro: String? = nil) {
        self.title = title
        self.symbol = symbol
        self.intro = intro
        self.trailing = nil
    }

    init<Trailing: View>(
        _ title: String,
        symbol: String,
        intro: String? = nil,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.title = title
        self.symbol = symbol
        self.intro = intro
        self.trailing = AnyView(trailing())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 14) {
                Badge(symbol: symbol)

                Text(title)
                    .font(.app(30, weight: .semibold))

                Spacer(minLength: 12)

                if let trailing {
                    trailing
                }
            }

            if let intro {
                Text(intro)
                    .font(.appBody)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 720, alignment: .leading)
            }
        }
    }
}

/// The round, tinted icon that marks a page or an empty state.
struct Badge: View {
    let symbol: String
    var size: CGFloat = 38

    var body: some View {
        ZStack {
            Circle().fill(Color.accentColor.opacity(0.18))
            Image(systemName: symbol)
                .font(.system(size: size * 0.45, weight: .medium))
                .foregroundStyle(.tint)
        }
        .frame(width: size, height: size)
    }
}

/// Nothing to show, said properly: a mark, a line, and an explanation.
struct EmptyState: View {
    let symbol: String
    let title: String
    var detail: String?

    var body: some View {
        VStack(spacing: 12) {
            Badge(symbol: symbol, size: 66)
            Text(title)
                .font(.appTitle3)
            if let detail {
                Text(detail)
                    .font(.appCallout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: 260)
        .frame(maxWidth: .infinity)
    }
}

/// A card that explains itself: icon, title, a line of what it is for, and its
/// action on the right where the eye ends up.
struct ActionCard<Content: View>: View {
    let title: String
    let symbol: String
    var detail: String?
    var tinted = false
    @ViewBuilder let content: Content

    init(
        _ title: String,
        symbol: String,
        detail: String? = nil,
        tinted: Bool = false,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.symbol = symbol
        self.detail = detail
        self.tinted = tinted
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.app(13, weight: .semibold))
                .foregroundStyle(.tint)
                .frame(width: 18)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.appHeadline)
                if let detail {
                    Text(detail)
                        .font(.appCallout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 12)

            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(radius: 16)
    }
}
