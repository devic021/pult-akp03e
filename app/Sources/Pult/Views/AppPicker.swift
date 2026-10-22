import SwiftUI

/// Picking an application, used both for what a scene claims and for what a
/// key opens. One list, so the two never drift apart.
struct AppPickerPopover: View {
    @StateObject private var installed = Installed.shared
    @State private var search = ""
    /// Bundle IDs already chosen, shown ticked.
    var chosen: Set<String> = []
    let onPick: (Installed.App) -> Void

    private var matches: [Installed.App] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return installed.apps }
        return installed.apps.filter {
            $0.name.lowercased().contains(query) || $0.bundleID.lowercased().contains(query)
        }
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(T("action.app.choose"), text: $search)
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .glassEffect(in: .capsule)

            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(matches) { app in
                        Button {
                            onPick(app)
                        } label: {
                            HStack(spacing: 9) {
                                Image(nsImage: installed.icon(for: app))
                                    .resizable()
                                    .frame(width: 22, height: 22)
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(app.name).lineLimit(1)
                                    Text(app.bundleID)
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                        .lineLimit(1)
                                }
                                Spacer()
                                if chosen.contains(app.bundleID) {
                                    Image(systemName: "checkmark").foregroundStyle(.tint)
                                }
                            }
                            .padding(.horizontal, 7)
                            .padding(.vertical, 4)
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if installed.apps.isEmpty {
                ProgressView().controlSize(.small)
            }
        }
        .padding(12)
        .frame(width: 340, height: 400)
        .task { installed.load() }
    }
}

/// An application shown as itself: its icon and its name, with the bundle ID
/// kept for the tooltip. A row of reverse-DNS strings tells you nothing.
struct AppChip: View {
    @EnvironmentObject private var state: AppState
    @StateObject private var installed = Installed.shared
    let bundleID: String
    var onRemove: (() -> Void)?

    private var app: Installed.App? {
        installed.apps.first { $0.bundleID == bundleID }
    }

    private var name: String {
        app?.name ?? state.name(ofApp: bundleID)
    }

    var body: some View {
        HStack(spacing: 6) {
            if let app {
                Image(nsImage: installed.icon(for: app))
                    .resizable()
                    .frame(width: 16, height: 16)
            } else if let icon = state.runningIcons[bundleID] {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 16, height: 16)
            } else {
                Image(systemName: "app.dashed")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Text(name).font(.callout).lineLimit(1)

            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .glassEffect(in: .capsule)
        .help(bundleID)
        .task { installed.load() }
    }
}
