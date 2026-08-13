import SwiftUI

struct ReciterSidebarView: View {
    @ObservedObject var store: LibraryStore

    private var selection: Binding<String?> {
        Binding(
            get: { store.selectedReciterID },
            set: { id in Task { await store.selectReciter(id) } }
        )
    }

    var body: some View {
        List(selection: selection) {
            Section(store.preferences.text("Favorites")) {
                ForEach(store.reciterGroups.favorites) { row in
                    ReciterRow(store: store, row: row, favorite: true)
                        .tag(row.id)
                }
            }

            Section(store.preferences.text("All reciters")) {
                ForEach(store.reciterGroups.all) { row in
                    ReciterRow(store: store, row: row, favorite: false)
                        .tag(row.id)
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle(store.preferences.text("Reciters"))
        .searchable(
            text: $store.reciterSearch,
            placement: .sidebar,
            prompt: store.preferences.text("Search reciters")
        )
        .toolbar {
            ToolbarItem {
                Button {
                    store.reciterDirection = store.reciterDirection == .ascending
                        ? .descending : .ascending
                } label: {
                    Image(systemName: store.reciterDirection == .ascending
                        ? "text.line.first.and.arrowtriangle.forward"
                        : "text.line.last.and.arrowtriangle.forward")
                }
                .help(store.preferences.text(
                    store.reciterDirection == .ascending ? "Sort descending" : "Sort ascending"
                ))
                .accessibilityIdentifier("reciters.sort")
            }
        }
        .overlay {
            if store.reciterGroups.favorites.isEmpty && store.reciterGroups.all.isEmpty {
                ContentUnavailableView.search(text: store.reciterSearch)
            }
        }
        .accessibilityIdentifier("reciters.sidebar")
    }
}

private struct ReciterRow: View {
    @ObservedObject var store: LibraryStore
    let row: ReciterPresentation
    let favorite: Bool

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "person.wave.2")
                .foregroundStyle(.secondary)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(row.reciter.displayName(language: store.preferences.resolvedLanguage))
                    .lineLimit(1)
                if row.cachedCount > 0 {
                    Label("\(row.cachedCount)", systemImage: "arrow.down.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("\(row.cachedCount) \(store.preferences.text("Cached"))")
                }
            }
            Spacer(minLength: 4)
            Button {
                Task { await store.toggleFavorite(reciterID: row.id) }
            } label: {
                Image(systemName: favorite ? "star.fill" : "star")
                    .foregroundStyle(favorite ? .yellow : .secondary)
            }
            .buttonStyle(.plain)
            .help(store.preferences.text("Favorites"))
            .accessibilityIdentifier("reciter.\(row.id).favorite")
        }
        .contentShape(.rect)
        .accessibilityIdentifier("reciter.\(row.id)")
    }
}
