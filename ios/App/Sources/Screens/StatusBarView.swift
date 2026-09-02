// StatusBarView.swift — device ACTIVITY, formerly the global bottom bar.
//
// The full-width frosted strip that used to sit at the bottom of the split
// view is gone: it was a safeAreaInset on the NavigationSplitView itself, so
// the columns laid out beneath it and it painted over their own bottom bars
// (CollectionDetailView's Apply bar, SlotListView's multi-select bar).
//
// What it carried is re-homed, not lost:
//   - connection state  → SidebarView's Device section (DeviceStatusRow)
//   - the running op    → `ActiveOperationView`, a TRANSIENT toolbar item in
//                         the content column's nav bar (nothing to occlude;
//                         "Idle" is expressed by absence)
//   - the ops history   → `OperationsPopover`, reachable from that item while
//                         busy and from the sidebar's device menu while idle
//
// Cancel/Pause for a running long op lives in both survivors, unchanged: the
// popover is still the only way to stop a 32-slot verified write mid-flight.

import SwiftUI
import FreakCore

// ==================================================== the toolbar attachment

/// Adds the transient device-activity item to whichever content-column screen
/// is showing. Applied once, in RootView; merges with each screen's own
/// `.toolbar`.
struct DeviceActivityToolbarModifier: ViewModifier {
    @Environment(AppModel.self) private var model
    @State private var showOperations = false

    private var busy: Bool {
        model.operations.current != nil || !model.operations.queued.isEmpty
    }

    func body(content: Content) -> some View {
        content.toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if busy {
                    // NOT a Button wrapping the whole view: Cancel/Pause lives
                    // inside ActiveOperationView, and a control nested in
                    // another Button's label never gets the tap — the outer
                    // button swallowed it and opened this popover instead, so
                    // "Cancel" did not cancel.
                    ActiveOperationView(openDetails: { showOperations = true })
                        .popover(isPresented: $showOperations) {
                            OperationsPopover()
                        }
                }
            }
        }
    }
}

extension View {
    /// The replacement for the old global status bar's right-hand side.
    func deviceActivityToolbar() -> some View {
        modifier(DeviceActivityToolbarModifier())
    }
}

// ============================================================= active op view

/// The running operation: label, sub-label, determinate progress, ETA,
/// Cancel/Pause for long ops, and the queued-behind count. Renders nothing
/// when the device is idle.
///
/// `openDetails` makes only the SUMMARY tappable. Cancel/Pause is a sibling of
/// that button, never nested inside it, so the labelled control does what it
/// says.
struct ActiveOperationView: View {
    @Environment(AppModel.self) private var model
    var openDetails: (() -> Void)?

    var body: some View {
        HStack(spacing: 10) {
            if let op = model.operations.current {
                Button {
                    openDetails?()
                } label: {
                    VStack(alignment: .trailing, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(op.label)
                                .font(.caption.weight(.medium))
                                .lineLimit(1)
                            if let sub = op.subLabel {
                                Text(sub)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        if let progress = op.progress {
                            HStack(spacing: 6) {
                                ProgressView(value: Double(progress.done),
                                             total: Double(max(progress.total, 1)))
                                    .frame(width: 120)
                                if let eta = progress.etaSeconds {
                                    Text(Format.clock(eta))
                                        .font(.caption2.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                .buttonStyle(.plain)
                .disabled(openDetails == nil)
                .accessibilityLabel("Device activity")
                if op.kind == .long {
                    Button(op.label.hasPrefix("Backing") ? "Pause" : "Cancel") {
                        op.cancel()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                } else {
                    ProgressView().controlSize(.small)
                }
                if !model.operations.queued.isEmpty {
                    Text("+\(model.operations.queued.count) queued")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } else if !model.operations.queued.isEmpty {
                ProgressView().controlSize(.small)
                Text("\(model.operations.queued.count) queued")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// ========================================================= operations popover

struct OperationsPopover: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Device operations")
                .font(.headline)
            if let current = model.operations.current {
                opRow(current, heading: "Running")
            }
            ForEach(model.operations.queued) { op in
                opRow(op, heading: "Queued")
            }
            if model.operations.current == nil
                && model.operations.queued.isEmpty {
                Text("Idle — one operation runs at a time; quick writes "
                     + "queue behind long ones.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let run = model.sendPlanRun, !run.finished, !run.cancelled {
                // Batches cancel BETWEEN slots (§9.8); single writes are
                // never cancellable mid-burst.
                Button("Stop batch after current slot") {
                    run.cancelled = true
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            if !model.operations.recent.isEmpty {
                Divider()
                Text("Recent")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(model.operations.recent.prefix(8)) { op in
                    recentRow(op)
                }
            }
        }
        .padding(16)
        .frame(idealWidth: 360)
        .presentationCompactAdaptation(.popover)
    }

    private func opRow(_ op: DeviceOperation, heading: String) -> some View {
        HStack(spacing: 8) {
            Text(heading)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(op.label).font(.callout)
                if let progress = op.progress {
                    Text("\(progress.done)/\(progress.total)"
                         + (progress.etaSeconds.map {
                             " · \(Format.clock($0)) left"
                         } ?? ""))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            // Only LONG ops are cancellable (between slots); a quick write's
            // 7-frame burst is too short and a mid-burst cancel tears the
            // slot (UX §8.2, §9.8).
            if op.phase == .running && op.kind == .long {
                Button("Cancel") { op.cancel() }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
            }
        }
    }

    private func recentRow(_ op: DeviceOperation) -> some View {
        HStack(spacing: 8) {
            switch op.phase {
            case .succeeded:
                Image(systemName: "checkmark.circle")
                    .foregroundStyle(.green)
            case .failed:
                Image(systemName: "xmark.circle")
                    .foregroundStyle(.red)
            case .cancelled:
                Image(systemName: "stop.circle")
                    .foregroundStyle(.secondary)
            default:
                Image(systemName: "circle")
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(op.label).font(.caption)
                if case .failed(let message) = op.phase {
                    Text(message)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
            }
            Spacer()
            if let finished = op.finishedAt {
                Text(Format.relativeAge(finished))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

#Preview("Operations popover") {
    PreviewHost { _ in
        OperationsPopover()
    }
}
