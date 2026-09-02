// SyncListView.swift — device vs. ONE CHOSEN COLLECTION, one row per slot
// (UX §17).
//
// Sync answers "how does my device differ from this arrangement?" — a
// question the user asks by picking a baseline. The library is a catalog of
// every patch owned, not a description of where things belong, so it is never
// the baseline.
//
// The diff computes; only explicit user actions write. The precondition
// banner is the honest gate: no baseline → the picker state; no hashed
// snapshot → the CTA pricing the full pass (~3½ minutes, kept as a backup).
// Filter bar with live counts; per-status explicit actions in the row's
// context menu and swipe actions (the row itself gives its width to the
// preset NAME, which is what the screen exists to show).

import SwiftUI
import FreakCore

struct SyncListView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            switch model.sync.state {
            case .needsBaseline:
                needsBaselineState
            case .needsSnapshot:
                needsSnapshotState
            case .comparing:
                comparingState
            case .failed(let message):
                failedState(message)
            case .ready:
                readyList
            }
        }
        .navigationTitle("Sync")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    if let baseline = model.sync.baseline {
                        Button("Make Device Match '\(baseline.name)'…") {
                            model.requestCollectionApply(id: baseline.id)
                        }
                        .disabled(model.sync.state != .ready
                                  || !model.connection.hasDevice
                                  || model.operations.exclusiveLongOp != nil)
                    }
                    Button("Save Unlisted Presets to Library…") {
                        model.saveUnlistedToLibrary()
                    }
                    .disabled(model.sync.state != .ready)
                } label: {
                    Text("Apply…")
                }
                .disabled(model.sync.state != .ready)
            }
        }
    }

    // -------------------------------------------------------------- states

    /// No baseline chosen: explain the model, never show a diff (UX §17).
    private var needsBaselineState: some View {
        ContentUnavailableView {
            Label("Pick something to compare against",
                  systemImage: "square.on.square.dashed")
        } description: {
            Text("Sync compares your device to one collection — an "
                 + "arrangement you saved or imported. Your library is a "
                 + "catalog of every patch you own; it doesn't describe "
                 + "where things should sit on the device.")
        } actions: {
            if !model.collectionsModel.collections.isEmpty {
                BaselinePicker(label: "Choose a Collection…")
                    .buttonStyle(.borderedProminent)
            }
            Button("Snapshot This Device as a Collection") {
                model.requestNewCollectionFromDevice()
            }
            .buttonStyle(.bordered)
            .disabled(!model.connection.hasDevice)
            Button("Browse Collections") { model.sidebar = .collections }
                .buttonStyle(.borderless)
        }
    }

    private var needsSnapshotState: some View {
        ContentUnavailableView {
            Label("Nothing to compare yet",
                  systemImage: "arrow.triangle.2.circlepath")
        } description: {
            Text(model.sync.readEstimateCopy)
        } actions: {
            Button("Read Device & Compare") { model.readDeviceAndCompare() }
                .buttonStyle(.borderedProminent)
                .disabled(!model.connection.hasDevice
                          || model.operations.exclusiveLongOp != nil)
            BaselinePicker(label: baselineLabel)
                .buttonStyle(.bordered)
        }
    }

    private var baselineLabel: String {
        model.sync.baseline.map { "Compare against: \($0.name)" }
            ?? "Choose a Collection…"
    }

    /// Compare running = the backup's progress, inline (same op, UX §17).
    private var comparingState: some View {
        VStack(spacing: 16) {
            if let run = model.backupRun, run.purpose == .compare {
                BackupProgressBody(run: run)
                    .padding(24)
            } else {
                ProgressView("Reading the device…")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func failedState(_ message: String) -> some View {
        ContentUnavailableView {
            Label("Compare failed", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            Button("Retry") { model.readDeviceAndCompare() }
                .buttonStyle(.borderedProminent)
                .disabled(!model.connection.hasDevice)
        }
    }

    // --------------------------------------------------------------- ready

    private var readyList: some View {
        List {
            Section {
                SyncBaselineHeader()
            }
            Section {
                SyncProvenanceHeader()
            }
            Section {
                SyncFilterBar()
            }
            if let summary = model.sync.allInSyncSummary {
                Section {
                    Label(summary, systemImage: "checkmark.circle")
                        .foregroundStyle(.green)
                        .font(.callout)
                }
            }
            Section {
                ForEach(model.sync.visibleRows, id: \.slot) { row in
                    SyncRowView(row: row)
                }
            }
        }
        .listStyle(.plain)
    }
}

// =============================================================== baseline

/// The Menu over every collection. Its label is `fixedSize`d so a narrow
/// content column truncates the surrounding text, never hyphenates a control.
struct BaselinePicker: View {
    @Environment(AppModel.self) private var model
    var label: String

    var body: some View {
        Menu {
            ForEach(model.collectionsModel.sorted, id: \.id) { coll in
                Button {
                    model.syncBaselineID = coll.id
                } label: {
                    if model.sync.baseline?.id == coll.id {
                        Label("\(coll.name) · \(coll.slots.count) slots",
                              systemImage: "checkmark")
                    } else {
                        Text("\(coll.name) · \(coll.slots.count) slots")
                    }
                }
            }
        } label: {
            Text(label)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }
}

/// "Compare against: [ Ambient Peaks ▾ ] — 32 slots · imported bank"
struct SyncBaselineHeader: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Text("Compare against")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                BaselinePicker(label: model.sync.baseline?.name ?? "Choose…")
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: 0)
            }
            if let baseline = model.sync.baseline {
                Text(subtitle(baseline))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
    }

    private func subtitle(_ coll: PresetCollection) -> String {
        let kind: String
        switch coll.provenance.kind {
        case .deviceSnapshot: kind = "device snapshot"
        case .importedBank: kind = "imported bank"
        case .manual: kind = "hand-built"
        }
        return "\(coll.slots.count) slots · \(kind)"
    }
}

// ===================================================================== header

/// "Compared against device read 12 min ago (backup …) · 3 writes since."
struct SyncProvenanceHeader: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                if let provenance = model.sync.provenance {
                    Text("Compared against \(provenance.line) · "
                         + "\(model.freshness.writesSinceBackup) writes since")
                        .font(.caption)
                        .foregroundStyle(provenance.isStale
                            ? .orange : .secondary)
                    if provenance.isStale {
                        Text("This read is over a day old — the synth may "
                             + "have changed.")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
            }
            .layoutPriority(1)
            Spacer()
            Button("Re-read") { model.readDeviceAndCompare() }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .lineLimit(1)
                // Without this the caption above steals the width and the
                // button hyphenates to "Re-" / "read".
                .fixedSize(horizontal: true, vertical: false)
                .disabled(!model.connection.hasDevice
                          || model.operations.exclusiveLongOp != nil)
        }
    }
}

