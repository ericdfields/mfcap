// FavoritesListView.swift — favorited presets across library and device
// (UX addendum §24.3).
//
// Favorite is a library attribute, so this view is device-independent and
// survives identity switches; the per-row device-presence hint simply clears
// when nothing is connected. The CategoryFilterBar and tag facets apply here
// too (favorites ∧ category ∧ tags), with counts scoped to favorites.

import SwiftUI
import FreakCore

struct FavoritesListView: View {
    @Environment(AppModel.self) private var model

    @State private var deleteCandidate: LibraryEntry?
    @State private var renamingEntry: String?

    var body: some View {
        @Bindable var libraryModel = model.libraryModel
        Group {
            if model.libraryModel.favorites.isEmpty
                && model.libraryModel.categoryFilter == nil
                && model.libraryModel.tagFilter.isEmpty {
                emptyState
            } else {
                list
            }
        }
        .navigationTitle("Favorites")
        .searchable(text: $libraryModel.searchText, prompt: "Name or tag")
        .safeAreaInset(edge: .top, spacing: 0) { CategoryFilterBar() }
        .onAppear { model.libraryModel.favoritesOnly = true }
        .onDisappear { model.libraryModel.favoritesOnly = false }
        .alert(item: $deleteCandidate) { entry in
            Alert(
                title: Text("Remove '\(entry.name)' from the library?"),
                message: Text("This deletes the library entry. Unfavorite it "
                    + "instead if you only want it out of Favorites."),
                primaryButton: .destructive(Text("Delete Entry")) {
                    Task { try? await model.libraryModel.delete(id: entry.id) }
                },
                secondaryButton: .cancel())
        }
    }

    private var list: some View {
        List {
            ForEach(model.libraryModel.filtered(tag: nil)) { entry in
                LibraryRowView(entry: entry, renamingEntry: $renamingEntry,
                               requestDelete: { deleteCandidate = $0 })
            }
        }
        .listStyle(.plain)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No favorites yet", systemImage: "heart")
        } description: {
            Text("Tap the heart on any preset — in the library or on the "
                 + "device — to keep it here.")
        } actions: {
            Button("Browse the device") { model.sidebar = .device }
                .buttonStyle(.borderedProminent)
            Button("Browse the library") { model.sidebar = .library(tag: nil) }
                .buttonStyle(.bordered)
        }
    }
}

#Preview("Favorites") {
    PreviewHost { _ in
        NavigationStack { FavoritesListView() }
    }
}
