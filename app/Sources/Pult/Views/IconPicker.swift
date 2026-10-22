import SwiftUI

/// One icon, out of the sheet the daemon rendered in a single round trip.
struct IconThumb: View {
    @EnvironmentObject private var state: AppState
    let name: String?
    var size: CGFloat = 28

    var body: some View {
        Group {
            if let name, let image = state.iconSheet[name] {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 5))
            } else if name != nil {
                RoundedRectangle(cornerRadius: 5).fill(.white.opacity(0.06))
            } else {
                Image(systemName: "square.dashed").foregroundStyle(.tertiary)
            }
        }
        .frame(width: size, height: size)
        .task { state.loadIconSheet() }
    }
}

/// The bundled set, searchable.
struct IconPicker: View {
    @EnvironmentObject private var state: AppState
    @Binding var selection: String?
    let dismiss: () -> Void
    @State private var search = ""

    private var matches: [String] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        return query.isEmpty ? state.icons : state.icons.filter { $0.contains(query) }
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(T("key.icon.choose"), text: $search)
                    .textFieldStyle(.plain)
                Button(T("key.icon.none")) {
                    selection = nil
                    dismiss()
                }
                .buttonStyle(.glass)
                .controlSize(.small)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .glassEffect(in: .capsule)

            ScrollView {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.fixed(46), spacing: 10), count: 8),
                    spacing: 10
                ) {
                    ForEach(matches, id: \.self) { name in
                        Button {
                            selection = name
                            dismiss()
                        } label: {
                            IconThumb(name: name, size: 38)
                                .padding(4)
                                .background {
                                    RoundedRectangle(cornerRadius: 9)
                                        .fill(selection == name
                                              ? Color.accentColor.opacity(0.35)
                                              : Color.white.opacity(0.04))
                                }
                        }
                        .buttonStyle(.plain)
                        .help(name)
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .padding(14)
        .frame(width: 470, height: 390)
        .task { state.loadIconSheet() }
    }
}
