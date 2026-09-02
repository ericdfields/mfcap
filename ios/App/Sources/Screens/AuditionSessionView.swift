// AuditionSessionView.swift — the running audition, full attention.
//
// Designed for standing at the MicroFreak with the iPad beside it: one preset
// name in big type, four large verdict targets, nothing else to read. Presented
// by RootView as a fullScreenCover so it sits ABOVE the split view and cannot
// be clipped by a column's own bars.
//
// Minimize hands the screen back WITHOUT ending the session: the slot stays
// borrowed and the standing banner in RootView says so and offers the way back.

import SwiftUI
import FreakCore

struct AuditionSessionView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 28) {
            header
            Spacer(minLength: 0)
            phaseContent
            Spacer(minLength: 0)
            bottomBar
        }
        .padding()
        // RootView's standing loan banner is suppressed only while this cover
        // is genuinely on screen — so it tells the model, rather than the
        // model assuming a presentation always succeeds.
        .onAppear { model.audition.coverAppeared() }
        .onDisappear { model.audition.coverDisappeared() }
    }

    // ------------------------------------------------------------- header

    @ViewBuilder
    private var header: some View {
        VStack(spacing: 4) {
            if model.connection.isPractice {
                Label("Practice mode — nothing is playing on a real synth",
                      systemImage: "waveform.slash")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Text(model.audition.sourceLabel)
                .font(.footnote).foregroundStyle(.secondary)
                .lineLimit(1)
            Text("Borrowing slot \(slotDisplay)")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    /// The slot the session actually borrowed (the picker's `slot` is only a
    /// fallback for the moment before one exists).
    private var slotDisplay: Int {
        SlotID(model.audition.borrowedSlot ?? model.audition.slot).display
    }

    // -------------------------------------------------------------- phases

    @ViewBuilder
    private var phaseContent: some View {
        switch model.audition.phase {
        case .starting:
            ProgressView("Saving slot \(slotDisplay)…")
        case .loading:
            ProgressView("Loading next preset…")
        case .playing:
            if let entry = model.audition.current {
                VStack(spacing: 8) {
                    Text(entry.name)
                        .font(.system(size: 44, weight: .bold, design: .rounded))
                        .multilineTextAlignment(.center)
                    Text(origin(of: entry))
                        .font(.title3).foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        CategoryBadge(category: entry.category)
                        ForEach(entry.tags, id: \.self) { TagChip(tag: $0) }
                    }
                }
                Text("Play it. Then file it.")
                    .font(.callout).foregroundStyle(.secondary)
                VerdictChips { model.audition.pick($0) }
                    .padding(.horizontal)
            }
        case .exhausted:
            ContentUnavailableView {
                Label("That's everything", systemImage: "checkmark.seal")
            } description: {
                Text("\(model.audition.judged) verdicts filed. Stop to put the "
                     + "slot back the way it was.")
            }
        case .failed(let why):
            ContentUnavailableView {
                Label("Audition stopped", systemImage: "exclamationmark.triangle")
            } description: {
                Text(why)
            } actions: {
                if model.audition.needsRestore {
                    // The escape hatch. Safe only because the borrowed
                    // original is on disk: this hands the promise to the
                    // recovery banner instead of pretending it is settled.
                    Button("Put It Back Later") { model.audition.abandon() }
                        .buttonStyle(.bordered)
                }
            }
        case .idle:
            EmptyView()
        }
    }

    // ---------------------------------------------------------- bottom bar

    private var bottomBar: some View {
        HStack {
            Text("\(model.audition.total - model.audition.remaining) of "
                 + "\(model.audition.total)")
                .monospacedDigit().foregroundStyle(.secondary)
            Spacer()
            Button("Minimize") { model.audition.presented = false }
                .buttonStyle(.bordered)
            Button("Skip") { model.audition.skip() }
                .disabled(model.audition.phase != .playing)
                .keyboardShortcut(.space, modifiers: [])
            Button("Stop", role: .destructive) { model.audition.stop() }
                .buttonStyle(.bordered)
                .keyboardShortcut(.escape, modifiers: [])
        }
        .padding()
    }

    /// "Voltage Forms · slot 3" — which collection(s) this preset came from.
    private func origin(of entry: LibraryEntry) -> String {
        let names = model.collectionsModel.sorted
            .filter { coll in coll.slots.values.contains { $0.sha256 == entry.sha256 } }
            .map(\.name)
        return names.isEmpty ? "Library" : names.joined(separator: " · ")
    }
}

#Preview("Audition session") {
    PreviewHost { _ in
        AuditionSessionView()
    }
}
