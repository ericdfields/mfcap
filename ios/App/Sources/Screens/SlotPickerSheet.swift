// SlotPickerSheet.swift — the tap-parity slot picker (UX §8.1).
//
// The 512-row list in a sheet: empty-judged slots grouped FIRST, the core's
// pickScratchSlot suggestion labeled ("Suggested: slot 509 — empty"), search
// over cached names. Serves both Send to Slot… (device write, §9 guarded
// downstream) and the library's local Assign Slot….

import SwiftUI
import FreakCore

struct SlotPickerSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let request: SlotPickerRequest

    @State private var searchText = ""

    private var suggestion: SlotID? { model.slots.scratchSuggestion() }

    var body: some View {
        NavigationStack {
            List {
                if let suggestion {
                    Section {
                        pickRow(suggestion,
                                labelPrefix: "Suggested: ",
                                highlight: true)
                    }
                } else if model.slots.hasJudgments {
                    Section {
                        // The no-scratch-slot path: the human decides (§14.4).
                        Text("No slot is judged empty — every choice "
                             + "replaces a real preset.")
                            .font(.callout)
                            .foregroundStyle(.orange)
                    }
                }
                Section("Empty-judged slots") {
                    ForEach(groupedSlots.empty) { slot in
                        pickRow(slot)
                    }
                    if groupedSlots.empty.isEmpty {
                        Text(model.slots.hasJudgments
                             ? "None." : "Content not read yet — judgments "
                             + "appear after a full read (Sync → Read "
                             + "Device & Compare).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Section("All slots") {
                    ForEach(groupedSlots.rest) { slot in
                        pickRow(slot)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .searchable(text: $searchText, prompt: "Name or slot number")
            .navigationTitle(request.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.large])
    }

    private var groupedSlots: (empty: [SlotID], rest: [SlotID]) {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        let lowered = query.lowercased()
        var empty: [SlotID] = []
        var rest: [SlotID] = []
        for row in model.slots.rows {
            if !query.isEmpty {
                let nameHit = row.name?.lowercased().contains(lowered) ?? false
                let numberHit = String(row.slot.display).contains(query)
                guard nameHit || numberHit else { continue }
            }
            if row.judgment.isExpendable {
                empty.append(row.slot)
            } else {
                rest.append(row.slot)
            }
        }
        return (empty, rest)
    }

    private func pickRow(_ slot: SlotID, labelPrefix: String = "",
                         highlight: Bool = false) -> some View {
        let row = model.slots.record(slot)
        return Button {
            pick(slot)
        } label: {
            HStack(spacing: 12) {
                SlotNumberLabel(slot: slot)
                VStack(alignment: .leading, spacing: 1) {
                    Text(labelPrefix + (row?.displayName ?? ""))
                        .font(.callout)
                        .foregroundStyle(row?.judgment.isExpendable == true
                            ? Color.secondary : Color.primary)
                    if case .expendable(let evidence)? = row?.judgment {
                        Text("empty — \(evidence)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if let judgment = row?.judgment {
                    JudgmentDot(judgment: judgment)
                }
            }
        }
        .listRowBackground(highlight
            ? Color.accentColor.opacity(0.08) : nil)
    }

    private func pick(_ slot: SlotID) {
        dismiss()
        switch request.purpose {
        case .send(let transfers):
            if transfers.count == 1, let only = transfers.first {
                model.requestSend(only, to: slot)
            } else {
                model.requestSend(transfers, startingAt: slot)
            }
        case .assign(let entryID):
            assign(entryID, to: slot)
        }
    }

    /// Local assign — §6 slot-claim rule surfaced when another entry claims
    /// the slot; the device is never touched.
    private func assign(_ entryID: String, to slot: SlotID) {
        let displaced = model.libraryModel.entryClaiming(slot: slot)
        Task { @MainActor in
            try? await model.libraryModel.assignSlot(id: entryID, slot: slot)
            if let displaced, displaced.id != entryID {
                model.toasts.show("This replaces '\(displaced.name)' as the "
                    + "preset assigned to slot \(slot.display). Library only "
                    + "— the device is not touched.")
            } else {
                model.toasts.show("Assigned to slot \(slot.display). Library "
                    + "only — the device is not touched.")
            }
        }
    }
}

#Preview("Slot picker") {
    PreviewHost { model in
        SlotPickerSheet(request: SlotPickerRequest(
            purpose: .send(transfers: [
                PresetTransfer(source: .deviceSlot(SlotID(0)),
                               displayName: "Patch 000")]),
            title: "Send 'Patch 000' to…"))
            .environment(model)
    }
}
