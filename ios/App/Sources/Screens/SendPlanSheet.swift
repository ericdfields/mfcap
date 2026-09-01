// SendPlanSheet.swift — the plan sheet for multi-target sends (UX §8.1,
// §9.5 planSheet severity). Lists every target and victim; Confirm/Cancel
// bottom-trailing (§13.2). Also renders the running batch with per-row
// ticks and Retry Remaining after a stop-at-first-failure.

import SwiftUI
import FreakCore

struct SendPlanSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let pending: PendingConfirmation

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if model.connection.isPractice {
                    PracticeBanner()
                }
                List {
                    ForEach(pending.plan.items) { item in
                        row(item)
                    }
                }
                .listStyle(.plain)
                Divider()
                footer
            }
            .navigationTitle(pending.plan.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        model.pendingConfirmation = nil
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func row(_ item: OverwritePlan.Item) -> some View {
        HStack(spacing: 12) {
            SlotNumberLabel(slot: item.target)
            VStack(alignment: .leading, spacing: 2) {
                Text("← '\(item.incomingName)'")
                    .font(.callout)
                    .lineLimit(1)
                Text(item.victimLine)
                    .font(.caption)
                    .foregroundStyle(item.victim.isUnrecoverable
                        ? .red : .secondary)
            }
            Spacer()
            if let run = model.sendPlanRun, run.plan.id == pending.plan.id {
                switch run.state(item.target) {
                case .done:
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                case .running:
                    ProgressView().controlSize(.small)
                case .failed:
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.red)
                case .pending, .skipped:
                    EmptyView()
                }
            }
        }
        .frame(minHeight: 44)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(pending.plan.writeCount) verified writes · "
                 + Format.estimate(pending.plan.estimatedDuration))
                .font(.callout)
            Text(pending.plan.freshnessLine)
                .font(.caption)
                .foregroundStyle(.secondary)
            if pending.plan.isPracticeDevice {
                Text("Practice device — no hardware will change.")
                    .font(.caption)
                    .foregroundStyle(.purple)
            }
            HStack {
                Spacer()
                if let run = model.sendPlanRun,
                   run.plan.id == pending.plan.id, run.failure != nil {
                    Button("Retry Remaining") {
                        model.retryBatchRemaining(run)
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Button(pending.plan.confirmLabel) {
                        dismiss()
                        pending.confirm()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.connection.hasDevice
                              || pending.plan.writeCount == 0)
                }
            }
        }
        .padding(16)
    }
}
