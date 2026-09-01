// SlotRowView.swift — one browser row (UX §5 row anatomy, ≥ 52 pt).
//
// [413] Bass Prophet                     ● ↔ ⟳
// Judgment dot + optional sync badge + activity glyph; dimming only ever by
// content judgment. Drag source, drop target (drop = intent, §9 confirmation
// anchored HERE for expendable victims), context menu + both-edge swipe
// actions with tap parity (UX §13.5), inline rename.

import SwiftUI
import FreakCore

struct SlotRowView: View {
    @Environment(AppModel.self) private var model
    let slot: SlotID
    @Binding var renamingSlot: SlotID?

    @State private var dropTargeted = false

    private var row: SlotCacheRow? { model.slots.record(slot) }

    var body: some View {
        content
            .frame(minHeight: 52)
            .contentShape(Rectangle())
            .onTapGesture { model.detail = .slot(slot) }
            .listRowBackground(dropTargeted
                ? Color.accentColor.opacity(0.15) : nil)
            .overlay {
                if dropTargeted {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.accentColor, lineWidth: 2)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                // §8.1 live consequence caption while a drag hovers. SwiftUI
                // exposes no payload during hover, so the caption states the
                // victim half ("replaces …"); the incoming name appears in
                // the §9 confirmation the drop opens.
                if dropTargeted {
                    Text(dropConsequence)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.regularMaterial, in: Capsule())
                        .padding(4)
                        .allowsHitTesting(false)
                }
            }
            .draggable(dragPayload)
            .dropDestination(for: PresetTransfer.self) { items, _ in
                guard model.connection.hasDevice else { return false }
                if items.count == 1, let item = items.first {
                    model.requestSend(item, to: slot, anchor: slot)
                } else if !items.isEmpty {
                    model.requestSend(items, startingAt: slot, anchor: slot)
                }
                return true
            } isTargeted: { targeted in
                dropTargeted = targeted
            }
            .contextMenu { menuItems }
            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                Button {
                    model.saveToLibrary(slot, tags: [])
                } label: {
                    Label("Save to Library", systemImage: "books.vertical")
                }
                .tint(.blue)
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button {
                    renamingSlot = slot
                } label: {
                    Label("Rename", systemImage: "pencil")
                }
                Button {
                    model.requestSlotPickerForCopy(of: slot)
                } label: {
                    Label("Send to Another Slot…",
                          systemImage: "arrow.right.square")
                }
                .tint(.indigo)
            }
            // §9 popover severity anchors at the touched row (UX §13.2).
            .popover(item: popoverConfirmation) { pending in
                OverwriteConfirmationPopover(pending: pending)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilityText)
    }

    // -------------------------------------------------------------- content

    @ViewBuilder
    private var content: some View {
        HStack(spacing: 12) {
            SlotNumberLabel(slot: slot)
            if renamingSlot == slot, let row {
                RenameField(original: row.name ?? "") { newName in
                    renamingSlot = nil
                    model.renameSlot(slot, to: newName)
                } cancel: {
                    renamingSlot = nil
                }
            } else {
                nameLabel
            }
            Spacer(minLength: 8)
            badges
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var nameLabel: some View {
        if let row {
            if row.name == nil && !row.nameFailed {
                // Names pass shimmer: redacted placeholder, not a wait screen.
                Text("Preset name")
                    .redacted(reason: .placeholder)
                    .opacity(0.6)
            } else {
                HStack(spacing: 6) {
                    Text(row.displayName)
                        .font(.body)
                        .lineLimit(1)
                        .foregroundStyle(row.judgment.isExpendable
                            ? Color.secondary : Color.primary)
                    if row.judgment.isExpendable { EmptyChip() }
                }
            }
        }
    }

    @ViewBuilder
    private var badges: some View {
        if let row {
            if row.torn { SlotFlagBadge(flag: .torn) }
            if row.verifyFailed { SlotFlagBadge(flag: .verifyFailed) }
            if let status = model.slots.syncBadges[slot.raw] {
                SyncBadge(status: status)
            }
            if row.busy || activeOpTargetsRow {
                ProgressView().controlSize(.small)
            }
            JudgmentDot(judgment: row.judgment)
        }
    }

    private var activeOpTargetsRow: Bool {
        model.operations.active.contains { $0.slot == slot && $0.isActive }
    }

    // ---------------------------------------------------------- context menu

    @ViewBuilder
    private var menuItems: some View {
        let deviceReady = model.connection.hasDevice
            && model.operations.exclusiveLongOp == nil
        if let busyLine = model.operations.exclusiveLongOp?.busyLine {
            Text(busyLine)   // reason inline while device is exclusive (UX §5)
        }
        Button {
            model.saveToLibrary(slot, tags: [])
        } label: {
            Label("Save to Library", systemImage: "books.vertical")
        }
        Button {
            model.requestSlotPickerForCopy(of: slot)
        } label: {
            // Outbound copy — matches SlotDetailView's label for the same
            // action ("Here" would wrongly imply the paste direction).
            Label("Send to Another Slot…", systemImage: "arrow.right.square")
        }
        .disabled(!deviceReady)
        Button {
            renamingSlot = slot
        } label: {
            Label("Rename", systemImage: "pencil")
        }
        .disabled(!deviceReady)
        Button {
            _ = model.readSlot(slot)
        } label: {
            Label("Read Now (~1 s)", systemImage: "waveform.badge.magnifyingglass")
        }
        .disabled(!deviceReady)
        if row?.nameFailed == true {
            Button {
                model.retryName(slot)
            } label: {
                Label("Retry Name Read", systemImage: "arrow.clockwise")
            }
            .disabled(!deviceReady)
        }
        Button {
            model.sidebar = .sync
            model.detail = .syncSlot(slot)
        } label: {
            Label("Show in Sync", systemImage: "arrow.triangle.2.circlepath")
        }
        Divider()
        Button {
            model.copySlot(slot)
        } label: {
            Label("Copy", systemImage: "doc.on.doc")
        }
        Button {
            model.pasteInto(slot)
        } label: {
            Label("Paste (Send Here)", systemImage: "doc.on.clipboard")
        }
        .disabled(model.copyBuffer == nil || !deviceReady)
    }

    // ------------------------------------------------------------- plumbing

    private var dropConsequence: String {
        switch model.victimFacts(slot) {
        case .empty(let evidence):
            return "replaces empty slot (\(evidence))"
        case .named(let name, _):
            return "replaces \"\(name)\""
        case .unknown(let known):
            if let known { return "replaces \"\(known)\" — not read yet" }
            return "contents unknown"
        }
    }

    private var dragPayload: PresetTransfer {
        PresetTransfer(source: .deviceSlot(slot),
                       displayName: row?.name ?? "Slot \(slot.display)")
    }

    private var popoverConfirmation: Binding<PendingConfirmation?> {
        Binding(
            get: {
                // Only confirmations anchored at THIS row render here —
                // unanchored popover-severity confirmations (Library/Sync
                // sends) fall back to RootView's dialog, so they can never
                // silently vanish when no row is on screen.
                guard let pending = model.pendingConfirmation,
                      case .popover = pending.plan.severity,
                      pending.anchor == slot
                else { return nil }
                return pending
            },
            set: { if $0 == nil { model.pendingConfirmation = nil } })
    }

    private var accessibilityText: String {
        guard let row else { return "slot \(slot.display)" }
        var parts = ["slot \(slot.display)"]
        if row.nameFailed {
            parts.append("name read failed")
        } else if let name = row.name {
            parts.append(name)
        }
        switch row.judgment {
        case .expendable(let evidence): parts.append("empty — \(evidence)")
        case .unjudged: parts.append("content not read yet")
        case .unknown: break
        case .real: break
        }
        if let status = model.slots.syncBadges[slot.raw] {
            parts.append("sync \(status.rawValue)")
        }
        return parts.joined(separator: ", ")
    }
}
