// StatusBarView.swift — the global bottom status bar (UX §3).
//
// Left: connection capsule; center-left in practice: the practice capsule;
// right: the active device operation with mini progress + Cancel/Pause, or
// "Idle". Tapping opens the Operations popover — the ONLY home of device
// busyness (one spinner vocabulary, UX §1.3).

import SwiftUI
import FreakCore

struct StatusBarView: View {
    @Environment(AppModel.self) private var model
    @State private var showOperations = false

    var body: some View {
        HStack(spacing: 12) {
            ConnectionCapsule()
            Spacer()
            ActiveOperationView()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
        .contentShape(Rectangle())
        .onTapGesture { showOperations = true }
        .popover(isPresented: $showOperations,
                 attachmentAnchor: .rect(.bounds)) {
            OperationsPopover()
        }
    }
}

// ==================================================================== capsule

struct ConnectionCapsule: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Button {
            if !model.connection.hasDevice {
                model.showConnectSheet = true
            }
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(color)
                    .frame(width: 8, height: 8)
                Text(text)
                    .font(.caption.weight(.medium))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(color.opacity(0.12), in: Capsule())
            .foregroundStyle(color)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Connection: \(text)")
    }

    private var text: String {
        switch model.connection {
        case .noDevice: return "No Device"
        case .connecting: return "Connecting…"
        case .hardware: return "MicroFreak · Connected"
        case .practice(let profile): return "Practice · \(profile.title)"
        }
    }

    private var color: Color {
        switch model.connection {
        case .noDevice: return .secondary
        case .connecting: return .orange
        case .hardware: return .green
        case .practice: return .purple   // the reserved practice tint (§11)
        }
    }
}

// ============================================================= active op view

struct ActiveOperationView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 10) {
            if let op = model.operations.current {
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
            } else {
                Text("Idle")
                    .font(.caption)
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

#Preview("Status bar") {
    PreviewHost { _ in
        VStack {
            Spacer()
            StatusBarView()
        }
    }
}
