// CollectionsListView.swift — the COLLECTIONS content column (UX addendum
// §26.1). A collection is a saved slot→preset arrangement over the content-
// addressed library; this screen lists them and offers Create-from-Device and
// Import-Bank. Nothing here writes to the device — Apply lives in the detail
// view behind its pre-flight (§27).

import SwiftUI
import UniformTypeIdentifiers
import FreakCore

struct CollectionsListView: View {
    @Environment(AppModel.self) private var model
    @State private var showImporter = false
    @State private var renamingID: String?
    @State private var deleteCandidate: PresetCollection?

    private static let bankTypes: [UTType] =
        [UTType(filenameExtension: "mfprojz"),
         UTType(filenameExtension: "mbp")].compactMap { $0 } + [.data]

    var body: some View {
        Group {
            if model.collectionsModel.collections.isEmpty {
                emptyState
            } else {
                list
            }
        }
        .navigationTitle("Collections")
        .toolbar { toolbar }
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: Self.bankTypes,
                      allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first {
                model.importBank(url: url)
            }
        }
        .alert(item: $deleteCandidate) { coll in
            Alert(
                title: Text("Delete collection '\(coll.name)'?"),
                message: Text("This removes the saved arrangement only. The "
                    + "referenced library presets are untouched — deleting a "
                    + "collection never deletes presets."),
                primaryButton: .destructive(Text("Delete Collection")) {
                    Task { await model.collectionsModel
                        .delete(id: coll.id, in: model.libraryModel.library) }
                },
                secondaryButton: .cancel())
        }
    }

    private var list: some View {
        List {
            ForEach(model.collectionsModel.sorted) { coll in
                if renamingID == coll.id {
                    RenameField(original: coll.name) { newName in
                        renamingID = nil
                        Task { await model.collectionsModel.rename(
                            id: coll.id, to: newName,
                            in: model.libraryModel.library) }
                    } cancel: { renamingID = nil }
                } else {
                    CollectionRowView(collection: coll)
                        .onTapGesture {
                            model.sidebar = .collection(id: coll.id)
                            model.detail = .collection(id: coll.id)
                        }
                        .contextMenu { rowMenu(coll) }
                }
            }
        }
        .listStyle(.plain)
    }

    @ViewBuilder
    private func rowMenu(_ coll: PresetCollection) -> some View {
        Button {
            model.requestCollectionApply(id: coll.id)
        } label: {
            Label("Apply / Switch…", systemImage: "arrow.right.arrow.left")
        }
        .disabled(!model.connection.hasDevice)
        Button { renamingID = coll.id } label: {
            Label("Rename", systemImage: "pencil")
        }
        Button {
            Task { await model.collectionsModel
                .duplicate(id: coll.id, in: model.libraryModel.library) }
        } label: {
            Label("Duplicate", systemImage: "plus.square.on.square")
        }
        Divider()
        Button(role: .destructive) { deleteCandidate = coll } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Menu {
                Picker("Sort", selection: Binding(
                    get: { model.collectionsModel.sort },
                    set: { model.collectionsModel.sort = $0 })) {
                    ForEach(CollectionsModel.Sort.allCases) { sort in
                        Text(sort.title).tag(sort)
                    }
                }
            } label: { Label("Sort", systemImage: "arrow.up.arrow.down") }
            Button {
                model.requestNewCollectionFromDevice()
            } label: {
                Label("Create from Device…", systemImage: "square.and.arrow.down.on.square")
            }
            .disabled(!model.connection.hasDevice)
            Button { showImporter = true } label: {
                Label("Import Bank…", systemImage: "tray.and.arrow.down")
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No collections yet", systemImage: "square.stack.3d.up")
        } description: {
            Text("A collection is a saved slot layout — snapshot the device "
                 + "or import a bank, then apply it to switch the synth fast.")
        } actions: {
            Button("Create from the current device") {
                model.requestNewCollectionFromDevice()
            }
            .buttonStyle(.borderedProminent)
            .disabled(!model.connection.hasDevice)
            Button("Import a bank (.mfprojz / .mbp)") { showImporter = true }
                .buttonStyle(.bordered)
        }
    }
}

#Preview("Collections") {
    PreviewHost { _ in
        NavigationStack { CollectionsListView() }
    }
}
