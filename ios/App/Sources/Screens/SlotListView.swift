// SlotListView.swift — the home screen: all 512 slots, always (UX §5).
//
// Names-first: rows render instantly from cache, names stream in during the
// ~2 s names pass (shimmer, not a wait screen), search is cache-only and
// never reads, and rows NEVER trigger blob reads — judgment costs are always
// explicit. Bank sections have sticky headers with judged counts; sidebar
// bank rows jump here via ScrollViewReader.

import SwiftUI

struct SlotListView: View {
    @Environment(AppModel.self) private var model
    @State private var editMode: EditMode = .inactive
    @State private var selection = Set<Int>()
    @State private var renamingSlot: SlotID?

    var body: some View {
        @Bindable var slots = model.slots
        ScrollViewReader { proxy in
            List(selection: $selection) {
                if model.slots.stale {
                    staleBanner
                }
                if let error = model.slots.namesError {
                    namesErrorBanner(error)
                }
                ForEach(0..<SlotID.Layout.banks, id: \.self) { bank in
                    bankSection(bank)
                }
            }
            .listStyle(.plain)
            .environment(\.editMode, $editMode)
            .searchable(text: $slots.searchText,
                        prompt: "Name or slot number")
            .onChange(of: model.bankJumpRequest) { _, request in
                guard let bank = request else { return }
                withAnimation { proxy.scrollTo("bank-\(bank)", anchor: .top) }
                model.bankJumpRequest = nil
            }
        }
        .navigationTitle("Device")
        .toolbar { toolbarContent }
        .safeAreaInset(edge: .bottom) {
            if editMode == .active { multiSelectBar }
        }
        .saturation(model.slots.stale ? 0.35 : 1.0)
    }

    // ------------------------------------------------------------- sections

    @ViewBuilder
    private func bankSection(_ bank: Int) -> some View {
        let visible = Set(model.slots.filteredSlots.map(\.raw))
        let bankSlots = SlotID.bankSlots(bank).filter { visible.contains($0.raw) }
        if !bankSlots.isEmpty {
            Section {
                ForEach(bankSlots) { slot in
                    SlotRowView(slot: slot, renamingSlot: $renamingSlot)
                        .id(slot.raw)
                        .tag(slot.raw)
                }
            } header: {
                BankSectionHeader(bank: bank)
                    .id("bank-\(bank)")
            }
        }
    }

    // -------------------------------------------------------------- banners

    private var staleBanner: some View {
        Label {
            Text("Showing last known state"
                 + (model.slots.namesAsOf.map {
                     " from \(Format.timeOfDay($0))"
                 } ?? "")
                 + " — no device.")
        } icon: {
            Image(systemName: "bolt.horizontal.circle")
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .listRowBackground(Color.yellow.opacity(0.1))
    }

    private func namesErrorBanner(_ error: String) -> some View {
        HStack {
            Label(error, systemImage: "exclamationmark.triangle")
                .font(.callout)
            Spacer()
            Button("Retry") { _ = model.refreshNames() }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .listRowBackground(Color.red.opacity(0.08))
    }

    // -------------------------------------------------------------- toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                _ = model.refreshNames()
            } label: {
                if model.slots.refreshingNames {
                    ProgressView()
                } else {
                    Label(refreshLabel, systemImage: "arrow.clockwise")
                }
            }
            .disabled(!model.connection.hasDevice
                      || model.operations.exclusiveLongOp != nil)

            Button(editMode == .active ? "Done" : "Select") {
                withAnimation {
                    editMode = editMode == .active ? .inactive : .active
                    if editMode == .inactive { selection.removeAll() }
                }
            }

            Button {
                model.backUpNow()
            } label: {
                Label("Back Up Now", systemImage: "externaldrive.badge.plus")
            }
            .disabled(!model.connection.hasDevice
                      || model.operations.exclusiveLongOp != nil)
            .help("Reads all 512 slots, about 3½ minutes. "
                  + "The device is never modified by a backup.")
        }
    }

    private var refreshLabel: String {
        guard let asOf = model.slots.namesAsOf else { return "Refresh Names" }
        return "Names \(Format.relativeAge(asOf))"
    }

    // ---------------------------------------------- multi-select (UX §5, §13)

    private var multiSelectBar: some View {
        HStack {
            Text("\(selection.count) selected")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Save \(selection.count) to Library") {
                // Instant when blobs are on disk; otherwise the model states
                // the ~400 ms × N read cost first (UX §5).
                model.saveManyToLibrary(selection.sorted().map(SlotID.init))
                editMode = .inactive
                selection.removeAll()
            }
            .buttonStyle(.bordered)
            .disabled(selection.isEmpty)
            Button("Send \(selection.count) starting at slot…") {
                let transfers = selection.sorted().compactMap { raw
                    -> PresetTransfer? in
                    let slot = SlotID(raw)
                    guard let row = model.slots.record(slot),
                          row.hasKnownName else { return nil }
                    return PresetTransfer(source: .deviceSlot(slot),
                                          displayName: row.name ?? "")
                }
                model.requestSlotPicker(for: transfers)
                editMode = .inactive
                selection.removeAll()
            }
            .buttonStyle(.borderedProminent)
            .disabled(selection.isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial)
    }
}

// ============================================================ section header

struct BankSectionHeader: View {
    @Environment(AppModel.self) private var model
    let bank: Int

    var body: some View {
        HStack {
            Text(SlotID.bankLabel(bank))
                .font(.subheadline.weight(.semibold))
            Spacer()
            if let summary = model.slots.bankSummary(bank) {
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

#Preview("Slot browser", traits: .landscapeLeft) {
    PreviewHost { _ in
        NavigationStack { SlotListView() }
    }
}
