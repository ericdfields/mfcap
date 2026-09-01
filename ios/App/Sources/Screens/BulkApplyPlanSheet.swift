// BulkApplyPlanSheet.swift — the sync Apply… sheet (UX §17 bulk apply).
//
// Sections: imports (pre-checked), sends (pre-checked, each row shows its
// victim + expendability), conflicts — NEVER pre-resolved: each `changed`
// row requires an explicit Push / Pull / Skip choice, default Skip. Footer:
// totals, time estimate, backup freshness, confirm labeled with the count.

import SwiftUI
import FreakCore

struct BulkApplyPlanSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let plan: BulkApplyPlan

    @State private var importsOn = Set<Int>()
    @State private var sendsOn = Set<Int>()
    @State private var conflictChoices: [Int: BulkApplyPlan.ConflictChoice] = [:]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if model.connection.isPractice {
                    PracticeBanner()
                }
                List {
                    importSection
                    sendSection
                    conflictSection
                }
                .listStyle(.insetGrouped)
                Divider()
                footer
            }
            .navigationTitle("Apply sync changes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .onAppear {
            importsOn = Set(plan.imports.map(\.slot))     // pre-checked
            sendsOn = Set(plan.sends.map(\.slot))         // pre-checked
            for row in plan.conflicts {
                conflictChoices[row.slot] = .skip         // default Skip
            }
        }
        .presentationDetents([.large])
    }

    // ------------------------------------------------------------- sections

    @ViewBuilder
    private var importSection: some View {
        if !plan.imports.isEmpty {
            Section("Import \(plan.imports.count) to library (instant)") {
                ForEach(plan.imports, id: \.slot) { row in
                    toggleRow(slot: SlotID(row.slot),
                              label: "\"\(row.device?.name ?? "")\"",
                              sub: "not in library",
                              set: $importsOn)
                }
            }
        }
    }

    @ViewBuilder
    private var sendSection: some View {
        if !plan.sends.isEmpty {
            Section("Send \(plan.sends.count) to device (verified writes)") {
                ForEach(plan.sends, id: \.slot) { row in
                    let slot = SlotID(row.slot)
                    toggleRow(slot: slot,
                              label: "\"\(row.library?.name ?? "")\"",
                              sub: victimEvidence(slot),
                              set: $sendsOn)
                }
            }
        }
    }

    @ViewBuilder
    private var conflictSection: some View {
        if !plan.conflicts.isEmpty {
            Section("Conflicts (\(plan.conflicts.count)) — choose per row") {
                ForEach(plan.conflicts, id: \.slot) { row in
                    let slot = SlotID(row.slot)
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            SlotNumberLabel(slot: slot)
                            Text("device \"\(row.device?.name ?? "")\" ≠ "
                                 + "library \"\(row.library?.name ?? "")\"")
                                .font(.callout)
                                .lineLimit(1)
                        }
                        Picker("Resolution", selection: Binding(
                            get: { conflictChoices[row.slot] ?? .skip },
                            set: { conflictChoices[row.slot] = $0 })) {
                            ForEach(BulkApplyPlan.ConflictChoice.allCases) {
                                Text($0.title).tag($0)
                            }
                        }
                        .pickerStyle(.segmented)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private func toggleRow(slot: SlotID, label: String, sub: String,
                           set: Binding<Set<Int>>) -> some View {
        HStack(spacing: 12) {
            Image(systemName: set.wrappedValue.contains(slot.raw)
                  ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(.tint)
            SlotNumberLabel(slot: slot)
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.callout).lineLimit(1)
                Text(sub).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if set.wrappedValue.contains(slot.raw) {
                set.wrappedValue.remove(slot.raw)
            } else {
                set.wrappedValue.insert(slot.raw)
            }
        }
    }

    private func victimEvidence(_ slot: SlotID) -> String {
        if let judgment = model.slots.record(slot)?.judgment,
           case .expendable(let evidence) = judgment {
            return "replaces empty slot (\(evidence))"
        }
        return "replaces slot \(slot.display)"
    }

    // --------------------------------------------------------------- footer

    private var writeCount: Int {
        sendsOn.count + conflictChoices.values.filter { $0 == .push }.count
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(importsOn.count + conflictChoices.values.filter { $0 == .pull }.count) imports · "
                 + "\(writeCount) writes ≈ \(writeCount) s")
                .font(.callout)
            Text(model.freshness.dialogLine)
                .font(.caption)
                .foregroundStyle(.secondary)
            if model.connection.isPractice {
                Text("Practice device — no hardware will change.")
                    .font(.caption)
                    .foregroundStyle(.purple)
            }
            HStack {
                Spacer()
                Button(writeCount > 0
                       ? "Write \(writeCount) Slot\(writeCount == 1 ? "" : "s") to Device"
                       : "Apply Imports Only") {
                    confirm()
                }
                .buttonStyle(.borderedProminent)
                .disabled(importsOn.isEmpty && writeCount == 0
                          && !conflictChoices.values.contains(.pull))
            }
        }
        .padding(16)
    }

    private func confirm() {
        let imports = plan.imports.filter { importsOn.contains($0.slot) }
        let sends = plan.sends.filter { sendsOn.contains($0.slot) }
        dismiss()
        model.runBulkApply(imports: imports, sends: sends,
                           conflicts: conflictChoices)
    }
}

#Preview("Bulk apply") {
    PreviewHost { model in
        BulkApplyPlanSheet(plan: BulkApplyPlan(imports: [], sends: [],
                                               conflicts: []))
            .environment(model)
    }
}
