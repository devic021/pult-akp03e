import SwiftUI

/// Where the numbers on the keys come from.
///
/// Two questions, in the order they matter: does the dock know where it is,
/// and is each source answering. Everything else on the page is in service of
/// those — including the list of field names, which is what a template has to
/// be written against.
struct FeedsView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var l10n: L10n
    @StateObject private var locator = Locator()

    @State private var lat = ""
    @State private var lon = ""
    @State private var saving = false
    @State private var problem: String?
    @State private var checking: String?
    @State private var copied: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                PageHeader(
                    T("nav.feeds"),
                    symbol: "antenna.radiowaves.left.and.right",
                    intro: T("feeds.says")
                )

                place
                sources
            }
            .padding(Design.pagePadding)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task {
            // Ages tick, so the page asks again while it is open. A few
            // hundred bytes every five seconds, and nothing at all once the
            // pane is closed and the task is cancelled.
            while !Task.isCancelled {
                state.loadFeeds()
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
        .onChange(of: state.feeds.places) { _ in adoptPlaces() }
        .onAppear { adoptPlaces() }
    }

    // MARK: - Where the dock is

    private var place: some View {
        Section2(T("section.place"), symbol: "location") {
            ActionCard(
                T("feeds.place"),
                symbol: "mappin.and.ellipse",
                detail: T("feeds.place.help")
            ) {
                HStack(spacing: 8) {
                    coordinate(T("feeds.place.lat"), $lat)
                    coordinate(T("feeds.place.lon"), $lon)
                    Button(T("feeds.place.save")) { save() }
                        .buttonStyle(.pultProminent)
                        .disabled(coordinates == nil || saving)
                }
            }

            ActionCard(
                T("feeds.place.find"),
                symbol: "location.circle",
                detail: T("feeds.place.find.help")
            ) {
                Button(locator.asking ? T("feeds.place.asking") : T("feeds.place.find")) {
                    locator.find { latitude, longitude in
                        lat = String(format: "%.3f", latitude)
                        lon = String(format: "%.3f", longitude)
                        save()
                    }
                }
                .buttonStyle(.pult)
                .disabled(locator.asking)
            }

            if let message = problem ?? locator.problem {
                note(message, tone: Design.bad, symbol: "exclamationmark.triangle")
            } else if !state.feeds.located && !state.feeds.feeds.isEmpty {
                note(T("feeds.place.unset"), tone: Design.warn, symbol: "mappin.slash")
            }
        }
    }

    private func coordinate(_ title: String, _ text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.appCaption)
                .foregroundStyle(.secondary)
            TextField("", text: text, prompt: Text(title == T("feeds.place.lat") ? "45.267" : "19.834"))
                .textFieldStyle(.roundedBorder)
                .font(.appCallout.monospacedDigit())
                .frame(width: 90)
        }
    }

    /// Both numbers, or nothing: half a position is not a position.
    private var coordinates: (Double, Double)? {
        guard
            let latitude = Double(lat.replacingOccurrences(of: ",", with: ".")),
            let longitude = Double(lon.replacingOccurrences(of: ",", with: ".")),
            (-90...90).contains(latitude), (-180...180).contains(longitude)
        else { return nil }
        return (latitude, longitude)
    }

    private func save() {
        guard let (latitude, longitude) = coordinates else { return }
        saving = true
        problem = nil
        state.setPlace(latitude: latitude, longitude: longitude) { failure in
            saving = false
            problem = failure
        }
    }

    /// Takes the daemon's answer, unless something is being typed into the
    /// fields right now — overwriting a half-typed number is maddening.
    private func adoptPlaces() {
        guard coordinates == nil || (lat.isEmpty && lon.isEmpty) else { return }
        lat = state.feeds.places["lat"] ?? lat
        lon = state.feeds.places["lon"] ?? lon
    }

    // MARK: - The sources

    private var sources: some View {
        Section2(T("section.sources"), symbol: "arrow.down.circle") {
            if state.feeds.feeds.isEmpty {
                ActionCard(T("feeds.none"), symbol: "tray", detail: T("feeds.none.help")) {
                    EmptyView()
                }
            } else {
                if state.feeds.hour != 0 {
                    note(
                        "\(T("feeds.hour")) +\(state.feeds.hour) \(T("feeds.hour.ahead"))",
                        tone: Design.accent,
                        symbol: "clock.arrow.circlepath"
                    )
                }
                ForEach(state.feeds.feeds) { feed in
                    FeedCard(
                        feed: feed,
                        checking: checking == feed.name,
                        copied: copied,
                        check: {
                            checking = feed.name
                            state.loadFeeds(check: feed.name)
                            // The reply replaces the whole report, so there is
                            // nothing to wait for beyond the next poll of the
                            // page; a second is enough for the button to have
                            // visibly done something.
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                                if checking == feed.name { checking = nil }
                            }
                        },
                        copy: { template in
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(template, forType: .string)
                            copied = template
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                if copied == template { copied = nil }
                            }
                        }
                    )
                }
            }
        }
    }

    private func note(_ message: String, tone: Color, symbol: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.app(12, weight: .semibold))
                .foregroundStyle(tone)
            Text(message)
                .font(.appCallout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(radius: 16)
    }
}

