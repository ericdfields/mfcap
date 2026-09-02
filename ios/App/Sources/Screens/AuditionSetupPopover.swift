// AuditionSetupPopover.swift — audition as an ACTION on the list you are
// looking at (UX addendum §30).
//
// The toolbar button snapshots the visible set ONCE, when the popover opens,
// and this view splits it into rated/unrated ONCE, in its init — so a
// 966-entry library is filtered twice on open and never again per body pass.
// The popover states the queue, where it came from, the unrated-only choice,
// and which slot gets borrowed — the four facts the old Audition panel
// buried. Start hands AuditionModel an explicit queue; the running session
// takes over the screen from RootView.

import SwiftUI
import FreakCore

/// The affordance. `build` is called once, when the popover opens.
struct AuditionButton: View {
    @Environment(AppModel.self) private var model
    var titleKey = "Audition…"
    let build: () -> AuditionRequest

    @State private var request: AuditionRequest?

    var body: some View {
        Button {
            request = build()
        } label: {
            Label(titleKey, systemImage: "play.circle")
        }
        .disabled(model.auditionStartBlockReason() != nil)
        .help(model.auditionStartBlockReason()
              ?? "Play these presets on the synth, one verdict each.")
        .popover(item: $request) { request in
            AuditionSetupPopover(request: request)
        }
    }
}

struct AuditionSetupPopover: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let request: AuditionRequest
    /// Filtered once, in init — `queue` and `unratedCount` are read four
    /// times per body pass between them.
    private let unratedCandidates: [LibraryEntry]

    @State private var unratedOnly = true

    init(request: AuditionRequest) {
        self.request = request
        self.unratedCandidates = request.unratedCandidates
    }

    private var queue: [LibraryEntry] {
        unratedOnly ? unratedCandidates : request.candidates
    }

    var body: some View {
        @Bindable var audition = model.audition
        let expendable = model.audition.expendableSlots(model)
        return Form {
            Section {
                LabeledContent("Auditioning") {
                    Text("\(queue.count) preset\(queue.count == 1 ? "" : "s")")
                        .monospacedDigit()
                }
                Text(request.sourceLabel)
                    .font(.footnote).foregroundStyle(.secondary)
                if request.unresolvedCount > 0 {
                    Text("\(request.unresolvedCount) preset"
                         + "\(request.unresolvedCount == 1 ? "" : "s") here "
                         + "aren't in the library — they can't be judged and "
                         + "are skipped.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            Section {
                Picker("Queue", selection: $unratedOnly) {
                    Text("Unrated (\(unratedCandidates.count))").tag(true)
                    Text("All (\(request.candidates.count))").tag(false)
                }
                .pickerStyle(.segmented)
                if unratedOnly && unratedCandidates.isEmpty {
                    Text("Everything here has been judged. Switch to All to "
                         + "hear them again — verdicts are overwritten as you "
                         + "go.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            Section("Audition slot") {
                Picker("Slot to borrow", selection: $audition.slot) {
                    ForEach(expendable.isEmpty ? [SlotID.Layout.slots - 1]
                                                : expendable,
                            id: \.self) { s in
                        Text("Slot \(SlotID(s).display)").tag(s)
                    }
                }
                Text(expendable.isEmpty
                     ? "No slot has been judged empty yet — read the device first, "
                       + "or accept the highest slot: it is saved and put back either way."
                     : "Judged empty on the device. Its current contents are saved "
                       + "first and restored when you stop.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                Button {
                    model.audition.start(model, queue: queue,
                                         sourceLabel: request.sourceLabel)
                    dismiss()
                } label: {
                    Label("Start auditioning", systemImage: "play.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(startDisabled)
                if let reason = startReason {
                    Text(reason)
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Text("If the synth's display doesn't change when a preset loads, "
                     + "turn on Utility → MIDI → Program Change Receive on the "
                     + "MicroFreak.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .frame(idealWidth: 380, idealHeight: 520)
        .onAppear { model.audition.adoptDefaultSlot(model) }
    }

    private var startDisabled: Bool {
        queue.isEmpty || model.device == nil
            || model.auditionStartBlockReason() != nil
            || model.operations.exclusiveLongOp != nil
    }

    private var startReason: String? {
        if model.device == nil {
            return "Connect the MicroFreak (or enter practice mode) first."
        }
        if let reason = model.auditionStartBlockReason() { return reason }
        if let op = model.operations.exclusiveLongOp { return op.busyLine }
        if queue.isEmpty {
            return "Nothing to play — the queue is empty."
        }
        return nil
    }
}

#Preview("Audition setup") {
    PreviewHost { model in
        AuditionSetupPopover(
            request: AuditionRequest(sourceLabel: "All Presets",
                                     candidates: model.libraryModel.entries))
    }
}
