// BackupProgressSheet.swift — long-op progress + pause/cancel (UX §16.1).
//
// Dismissable — the operation continues and the status bar mirrors it.
// Determinate bar, current slot streaming by, elapsed, median-based ETA
// ("estimating…" until the core supplies one; m:ss; updated at most once a
// second), throughput, Pause (cancel — the on-disk partial IS the pause
// state) and Cancel (same mechanism, framed as stopping).

import SwiftUI
import FreakCore

struct BackupProgressSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if model.connection.isPractice {
                PracticeBanner()
            }
            if let run = model.backupRun {
                Text(run.isResume ? "Resuming backup" : "Backing up")
                    .font(.title2.weight(.semibold))
                BackupProgressBody(run: run)
                controls(run)
            } else {
                Text("No backup running.")
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(24)
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }

    @ViewBuilder
    private func controls(_ run: BackupRunState) -> some View {
        // §13.1: actions bottom-anchored.
        HStack {
            Button("Dismiss (keeps running)") { dismiss() }
                .buttonStyle(.bordered)
            Spacer()
            switch run.phase {
            case .running:
                Button("Pause") { run.pause() }
                    .buttonStyle(.bordered)
                Button("Cancel", role: .destructive) { run.pause() }
                    .buttonStyle(.bordered)
            case .paused:
                Button("Resume") {
                    dismiss()
                    model.resumeBackup(run.folderName)
                }
                .buttonStyle(.borderedProminent)
            case .done, .failed:
                Button("Close") { dismiss() }
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}

/// The shared progress body — also rendered inline by the Sync compare
/// state (same operation, UX §17).
struct BackupProgressBody: View {
    let run: BackupRunState

    @State private var displayedETA: TimeInterval?
    @State private var lastETAUpdate = Date.distantPast

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch run.phase {
            case .running:
                runningBody
            case .paused(let done, let total):
                Label("Paused — \(done) of \(total) saved. Resume anytime.",
                      systemImage: "pause.circle")
                    .font(.callout)
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.red)
            case .done:
                doneBody
            }
        }
    }

    @ViewBuilder
    private var runningBody: some View {
        let event = run.progress
        ProgressView(value: Double(event?.done ?? 0),
                     total: Double(max(event?.total ?? 1, 1)))
        HStack {
            if let event {
                Text("\(event.done)/\(event.total)")
                    .font(.callout.monospacedDigit())
                Text("slot \(SlotID(event.slot).display) · \(event.name)")
                    .font(.callout)
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
            } else {
                Text("Starting…").font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
        }
        HStack(spacing: 16) {
            if let event {
                Label(Format.clock(event.elapsedSeconds),
                      systemImage: "clock")
                    .font(.caption.monospacedDigit())
                Label(etaText(event), systemImage: "timer")
                    .font(.caption.monospacedDigit())
                if event.done > 0 && event.elapsedSeconds > 0 {
                    Text(Format.throughput(
                        perSlotSeconds: event.elapsedSeconds
                            / Double(event.done)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
    }

    @ViewBuilder
    private var doneBody: some View {
        if let timing = run.timing {
            Label("\(Int(timing.totalSeconds.rounded())) s total · "
                  + Format.throughput(perSlotSeconds: timing.perSlotSeconds),
                  systemImage: "checkmark.circle")
                .font(.callout)
                .foregroundStyle(.green)
        } else {
            Label("Done", systemImage: "checkmark.circle")
                .foregroundStyle(.green)
        }
    }

    /// ETA display rules (UX §16.1): "estimating…" until the core supplies
    /// one; m:ss; refreshed at most once per second.
    private func etaText(_ event: ProgressEvent) -> String {
        guard let eta = event.etaSeconds else { return "estimating…" }
        let now = Date()
        if now.timeIntervalSince(lastETAUpdate) >= 1.0
            || displayedETA == nil {
            // View-state mutation from body is safe via async dispatch.
            Task { @MainActor in
                displayedETA = eta
                lastETAUpdate = now
            }
            return Format.clock(eta) + " left"
        }
        return Format.clock(displayedETA ?? eta) + " left"
    }
}

#Preview("Backup progress") {
    PreviewHost { model in
        Color.clear
            .onAppear { model.backUpNow() }
            .sheet(isPresented: .constant(true)) {
                BackupProgressSheet()
            }
    }
}
