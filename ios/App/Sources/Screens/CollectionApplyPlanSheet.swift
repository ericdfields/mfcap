// CollectionApplyPlanSheet.swift — the Apply/Switch pre-flight (UX addendum
// §27), modeled on RestorePlanSheet. The mandatory summary line ("changes N
// of 512 slots · ~M s") comes straight off the core ApplyPlan; each changed
// row previews its victim through the same §9 vocabulary; unresolvable rows
// are pre-disabled with the core's sentence and excluded from the count.
// Confirm dismisses and runs the verified switch; progress + cancel ride the
// global status bar exactly like every other batch write.

import SwiftUI
import FreakCore

struct CollectionApplyPlanSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let plan: CollectionApplyPlan

    @State private var finalAlert = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if plan.isPractice { PracticeBanner() }
                summary
                Divider()
                rows
                Divider()
                footer
            }
            .navigationTitle("Switch to \(plan.collectionName)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .alert("This overwrites every slot the collection defines — "
               + "\(plan.writableCount) slots.", isPresented: $finalAlert) {
            Button("Switch — Write \(plan.writableCount) Slots",
                   role: .destructive) { confirm() }
            Button("Cancel", role: .cancel) {}
        }
        .presentationDetents([.large])
    }

    // ----------------------------------------------------------- summary

    private var summary: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(plan.summaryLine).font(.callout.weight(.medium))
            if !plan.unresolvableSlots.isEmpty {
                Text("\(plan.unresolvableSlots.count) slot"
                     + "\(plan.unresolvableSlots.count == 1 ? "" : "s")"
                     + " can't be written — their bytes aren't on disk. "
                     + "Re-import the bank or re-snapshot.")
                    .font(.caption).foregroundStyle(.orange)
            }
            Text("Slots the collection doesn't define are left as they are. "
                 + "Verification adds a read-back per slot.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
    }

    // -------------------------------------------------------------- rows

    private var rows: some View {
        List {
            if plan.overwrite.items.isEmpty {
                Text("Already in sync — the device already matches this "
                     + "collection.")
                    .foregroundStyle(.secondary)
            }
            ForEach(plan.overwrite.items) { item in
                HStack(spacing: 12) {
                    SlotNumberLabel(slot: item.target)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("← \"\(item.incomingName)\" (collection)")
                            .font(.callout)
                        if let reason = item.disabledReason {
                            Text(reason).font(.caption).foregroundStyle(.orange)
                        } else {
                            Text(victimLine(item)).font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                }
                .opacity(item.disabledReason == nil ? 1 : 0.5)
            }
        }
        .listStyle(.plain)
    }

    private func victimLine(_ item: OverwritePlan.Item) -> String {
        switch item.victim {
        case .named(let name, let recoverable):
            var out = "replaces \"\(name)\" (on device"
            switch recoverable {
            case .library: out += ", in library"
            case .backup: out += ", in a backup"
            case .none: out += ", NOT recoverable"
            }
            return out + ")"
        case .empty(let evidence):
            return "replaces empty slot (\(evidence))"
        case .unknown:
            return "current contents unknown"
        }
    }

    // ------------------------------------------------------------ footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(plan.overwrite.freshnessLine)
                .font(.caption).foregroundStyle(.secondary)
            if plan.isPractice {
                Text("Practice device — no hardware will change.")
                    .font(.caption).foregroundStyle(.purple)
            }
            HStack {
                Spacer()
                Button(plan.overwrite.confirmLabel) {
                    if plan.writableCount >= plan.plan.totalSlots {
                        finalAlert = true
                    } else {
                        confirm()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(plan.writableCount == 0
                          || !model.connection.hasDevice)
            }
        }
        .padding(16)
    }

    private func confirm() {
        dismiss()
        model.executeCollectionApply(plan)
    }
}