// ================================================================= filter bar

/// Live-count toggles; default shows only real disagreements with the chosen
/// collection — `unlisted`, `in sync` and `empty` are opt-in (UX §17).
struct SyncFilterBar: View {
    @Environment(AppModel.self) private var model

    private let order: [SlotStatus] = [.differs, .baselineOnly, .unlisted,
                                       .inSync, .empty]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(order, id: \.self) { status in
                    // filterCount, not counts: a name-only row rides the
                    // `.differs` chip, so each chip's number equals the
                    // number of rows it actually reveals.
                    let count = model.sync.filterCount(status)
                    let isOn = model.sync.visibleStatuses.contains(status)
                    Button {
                        if isOn {
                            model.sync.visibleStatuses.remove(status)
                        } else {
                            model.sync.visibleStatuses.insert(status)
                        }
                    } label: {
                        HStack(spacing: 4) {
                            SyncBadge(status: status)
                            Text("\(count)")
                                .font(.caption.monospacedDigit())
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(isOn ? Color.accentColor.opacity(0.12)
                                         : Color.clear,
                                    in: Capsule())
                        .overlay(Capsule().stroke(
                            isOn ? Color.accentColor : Color.secondary
                                .opacity(0.3), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

// ======================================================================== row

/// One slot, one line the eye can actually read.
///
/// The old row was a flat HStack of five flexible participants — slot number,
/// a two-line label, an elastic Spacer, the status chip and a bordered
/// "Resolve…" menu — with no layout priority anywhere, so SwiftUI split the
/// shortfall across all of them: names truncated to `device "…` inside their
/// own prefix and the button hyphenated to `Re-` / `solve…`. Three fixes:
/// the label VStack absorbs the slack (no Spacer) and is served FIRST
/// (`layoutPriority`), the strings are the bare names instead of
/// `device "A" ≠ library "B"`, and the per-row control moves to the context
/// menu / swipe actions it already duplicated (the row navigates to
/// SyncSlotDetailView on tap, which offers the same actions with full labels).
struct SyncRowView: View {
    @Environment(AppModel.self) private var model
    let row: SlotDiff

    private var slot: SlotID { SlotID(row.slot) }

    var body: some View {
        HStack(spacing: 10) {
            SlotNumberLabel(slot: slot)
            VStack(alignment: .leading, spacing: 2) {
                Text(nameLine)
                    .font(.body)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let detailLine {
                    Text(detailLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            // Replaces Spacer(): the label column IS the slack absorber, and
            // it is served before the chip instead of competing with it.
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)
            SyncBadge(status: row.status)
        }
        .frame(minHeight: 52)
        .contentShape(Rectangle())
        .onTapGesture { model.detail = .syncSlot(slot) }
        .contextMenu { menuActions }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) { swipeActions }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(accessibilityText)
    }

    /// The bare preset name — no `device "` / `library "` chrome to eat the
    /// glyph budget before the payload is reached.
    private var nameLine: String {
        switch row.status {
        case .baselineOnly:                 // the device side is an Init blob
            return row.baseline?.name ?? "—"
        case .unlisted, .differs, .inSync, .empty:
            return row.device?.name ?? row.baseline?.name ?? "—"
        }
    }

    /// A second line only when it says something the badge does not.
    private var detailLine: String? {
        switch row.status {
        case .unlisted:
            guard let sha = row.device?.sha256 else { return nil }
            return model.libraryModel.entriesSharing(sha256: sha).isEmpty
                ? "not in this collection · not in your library"
                : nil                       // badge already reads "unlisted"
        case .baselineOnly:
            return "device slot empty"      // which preset is on the name line
        case .differs:
            guard let name = row.baseline?.name else { return nil }
            return name == row.device?.name
                ? "same name, different contents"
                // Payload FIRST: the collection's name is already on screen
                // twice (SyncBaselineHeader), so leading with it spends the
                // narrow content column's glyphs on the one word the reader
                // does not need and truncates the one they do.
                : "collection has \"\(name)\""
        case .inSync:
            guard row.nameDiffers, let name = row.baseline?.name else { return nil }
            return "collection calls it \"\(name)\" · names differ only"
        case .empty:
            if let judgment = model.slots.record(slot)?.judgment,
               case .expendable(let evidence) = judgment {
                return evidence
            }
            return nil
        }
    }

    /// VoiceOver keeps the sentence the visual row no longer spells out.
    private var accessibilityText: String {
        var parts = ["slot \(slot.display)", nameLine, row.status.rawValue]
        if let detailLine { parts.append(detailLine) }
        return parts.joined(separator: ", ")
    }

    private var deviceReady: Bool {
        model.connection.hasDevice && model.operations.exclusiveLongOp == nil
    }

    /// A name-only row carries `.inSync` (the diff is content-based) but
    /// `planApply` writes it, so it gets the same two resolutions `.differs`
    /// does — minus "Save Device Preset to Library", whose exact bytes the
    /// baseline already holds.
    private var isNameOnly: Bool { SyncModel.isNameOnly(row) }

    /// Full labels — the context menu has the width for them.
    @ViewBuilder
    private var menuActions: some View {
        switch row.status {
        case .unlisted:
            Button { model.syncSaveRowToLibrary(row) } label: {
                Label("Save to Library", systemImage: "square.and.arrow.down")
            }
        case .empty:
            // `.empty` means the device slot is expendable — an Init or a
            // duplicate blob. Cataloguing those is what the detail view and
            // `saveUnlistedToLibrary` both already refuse to do.
            EmptyView()
        case .baselineOnly:
            Button { model.syncSendBaselineRow(row) } label: {
                Label("Send to Device", systemImage: "square.and.arrow.up")
            }
            .disabled(!deviceReady)
        case .differs:
            Button { model.syncSendBaselineRow(row) } label: {
                Label("Send Collection's Preset", systemImage: "arrow.up")
            }
            .disabled(!deviceReady)
            Button { model.syncAdoptRowIntoBaseline(row) } label: {
                Label("Update Collection from Device", systemImage: "arrow.down")
            }
            Button { model.syncSaveRowToLibrary(row) } label: {
                Label("Save Device Preset to Library",
                      systemImage: "square.and.arrow.down")
            }
        case .inSync:
            if isNameOnly {
                Button { model.syncSendBaselineRow(row) } label: {
                    Label("Send Collection's Name", systemImage: "arrow.up")
                }
                .disabled(!deviceReady)
                Button { model.syncAdoptRowIntoBaseline(row) } label: {
                    Label("Update Collection from Device",
                          systemImage: "arrow.down")
                }
            }
        }
        Divider()
        Button { model.detail = .syncSlot(slot) } label: {
            Label("Show Details", systemImage: "info.circle")
        }
    }

    /// Short labels; `Menu` is not permitted inside `.swipeActions`, so
    /// `changed` becomes two buttons rather than one "Resolve…" menu. The
    /// device-write half keeps its connection gate.
    @ViewBuilder
    private var swipeActions: some View {
        switch row.status {
        case .unlisted:
            Button { model.syncSaveRowToLibrary(row) } label: {
                Label("Save", systemImage: "square.and.arrow.down")
            }
            .tint(.blue)
        case .empty:
            EmptyView()                       // expendable: nothing to catalogue
        case .baselineOnly:
            Button { model.syncSendBaselineRow(row) } label: {
                Label("Send", systemImage: "square.and.arrow.up")
            }
            .tint(.orange)
            .disabled(!deviceReady)
        case .differs:
            Button { model.syncSendBaselineRow(row) } label: {
                Label("Send", systemImage: "arrow.up")
            }
            .tint(.purple)
            .disabled(!deviceReady)
            Button { model.syncAdoptRowIntoBaseline(row) } label: {
                Label("Adopt", systemImage: "arrow.down")
            }
            .tint(.indigo)
        case .inSync:
            if isNameOnly {
                Button { model.syncSendBaselineRow(row) } label: {
                    Label("Send", systemImage: "arrow.up")
                }
                .tint(.purple)
                .disabled(!deviceReady)
                Button { model.syncAdoptRowIntoBaseline(row) } label: {
                    Label("Adopt", systemImage: "arrow.down")
                }
                .tint(.indigo)
            }
        }
    }
}

#Preview("Sync") {
    PreviewHost { _ in
        NavigationStack { SyncListView() }
    }
}
