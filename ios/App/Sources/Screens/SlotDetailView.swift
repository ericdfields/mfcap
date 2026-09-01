// SlotDetailView.swift — device-slot detail (UX §7).
//
// Fields top to bottom: editable name, slot line, judgment line (evidence IS
// the copy), category byte (display only, honest raw hex until the mapping
// is hardware-verified), sha (or the explicit ~1 s Read Slot CTA — the lazy
// blob trigger), Advanced meta disclosure, cross-references, slot history
// with its mandatory caveat header.

import SwiftUI
import UIKit
import FreakCore

struct SlotDetailView: View {
    @Environment(AppModel.self) private var model
    let slot: SlotID

    @State private var renaming = false
    @State private var shaExpanded = false

    private var row: SlotCacheRow? { model.slots.record(slot) }

    var body: some View {
        List {
            headerSection
            identitySection
            contentSection
            advancedSection
            crossReferenceSection
            actionsSection
            historySection
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Slot \(slot.display)")
    }

    // ------------------------------------------------------------ header

    private var headerSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                if renaming, let row {
                    RenameField(original: row.name ?? "") { newName in
                        renaming = false
                        model.renameSlot(slot, to: newName)
                    } cancel: {
                        renaming = false
                    }
                    .font(.title2)
                } else {
                    Button {
                        guard model.connection.hasDevice,
                              row?.hasKnownName == true else { return }
                        renaming = true
                    } label: {
                        HStack {
                            Text(row?.displayName ?? "")
                                .font(.title2.weight(.semibold))
                                .foregroundStyle(row?.nameFailed == true
                                    ? .secondary : .primary)
                            Image(systemName: "pencil")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
                HStack(spacing: 8) {
                    if row?.torn == true { SlotFlagBadge(flag: .torn) }
                    if row?.verifyFailed == true {
                        SlotFlagBadge(flag: .verifyFailed)
                    }
                    if row?.busy == true { ProgressView().controlSize(.small) }
                }
            }
            if row?.nameFailed == true {
                Button("Retry Name Read") { model.retryName(slot) }
                    .disabled(!model.connection.hasDevice)
            }
        }
    }

    // ---------------------------------------------------------- identity

    private var identitySection: some View {
        Section {
            LabeledContent("Slot") {
                Text("Slot \(slot.display) · \(SlotID.bankLabel(slot.bank))")
            }
            if let row {
                LabeledContent("Judgment") {
                    HStack(spacing: 6) {
                        JudgmentDot(judgment: row.judgment)
                        Text(row.judgmentCopy)
                    }
                }
            }
            if let entry = model.libraryModel.entryClaiming(slot: slot) {
                LabeledContent("Library claim") {
                    Button(entry.name) {
                        model.detail = .libraryEntry(entry.id)
                    }
                }
            }
        }
    }

    // ----------------------------------------------------------- content

    @ViewBuilder
    private var contentSection: some View {
        Section("Content") {
            if let meta = row?.meta {
                CategoryByteRow(meta: meta)
            }
            if let sha = row?.sha256 {
                ShaRow(sha256: sha, expanded: $shaExpanded)
            } else {
                // The lazy-blob trigger (UX §7.5): explicit, priced, patches
                // the browser row's judgment too.
                Button {
                    _ = model.readSlot(slot)
                } label: {
                    Label("Read Slot (about 1 second)",
                          systemImage: "waveform.badge.magnifyingglass")
                }
                .disabled(!model.connection.hasDevice
                          || model.operations.exclusiveLongOp != nil)
                if let busy = model.operations.exclusiveLongOp?.busyLine {
                    Text(busy).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    // ---------------------------------------------------------- advanced

    private var advancedSection: some View {
        Section {
            DisclosureGroup("Advanced") {
                LabeledContent("Meta") {
                    Text(Format.metaHex(row?.meta))
                        .font(.caption.monospaced())
                }
                if let meta = row?.meta, meta.count >= 9 {
                    LabeledContent("Attribute byte") {
                        Text(Format.hexByte(meta[meta.index(meta.startIndex,
                                                            offsetBy: 8)]))
                            .font(.caption.monospaced())
                    }
                }
                if let confirmed = row?.lastConfirmed {
                    LabeledContent("Last confirmed") {
                        Text(Format.relativeAge(confirmed))
                    }
                }
                LabeledContent("Addressing") {
                    Text(slot.diagnosticLabel)   // the one both-numbers line
                        .font(.caption.monospaced())
                }
            }
        }
    }

    // -------------------------------------------------- cross references

    private var crossReferenceSection: some View {
        Section("Backups covering this slot") {
            let coverage = model.backups.coverage(of: slot,
                                                  sha256: row?.sha256)
            if coverage.isEmpty {
                Text("Not covered by any backup yet.")
                    .foregroundStyle(.secondary)
            }
            ForEach(coverage, id: \.summary.id) { entry in
                HStack {
                    Button(entry.summary.folderName) {
                        model.detail = .backup(entry.summary.folderName)
                    }
                    Spacer()
                    switch entry.matches {
                    case true?:
                        Label("matches", systemImage: "checkmark.circle")
                            .font(.caption).foregroundStyle(.green)
                    case false?:
                        Label("differs", systemImage: "circle.slash")
                            .font(.caption).foregroundStyle(.orange)
                    case nil:
                        Text("unread").font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // ----------------------------------------------------------- actions

    private var actionsSection: some View {
        Section {
            let deviceReady = model.connection.hasDevice
                && model.operations.exclusiveLongOp == nil
            Button {
                model.saveToLibrary(slot, tags: [])
            } label: {
                Label("Save to Library", systemImage: "books.vertical")
            }
            Button {
                model.requestSlotPickerForCopy(of: slot)
            } label: {
                Label("Send to Another Slot…",
                      systemImage: "arrow.right.square")
            }
            .disabled(!deviceReady)
            Menu {
                ForEach(model.libraryModel.entries) { entry in
                    Button(entry.name) {
                        model.requestSend(
                            PresetTransfer(source: .library(entryID: entry.id),
                                           displayName: entry.name),
                            to: slot)
                    }
                }
            } label: {
                Label("Overwrite from Library…",
                      systemImage: "square.and.arrow.down")
            }
            .disabled(!deviceReady || model.libraryModel.entries.isEmpty)
            Button {
                model.requestRestoreSlotFromBackup(slot)
            } label: {
                Label("Restore this slot from backup…",
                      systemImage: "arrow.uturn.backward.circle")
            }
            .disabled(!deviceReady
                      || model.backups.coverage(of: slot, sha256: nil).isEmpty)
        }
    }

    // ----------------------------------------------------------- history

    private var historySection: some View {
        Section {
            SlotHistoryList(slot: slot)
        } header: {
            Text("Slot history")
        } footer: {
            // Mandatory caveat copy (UX §15).
            Text("History of this app's activity — changes made on the synth "
                 + "itself appear only as differences at the next read.")
        }
    }
}

// ------------------------------------------------------------- components

/// Category byte (meta byte 7 = long-0x52 payload[10]); display only (§7.4).
struct CategoryByteRow: View {
    let meta: Data
    @State private var showInfo = false

    private var byte: UInt8? {
        guard meta.count >= 8 else { return nil }
        return meta[meta.index(meta.startIndex, offsetBy: 7)]
    }

    var body: some View {
        LabeledContent("Category") {
            HStack(spacing: 6) {
                if let byte {
                    if let label = CategoryByte.label(for: byte) {
                        Text("\(label) (\(Format.hexByte(byte)))")
                    } else {
                        Text(Format.hexByte(byte))
                            .font(.body.monospaced())
                        Button {
                            showInfo = true
                        } label: {
                            Image(systemName: "info.circle")
                        }
                        .popover(isPresented: $showInfo) {
                            Text(CategoryByte.infoCopy)
                                .font(.callout)
                                .padding(16)
                                .frame(idealWidth: 300)
                                .presentationCompactAdaptation(.popover)
                        }
                    }
                } else {
                    Text("—")
                }
            }
        }
    }
}

/// SHA-256: first 12 chars, monospaced; tap to expand / copy (§7.5).
struct ShaRow: View {
    let sha256: String
    @Binding var expanded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent("SHA-256") {
                Button {
                    expanded.toggle()
                } label: {
                    Text(expanded ? sha256 : Format.shaPrefix(sha256) + "…")
                        .font(.caption.monospaced())
                        .multilineTextAlignment(.trailing)
                }
            }
            if expanded {
                Button {
                    UIPasteboard.general.string = sha256
                } label: {
                    Label("Copy full hash", systemImage: "doc.on.doc")
                        .font(.caption)
                }
            }
        }
    }
}

/// Reverse-chronological journal excerpt, capped at 20 + "Show all" (§7.8).
struct SlotHistoryList: View {
    @Environment(AppModel.self) private var model
    let slot: SlotID
    @State private var showAll = false

    var body: some View {
        let events = model.history.events(slot: slot,
                                          identity: model.deviceIdentity)
        if events.isEmpty {
            Text("No activity recorded for this slot yet.")
                .foregroundStyle(.secondary)
        } else {
            ForEach(showAll ? events : Array(events.prefix(20))) { event in
                HStack(spacing: 10) {
                    Image(systemName: event.icon)
                        .foregroundStyle(.secondary)
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(event.summary).font(.callout)
                        Text(Format.relativeAge(event.date))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if events.count > 20 && !showAll {
                Button("Show all \(events.count) events") { showAll = true }
                    .font(.callout)
            }
        }
    }
}

#Preview("Slot detail") {
    PreviewHost { _ in
        NavigationStack { SlotDetailView(slot: SlotID(412)) }
    }
}
