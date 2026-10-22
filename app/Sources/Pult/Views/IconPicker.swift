import SwiftUI

/// One icon, drawn by the daemon so it matches the dock exactly.
struct IconThumb: View {
    @EnvironmentObject private var state: AppState
    let name: String?
    var size: CGFloat = 28
    var color: String?

    var body: some View {
        Group {
            if let name,
               let image = state.image(for: Key(
                   color: "#1c1f26",
                   icon: name,
                   icon_color: color ?? "#f5f5f5"
               ), size: 96) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 5))
            } else if name != nil {
                ProgressView().controlSize(.mini)
            } else {
                Image(systemName: "square.dashed")
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(width: size, height: size)
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
        return query.isEmpty
            ? state.icons
            : state.icons.filter { $0.contains(query) }
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(T("key.icon.choose"), text: $search)
                    .textFieldStyle(.plain)
                Button(T("key.icon.none")) {
                    selection = nil
                    dismiss()
                }
                .buttonStyle(.borderless)
            }

            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(44), spacing: 8), count: 8), spacing: 8) {
                    ForEach(matches, id: \.self) { name in
                        Button {
                            selection = name
                            dismiss()
                        } label: {
                            IconThumb(name: name, size: 36)
                                .padding(3)
                                .background(
                                    RoundedRectangle(cornerRadius: 7)
                                        .fill(selection == name ? Color.accentColor.opacity(0.3) : .clear)
                                )
                        }
                        .buttonStyle(.plain)
                        .help(name)
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .padding(12)
        .frame(width: 440, height: 360)
    }
}
