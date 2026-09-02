// CollectionDetailView.swift — one collection's detail (UX addendum §26.4).
//
// Header (name / provenance / count / created), a compact slot map of the
// occupied slots grouped by bank, and the bottom-anchored Apply / Switch
// action behind its §27 pre-flight. Rows are read-only — a collection is a
// saved plan; attributes are edited on the library copies. A live readiness
// line appears when the device is hashed, computed from the same pure diff
// the pre-flight uses, so detail and sheet never disagree.

import SwiftUI
import FreakCore

struct CollectionDetailView: View {
    @Environment(AppModel.self) private var model
    let collectionID: String

    @State private var renaming = false
    @State private var confirmDelete = false
    @State private var readiness: String?

    private var collection: PresetCollection? {
        model.collectionsModel.collection(id: collectionID)
    }

    var body: some View {
        Group {
            if let collection {
                detail(collection)
            } else {
                ContentUnavailableView("That collection is no longer here.",
                                       systemImage: "square.stack.3d.up.slash")
            }
        }
        .navigationTitle(collection?.name ?? "Collection")
    }

    private func detail(_ coll: PresetCollection) -> some View {
        List {
            headerSection(coll)
            slotMapSection(coll)
            actionsSection(coll)
        }
        .listStyle(.insetGrouped)
        .safeAreaInset(edge: .bottom) { applyBar(coll) }
        .task(id: coll.id) { readiness = model.collectionChangeSummary(coll) }
        .onChange(of: model.slots.hashedAsOf) { _, _ in
            readiness = model.collectionChangeSummary(coll)
        }
        .alert("Delete collection '\(coll.name)'?", isPresented: $confirmDelete) {
            Button("Delete Collection", role: .destructive) {
                Task {
                    await model.collectionsModel.delete(
                        id: coll.id, in: model.libraryModel.library)
                    model.detail = nil
                    model.sidebar = .collections
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes the saved arrangement only — the referenced library "
                 + "presets are untouched.")
        }
    }

    // ------------------------------------------------------------- header

    private func headerSection(_ coll: PresetCollection) -> some View {
        Section {
            if renaming {
                RenameField(original: coll.name) { newName in
                    renaming = false
                    Task { await model.collectionsModel.rename(
                        id: coll.id, to: newName,
                        in: model.libraryModel.library) }
                } cancel: { renaming = false }
                .font(.title2)
            } else {
                Button { renaming = true } label: {
                    HStack {
                        Text(coll.name).font(.title2.weight(.semibold))
                        Image(systemName: "pencil").font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
            }
            ProvenanceLabel(provenance: coll.provenance)
            LabeledContent("Presets", value: "\(coll.slots.count)")
            LabeledContent("Created") {
                Text(Format.parseCoreTimestamp(coll.createdAt)
                    .map { Format.relativeAge($0) } ?? coll.createdAt)
            }
        }
    }

    // ----------------------------------------------------------- slot map

    private func slotMapSection(_ coll: PresetCollection) -> some View {
        let occupied = coll.coveredSlots()
        return ForEach(0..<SlotID.Layout.banks, id: \.self) { bank in
            let inBank = occupied.filter { SlotID($0).bank == bank }
            if !inBank.isEmpty {
                Section(SlotID.bankLabel(bank)) {
                    ForEach(inBank, id: \.self) { raw in
                        if let ref = coll.slots[raw] {
                            HStack(spacing: 10) {
                                SlotNumberLabel(slot: SlotID(raw))
                                Text(ref.name).font(.callout)
                                Spacer()
                                CategoryBadge(category: category(of: ref))
                            }
                        }
                    }
                }
            }
        }
    }

    /// Decode the ref's stored meta byte 7 for a display-only category badge
    /// (data-model spec §1.1). Never edited here.
    private func category(of ref: PresetRef) -> FreakCore.Category {
        guard let meta = MFPresetFile.data(hex: ref.metaHex), meta.count >= 8
        else { return .uncategorized }
        return FreakCore.Category.fromDeviceByte(meta[7])
    }

    // ----------------------------------------------------------- actions

    private func actionsSection(_ coll: PresetCollection) -> some View {
        Section {
            Button {
                Task { await model.collectionsModel.duplicate(
                    id: coll.id, in: model.libraryModel.library) }
            } label: {
                Label("Duplicate", systemImage: "plus.square.on.square")
            }
            if let url = fileURL(coll) {
                ShareLink(item: url) {
                    Label("Export Collection…", systemImage: "square.and.arrow.up")
                }
            }
            Button(role: .destructive) { confirmDelete = true } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private func applyBar(_ coll: PresetCollection) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let readiness {
                Text(readiness).font(.caption).foregroundStyle(.secondary)
            } else if !model.connection.hasDevice {
                Text("Connect a device to switch to this collection.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Read the device to see how many slots would change.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button {
                model.requestCollectionApply(id: coll.id)
            } label: {
                Label("Apply / Switch…", systemImage: "arrow.right.arrow.left")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!model.connection.hasDevice)
        }
        .padding(16)
        .background(.thinMaterial)
    }

    private func fileURL(_ coll: PresetCollection) -> URL? {
        guard let root = model.libraryModel.library?.root else { return nil }
        let url = root.appendingPathComponent("collections")
            .appendingPathComponent("\(coll.id).json")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}

#Preview("Collection detail") {
    PreviewHost { _ in
        NavigationStack { CollectionDetailView(collectionID: "missing") }
    }
}
