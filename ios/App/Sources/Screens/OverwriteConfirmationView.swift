// OverwriteConfirmationView.swift — the one §9 confirmation component.
//
// Every device-write confirmation renders from an OverwritePlan through this
// file, so the guard rails cannot drift per screen: victim previewed always,
// recoverability stated, backup-freshness footer, confirm buttons that state
// the action and count, Read First for unjudged victims, Save a Copy First
// when unrecoverable, and the practice footer on simulated devices.

import SwiftUI

/// The full dialog (occupied or unjudged single target — §9.5 "dialog").
struct OverwriteConfirmationView: View {
    @Environment(AppModel.self) private var model
    let pending: PendingConfirmation

    private var plan: OverwritePlan { pending.plan }
    private var item: OverwritePlan.Item? { plan.items.first }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(plan.dialogTitle)
                .font(.title3.weight(.semibold))

            if let item {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Incoming: '\(item.incomingName)'",
                          systemImage: "arrow.down.doc")
                    victimSection(item)
                }
                .font(.callout)
            }

            Spacer(minLength: 0)

            footers

            // §13.2: confirm/cancel bottom-trailing, near the thumb.
            HStack {
                Button("Cancel", role: .cancel) {
                    model.pendingConfirmation = nil
                }
                Spacer()
                if item?.victim.isUnrecoverable == true {
                    Button("Save a Copy First") {
                        model.saveACopyFirst(plan)
                    }
                    .buttonStyle(.bordered)
                }
                if item?.victim.isUnknown == true {
                    // Unjudged victim: Read First is PRIMARY (§9.1).
                    Button("Read First (~1 s)") {
                        model.readFirstThenReplan(plan)
                    }
                    .buttonStyle(.borderedProminent)
                    Button(plan.confirmLabel) {
                        pending.confirm()
                    }
                    .buttonStyle(.bordered)
                } else {
                    Button(plan.confirmLabel) {
                        pending.confirm()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(24)
        .presentationDragIndicator(.visible)
    }

    @ViewBuilder
    private func victimSection(_ item: OverwritePlan.Item) -> some View {
        switch item.victim {
        case .named(let name, let recoverable):
            Label("Replaces '\(name)'", systemImage: "arrow.uturn.down")
            Text(recoverable.line)
                .foregroundStyle(recoverable == .none ? .red : .secondary)
        case .empty(let evidence):
            Label("Replaces empty slot — \(evidence)",
                  systemImage: "circle.dashed")
                .foregroundStyle(.secondary)
        case .unknown(let known):
            if let known {
                Label("Replaces '\(known)'", systemImage: "arrow.uturn.down")
            }
            Label("This slot's contents have not been read — the app cannot "
                  + "tell you what would be lost.",
                  systemImage: "questionmark.circle")
                .foregroundStyle(.orange)
        }
    }

    private var footers: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(plan.freshnessLine)
                .font(.caption)
                .foregroundStyle(.secondary)
            if plan.isPracticeDevice {
                Label("Practice device — no hardware will change.",
                      systemImage: "waveform.path")
                    .font(.caption)
                    .foregroundStyle(.purple)
            }
        }
    }
}

/// The one-tap popover for expendable victims, anchored at the touched row
/// (§9.5 "popover", §13.2).
struct OverwriteConfirmationPopover: View {
    @Environment(AppModel.self) private var model
    let pending: PendingConfirmation

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(pending.plan.dialogTitle)
                .font(.callout.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            Text(pending.plan.freshnessLine)
                .font(.caption2)
                .foregroundStyle(.secondary)
            if pending.plan.isPracticeDevice {
                Text("Practice device — no hardware will change.")
                    .font(.caption2)
                    .foregroundStyle(.purple)
            }
            HStack {
                Button("Cancel", role: .cancel) {
                    model.pendingConfirmation = nil
                }
                .buttonStyle(.bordered)
                Spacer()
                Button(pending.plan.confirmLabel) {
                    pending.confirm()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        .frame(idealWidth: 340)
        .presentationCompactAdaptation(.popover)
    }
}

#Preview("Overwrite dialog") {
    PreviewHost { model in
        Color.clear.onAppear {
            model.requestSend(
                PresetTransfer(source: .deviceSlot(SlotID(3)),
                               displayName: "Fat Bass v2"),
                to: SlotID(412))
        }
        .sheet(item: Binding(
            get: { model.pendingConfirmation },
            set: { if $0 == nil { model.pendingConfirmation = nil } })) {
            OverwriteConfirmationView(pending: $0)
                .presentationDetents([.medium])
        }
    }
}
