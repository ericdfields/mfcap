// RestorePlanSheet.swift — scope → plan → execute (UX §16.2).
//
// Every planned write lists its victim per §9; stale names trigger the
// automatic ~2 s refresh before the plan renders; missing-meta rows are
// pre-disabled with the core's own sentence; full-512 adds the final alert;
// execution stops at the first failure with Retry From Slot N.

import SwiftUI
import FreakCore

struct RestorePlanSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let request: RestorePlanRequest

    @State private var scope: RestorePlanRequest.Scope
    @State private var plan: OverwritePlan?
    @State private var building = false
    @State private var finalAlert = false
    @State private var selectedSlots = Set<Int>()

    init(request: RestorePlanRequest) {
        self.request = request
        _scope = State(initialValue: request.scope)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if model.connection.isPractice {
                    PracticeBanner()
                }
                scopePicker
                Divider()
                planBody
                Divider()
                footer
            }
            .navigationTitle("Restore from \(request.folderName)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .task(id: scopeKey) { await rebuild() }
        .alert("This overwrites every preset on the device — 512 slots.",
               isPresented: $finalAlert) {
            Button("Restore 512 Slots", role: .destructive) { confirm() }
            Button("Cancel", role: .cancel) {}
        }
        .presentationDetents([.large])
    }

    private var scopeKey: String {
        switch scope {
        case .fullDevice: return "full"
        case .differingSlots: return "differing"
        case .singleSlot(let slot): return "single-\(slot.raw)"
        // Selection toggles don't rebuild — the plan always covers every
        // covered slot; `selectedSlots` filters at confirm time.
        case .selectedSlots: return "sel"
        }
    }

    // ----------------------------------------------------------- scope step

    private var scopePicker: some View {
        Picker("Scope", selection: $scope) {
            Text("Full device").tag(RestorePlanRequest.Scope.fullDevice)
            Text("Selected slots").tag(
                RestorePlanRequest.Scope.selectedSlots([]))
            Text("Only slots that differ")
                .tag(RestorePlanRequest.Scope.differingSlots)
            if case .singleSlot(let slot) = request.scope {
                Text("Slot \(slot.display)")
                    .tag(RestorePlanRequest.Scope.singleSlot(slot))
            }
        }
        .pickerStyle(.segmented)
        .padding(16)
    }

    // ------------------------------------------------------------ plan step

    @ViewBuilder
    private var planBody: some View {
        if building {
            VStack(spacing: 12) {
                ProgressView()
                Text("Refreshing names so victims are current…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if case .differingSlots = scope, !model.slots.hasHashedSnapshot {
            ContentUnavailableView {
                Label("Needs a current hashed snapshot",
                      systemImage: "arrow.triangle.2.circlepath")
            } description: {
                Text("\"Only slots that differ\" compares against a full "
                     + "device read.")
            } actions: {
                Button("Read Device First (~3½ min)") {
                    dismiss()
                    model.readDeviceAndCompare()
                }
                .buttonStyle(.borderedProminent)
            }
        } else if let plan {
            List {
                if case .selectedSlots = scope {
                    Text("Tap rows to include or exclude them.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(plan.items) { item in
                    planRow(item)
                }
            }
            .listStyle(.plain)
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func planRow(_ item: OverwritePlan.Item) -> some View {
        HStack(spacing: 12) {
            if case .selectedSlots = scope {
                Image(systemName: selectedSlots.contains(item.target.raw)
                      ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(.tint)
            }
            SlotNumberLabel(slot: item.target)
            VStack(alignment: .leading, spacing: 2) {
                Text("← \"\(item.incomingName)\" (backup)")
                    .font(.callout)
                if let reason = item.disabledReason {
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else {
                    Text(victimDescription(item))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .opacity(item.disabledReason == nil ? 1 : 0.5)
        .contentShape(Rectangle())
        .onTapGesture {
            guard case .selectedSlots = scope,
                  item.disabledReason == nil else { return }
            if selectedSlots.contains(item.target.raw) {
                selectedSlots.remove(item.target.raw)
            } else {
                selectedSlots.insert(item.target.raw)
            }
        }
    }

    private func victimDescription(_ item: OverwritePlan.Item) -> String {
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

    // --------------------------------------------------------------- footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let plan = effectivePlan {
                Text("\(plan.writeCount) verified writes · "
                     + Format.estimate(plan.estimatedDuration))
                    .font(.callout)
                Text(plan.freshnessLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if plan.isPracticeDevice {
                    Text("Practice device — no hardware will change.")
                        .font(.caption)
                        .foregroundStyle(.purple)
                }
            }
            HStack {
                Spacer()
                Button(effectivePlan?.confirmLabel ?? "Restore") {
                    if effectivePlan?.severity == .planSheetPlusFinalAlert {
                        finalAlert = true   // §9.5 full-device final alert
                    } else {
                        confirm()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(effectivePlan == nil
                          || effectivePlan?.writeCount == 0
                          || !model.connection.hasDevice)
            }
        }
        .padding(16)
    }

    // -------------------------------------------------------------- actions

    /// The plan the confirm button executes: for "Selected slots" the full
    /// covered plan filtered by the current selection; otherwise the built
    /// plan as-is. The footer's count/label/severity read from this too.
    private var effectivePlan: OverwritePlan? {
        guard let plan else { return nil }
        guard case .selectedSlots = scope else { return plan }
        return OverwritePlan(
            kind: .restore,
            items: plan.items.filter { selectedSlots.contains($0.target.raw) },
            title: plan.title,
            freshnessLine: plan.freshnessLine,
            isPracticeDevice: plan.isPracticeDevice,
            backupFolderName: plan.backupFolderName)
    }

    private func rebuild() async {
        building = true
        defer { building = false }
        var effectiveScope = scope
        if case .selectedSlots = scope {
            // The pickable rows are ALL covered slots; the selection only
            // filters at confirm time (an empty selection must not produce
            // an empty, untoggleable plan).
            effectiveScope = .fullDevice
        }
        plan = await model.buildRestorePlan(
            RestorePlanRequest(folderName: request.folderName,
                               scope: effectiveScope))
        // Selecting starts from everything included.
        if case .selectedSlots = scope, selectedSlots.isEmpty,
           let plan {
            selectedSlots = Set(plan.items.compactMap {
                $0.disabledReason == nil ? $0.target.raw : nil
            })
        }
    }

    private func confirm() {
        guard let confirmed = effectivePlan else { return }
        dismiss()
        model.executeRestore(confirmed)
    }
}

#Preview("Restore plan") {
    PreviewHost { _ in
        RestorePlanSheet(request: RestorePlanRequest(
            folderName: "2026-09-01-120000"))
    }
}
