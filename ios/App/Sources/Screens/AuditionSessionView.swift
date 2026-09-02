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
    /// The end-of-session review, presented HERE while the cover is still up
    /// (RootView's copy of the sheet cannot show through a fullScreenCover).
    @State private var reviewing = false

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
        .onChange(of: model.audition.phase) { _, phase in
            // Queue done, cover still up: the catch-all review opens here,
            // before Stop tears the screen down.
            guard phase == .exhausted, model.voiceNotes.hasCapturedNotes
            else { return }
            model.voiceNotes.requestReview()
            reviewing = true
        }
        .sheet(isPresented: $reviewing) {
            if let request = model.voiceNotes.review {
                NoteReviewSheet(request: request)
            }
        }
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
            HStack(spacing: 10) {
                Text("Borrowing slot \(slotDisplay)")
                    .font(.caption2).foregroundStyle(.secondary)
                // The app's OWN live-microphone indication (App Review
                // 2.5.14), and the mute control, in one place the user can
                // reach without looking away from the synth.
                //
                // Gated on isCapturing, not isListening: a session whose
                // capture is suspended (an interface took the input, an
                // interruption, a tap that could not be rebuilt) is still
                // armed but is hearing nothing, and a pulsing "Listening" over
                // a dead microphone is the one thing this indicator must never
                // do. The suspension line below takes its place.
                if model.voiceNotes.isCapturing {
                    ListeningPill(isListening: true,
                                  isMuted: model.voiceNotes.isMuted) {
                        model.voiceNotes.toggleMuted()
                    }
                }
            }
            if let reason = model.voiceNotes.suspendedReason {
                Label(reason, systemImage: "mic.slash")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if let failure = model.voiceNotes.failure {
                Label(failure, systemImage: "exclamationmark.triangle")
                    .font(.caption2).foregroundStyle(.secondary)
            }
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
                    // Directly under the name, deliberately: a misattributed
                    // sentence is visible within a second of being said, which
                    // is what makes the one-tap repair below worth having.
                    liveTranscript(for: entry)
                    Text(origin(of: entry))
                        .font(.title3).foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        CategoryBadge(category: entry.category)
                        ForEach(entry.tags, id: \.self) { TagChip(tag: $0) }
                    }
                    ghostedProposals(for: entry)
                }
                Text("Play it. Then file it.")
                    .font(.callout).foregroundStyle(.secondary)
                VerdictChips(heard: model.voiceNotes.heardVerdictValue,
                             heardCaption: model.voiceNotes.heardVerdictCaption) {
                    model.audition.pick($0)
                }
                .padding(.horizontal)
            }
        case .exhausted:
            ContentUnavailableView {
                Label("That's everything", systemImage: "checkmark.seal")
            } description: {
                Text("\(model.audition.judged) verdicts filed. Stop to put the "
                     + "slot back the way it was.")
            } actions: {
                if model.voiceNotes.hasCapturedNotes {
                    Button("Review Notes") {
                        model.voiceNotes.requestReview()
                        reviewing = true
                    }
                    .buttonStyle(.borderedProminent)
                }
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

    // ------------------------------------------------------- voice notes

    /// The transcript for the preset on screen, plus the one-tap repair for a
    /// sentence that landed on the wrong preset.
    @ViewBuilder
    private func liveTranscript(for entry: LibraryEntry) -> some View {
        let voice = model.voiceNotes
        if voice.isListening || !(voice.captured[entry.id] ?? []).isEmpty {
            VStack(spacing: 4) {
                Text(voice.liveTranscript.isEmpty
                     ? (voice.isCapturing
                        ? "Listening — say what you think."
                        : "Not listening right now.")
                     : voice.liveTranscript)
                    .font(.callout)
                    .italic(voice.liveTranscript.isEmpty)
                    .foregroundStyle(voice.liveTranscript.isEmpty
                                     ? .secondary : .primary)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .frame(maxWidth: 640)
                    .accessibilityLabel(voice.liveTranscript.isEmpty
                                        ? "No speech heard yet"
                                        : "Heard: \(voice.liveTranscript)")
                if let last = voice.captured[entry.id]?.last,
                   voice.previousEntryID(before: entry.id) != nil {
                    Button {
                        Task {
                            await voice.moveToPreviousPreset(note: last,
                                                             from: entry.id)
                        }
                    } label: {
                        Label("That was about the previous preset",
                              systemImage: "arrow.uturn.backward")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// Ghosted Type and Characteristic chips — proposals, drawn as things that
    /// are not true yet. A tap promotes each one through the existing setter;
    /// nothing here changes the entry on its own.
    @ViewBuilder
    private func ghostedProposals(for entry: LibraryEntry) -> some View {
        let voice = model.voiceNotes
        let category = voice.ghostedCategory(for: entry)
        let tags = voice.ghostedTags(for: entry)
        if category != nil || !tags.isEmpty {
            HStack(spacing: 8) {
                if let category {
                    // The caption is the provenance: it appears only when the
                    // words heard were NOT the chip's own label, which is
                    // exactly when the user would otherwise have no way to
                    // tell where the suggestion came from.
                    GhostChip(title: category.displayName,
                              caption: voice.ghostedCategoryCaption(category)) {
                        Task { await voice.acceptCategory(category,
                                                          for: entry.id) }
                    }
                }
                ForEach(tags, id: \.self) { tag in
                    GhostChip(title: tag,
                              caption: voice.ghostedTagCaption(tag)) {
                        Task { await voice.acceptTag(tag, for: entry.id) }
                    }
                }
            }
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