/// One source, and everything that answers "is it working".
private struct FeedCard: View {
    let feed: FeedStatus
    var checking: Bool
    var copied: String?
    var check: () -> Void
    var copy: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Circle()
                    .fill(tone)
                    .frame(width: 9, height: 9)
                    .padding(.top, 6)
                    .help(toneSays)

                VStack(alignment: .leading, spacing: 4) {
                    Text(feed.name).font(.appHeadline)
                    Text(subtitle)
                        .font(.appCallout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .help(feed.source ?? "")
                }

                Spacer(minLength: 12)

                VStack(alignment: .trailing, spacing: 6) {
                    Text(age)
                        .font(.appCaption.monospacedDigit())
                        .foregroundStyle(feed.stale ? Design.warn : .secondary)
                    Button(checking ? T("feeds.checking") : T("feeds.check"), action: check)
                        .buttonStyle(.pult)
                        .disabled(checking)
                }
            }

            if let error = feed.error {
                Text(error)
                    .font(.appCaption)
                    .foregroundStyle(Design.bad)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !feed.fields.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(T("feeds.fields.help"))
                        .font(.appCaption)
                        .foregroundStyle(.secondary)

                    FlowRow(spacing: 6) {
                        ForEach(feed.fieldNames, id: \.self) { name in
                            let template = "{\(feed.name).\(name)}"
                            Button {
                                copy(template)
                            } label: {
                                HStack(spacing: 5) {
                                    Text(name)
                                        .font(.appCaption.weight(.medium))
                                    Text(feed.fields[name] ?? "")
                                        .font(.appCaption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                    if feed.series[name] != nil || feed.series.values.first != nil,
                                       feed.series.contains(where: { $0.key.hasPrefix(name) }) {
                                        Image(systemName: "chart.xyaxis.line")
                                            .font(.app(9))
                                            .foregroundStyle(Design.accent)
                                            .help(T("feeds.series"))
                                    }
                                    if copied == template {
                                        Image(systemName: "checkmark")
                                            .font(.app(9, weight: .bold))
                                            .foregroundStyle(Design.good)
                                    }
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background {
                                    RoundedRectangle(cornerRadius: Design.radiusField)
                                        .fill(Design.accentSoft)
                                }
                            }
                            .buttonStyle(.plain)
                            .help(template)
                        }
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(radius: 16)
    }

    private var tone: Color {
        switch feed.health {
        case .fresh: return Design.good
        case .stale: return Design.warn
        case .silent: return Design.muted
        case .failing: return Design.bad
        }
    }

    private var toneSays: String {
        switch feed.health {
        case .fresh: return T("feeds.health.fresh")
        case .stale: return T("feeds.health.stale.help")
        case .silent: return T("feeds.health.silent")
        case .failing: return T("feeds.health.failing")
        }
    }

    /// The host rather than the whole address: a weather URL is three lines of
    /// query string, and none of it answers "where is this coming from".
    private var subtitle: String {
        let origin = feed.source.flatMap { URL(string: $0)?.host } ?? feed.source ?? feed.kind
        return "\(origin) \u{00b7} \(T("feeds.every")) \(feed.every)"
    }

    private var age: String {
        guard let seconds = feed.age else { return T("feeds.age.never") }
        let text: String
        if seconds >= 86_400 {
            text = "\(seconds / 86_400)d"
        } else if seconds >= 3600 {
            text = "\(seconds / 3600)h"
        } else if seconds >= 60 {
            text = "\(seconds / 60)m"
        } else {
            text = "\(seconds)s"
        }
        return "\(text) \(T("feeds.age.ago"))"
    }
}
