// SyncListView.swift — device vs. library, one row per slot (UX §17).
//
// The diff computes; only explicit user actions write. The precondition
// banner is the honest gate: no hashed snapshot → the CTA state pricing the
// full pass (~3½ minutes, kept as a backup). Filter bar with live counts;
// per-status explicit actions; bulk Apply… never pre-resolves conflicts.

import SwiftUI
import FreakCore

struct SyncListView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            switch model.sync.state {
            case .needsSnapshot:
                needsSnapshotState
            case .comparing:
                comparingState
            case .failed(let message):
                failedState(message)
            case .ready:
                readyList
            }
        }
        .navigationTitle("Sync")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Apply…") { model.openBulkApply() }
                    .disabled(model.sync.state != .ready
                              || !model.connection.hasDevice
                              || model.operations.exclusiveLongOp != nil)
            }
        }
    }

    // -------------------------------------------------------------- states

    private var needsSnapshotState: some View {
        ContentUnavailableView {
            Label("Nothing to compare yet",
                  systemImage: "arrow.triangle.2.circlepath")
        } description: {
            Text(model.sync.readEstimateCopy)
        } actions: {
            Button("Read Device & Compare") { model.readDeviceAndCompare() }
                .buttonStyle(.borderedProminent)
                .disabled(!model.connection.hasDevice
                          || model.operations.exclusiveLongOp != nil)
            if model.libraryModel.entries.isEmpty {
                Button("Your library is empty — start there") {
                    model.sidebar = .library(tag: nil)
                }
                .buttonStyle(.bordered)
            }
        }
    }

    /// Compare running = the backup's progress, inline (same op, UX §17).
    private var comparingState: some View {
        VStack(spacing: 16) {
            if let run = model.backupRun, run.purpose == .compare {
                BackupProgressBody(run: run)
                    .padding(24)
            } else {
                ProgressView("Reading the device…")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func failedState(_ message: String) -> some View {
        ContentUnavailableView {
            Label("Compare failed", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            Button("Retry") { model.readDeviceAndCompare() }
                .buttonStyle(.borderedProminent)
                .disabled(!model.connection.hasDevice)
        }
    }

    // --------------------------------------------------------------- ready

    private var readyList: some View {
        List {
            Section {
                SyncProvenanceHeader()
            }
            Section {
                SyncFilterBar()
            }
            if let summary = model.sync.allInSyncSummary {
                Section {
                    Label(summary, systemImage: "checkmark.circle")
                        .foregroundStyle(.green)
                }
            }
            Section {
                ForEach(model.sync.visibleRows, id: \.slot) { row in
                    SyncRowView(row: row)
                }
            }
        }
        .listStyle(.plain)
    }
}

// ===================================================================== header

/// "Compared against device read 12 min ago (backup …) · 3 writes since."
struct SyncProvenanceHeader: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                if let provenance = model.sync.provenance {
                    Text("Compared against \(provenance.line) · "
                         + "\(model.freshness.writesSinceBackup) writes since")
                        .font(.caption)
                        .foregroundStyle(provenance.isStale
                            ? .orange : .secondary)
                    if provenance.isStale {
                        Text("This read is over a day old — the synth may "
                             + "have changed.")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
            }
            Spacer()
            Button("Re-read") { model.readDeviceAndCompare() }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!model.connection.hasDevice
                          || model.operations.exclusiveLongOp != nil)
        }
    }
}

// ================================================================= filter bar

/// Live-count toggles; default hides in-sync and empty (UX §17).
struct SyncFilterBar: View {
    @Environment(AppModel.self) private var model

    private let order: [SlotStatus] = [.deviceOnly, .differs, .libraryOnly,
                                       .inSync, .empty]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(order, id: \.self) { status in
                    let count = model.sync.counts[status] ?? 0
                    let isOn = model.sync.visibleStatuses.contains(status)
                    Button {
                        if isOn {
                            model.sync.visibleStatuses.remove(status)
                        } else {
                            model.sync.visibleStatuses.insert(status)
                        }
                    } label: {
                        HStack(spacing: 4) {
                            SyncBadge(status: status)
                            Text("\(count)")
                                .font(.caption.monospacedDigit())
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(isOn ? Color.accentColor.opacity(0.12)
                                         : Color.clear,
                                    in: Capsule())
                        .overlay(Capsule().stroke(
                            isOn ? Color.accentColor : Color.secondary
                                .opacity(0.3), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

// ======================================================================== row

struct SyncRowView: View {
    @Environment(AppModel.self) private var model
    let row: SlotDiff

    private var slot: SlotID { SlotID(row.slot) }

    var body: some View {
        HStack(spacing: 12) {
            SlotNumberLabel(slot: slot)
            VStack(alignment: .leading, spacing: 2) {
                Text(primaryLine).font(.body).lineLimit(1)
                Text(secondaryLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            SyncBadge(status: row.status)
            actions
        }
        .frame(minHeight: 52)
        .contentShape(Rectangle())
        .onTapGesture { model.detail = .syncSlot(slot) }
    }

    private var primaryLine: String {
        switch row.status {
        case .deviceOnly:
            return "device \"\(row.device?.name ?? "")\""
        case .libraryOnly:
            return "library \"\(row.library?.name ?? "")\""
        case .differs:
            return "device \"\(row.device?.name ?? "")\" ≠ "
                + "library \"\(row.library?.name ?? "")\""
        case .inSync:
            return row.device?.name ?? row.library?.name ?? ""
        case .empty:
            return row.device?.name ?? ""
        }
    }

    private var secondaryLine: String {
        switch row.status {
        case .deviceOnly: return "not in library"
        case .libraryOnly: return "device slot empty"
        case .differs: return "contents differ"
        case .inSync:
            if let device = row.device, let library = row.library,
               device.name != library.name {
                return "in sync · names differ"
            }
            return "in sync"
        case .empty:
            if let judgment = model.slots.record(slot)?.judgment,
               case .expendable(let evidence) = judgment {
                return evidence
            }
            return "judged empty"
        }
    }

    @ViewBuilder
    private var actions: some View {
        let deviceReady = model.connection.hasDevice
            && model.operations.exclusiveLongOp == nil
        switch row.status {
        case .deviceOnly:
            Button("Import to Library") { model.syncImportRow(row) }
                .buttonStyle(.bordered)
                .controlSize(.small)
        case .libraryOnly:
            Button("Send to Device") { model.syncSendRow(row) }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!deviceReady)
        case .differs:
            Menu {
                Button("Push Library → Device") { model.syncPushRow(row) }
                    .disabled(!deviceReady)
                Button("Pull Device → Library") { model.syncPullRow(row) }
            } label: {
                Text("Resolve…")
                    .font(.callout)
            }
            .menuStyle(.button)
            .buttonStyle(.bordered)
            .controlSize(.small)
        case .inSync, .empty:
            EmptyView()
        }
    }
}

#Preview("Sync") {
    PreviewHost { _ in
        NavigationStack { SyncListView() }
    }
}
