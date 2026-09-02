// NoteReviewSheet.swift — the end-of-session catch-all (docs/voice-notes.md
// §3 rule 2, last bullet).
//
// During the audition the user's hands are on the keys and their attention is
// on the synth; the in-session controls (a pre-aimed verdict chip, a ghosted
// tag) are for the things worth one tap in the moment. Everything else lands
// here, once, when the session is over and the user can actually read.
//
// What this sheet is NOT: a place where a transcript becomes data on its own.
// Every chip starts UNSELECTED. Apply calls the same library setters the
// pickers call, so the results are indistinguishable from having typed them —
// which is the point of §3 rule 3. Close without applying and the library is
// untouched; only the notes remain, as provenance.
//
// The verbatim text is shown with the matched spans underlined so the user can
// see WHY each chip was offered. It is never rewritten: a correction is a
// separate field, and discarding a note is final because no audio was kept.

import SwiftUI
import FreakCore

struct NoteReviewSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let request: NoteReviewRequest

    /// One offered proposal. Identity is (entry, kind, value) — the same tag
    /// heard twice about one preset is one decision, not two.
    private struct Key: Hashable {
        enum Kind: Hashable { case verdict, category, tag }
        let entryID: String
        let kind: Kind
        let value: String
    }

    @State private var sections: [NoteReviewRequest.Section]
    @State private var selected: Set<Key> = []
    @State private var applying = false

    init(request: NoteReviewRequest) {
        self.request = request
        _sections = State(initialValue: request.sections)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Everything you said, kept word for word and attached "
                         + "to the preset that was playing. Nothing below has "
                         + "changed a preset — tick what you meant and Apply.")
                        .font(.footnote).foregroundStyle(.secondary)
                    // The sheet is presented AFTER the audition cover is gone,
                    // and the cover's header was the only thing that rendered
                    // `failure`. Every write this sheet can make — accept,
                    // move, discard — therefore had nowhere to report a
                    // problem, and Apply toasted success over failed writes.
                    if let failure = model.voiceNotes.failure {
                        Label(failure, systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                }
                ForEach(sections) { section in
                    entrySection(section)
                }
            }
            .navigationTitle("Notes from this session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { close() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(selected.isEmpty ? "Done" : "Apply \(selected.count)") {
                        apply()
                    }
                    .disabled(applying)
                }
            }
        }
    }

    // ------------------------------------------------------------- sections

    @ViewBuilder
    private func entrySection(_ section: NoteReviewRequest.Section) -> some View {
        let entry = model.libraryModel.entry(id: section.entryID)
        Section(entry?.name ?? "Preset no longer in the library") {
            ForEach(section.notes) { note in
                VStack(alignment: .leading, spacing: 8) {
                    NoteRowView(note: note)
                    if let entry {
                        proposalChips(note: note, entry: entry)
                    }
                    noteActions(note: note, section: section)
                }
                .padding(.vertical, 2)
            }
        }
    }

    /// The chips, unselected. A proposal whose value the entry ALREADY carries
    /// is not offered — there is nothing to decide.
    @ViewBuilder
    private func proposalChips(note: PresetNote, entry: LibraryEntry) -> some View {
        let keys = offered(note: note, entry: entry)
        if !keys.isEmpty {
            WrapHStack(keys) { key in
                Button {
                    if selected.contains(key) { selected.remove(key) }
                    else { selected.insert(key) }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: selected.contains(key)
                              ? "checkmark.circle.fill" : "circle")
                            .font(.caption2)
                        Text(label(for: key)).font(.caption2)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(selected.contains(key)
                                ? Color.accentColor.opacity(0.15)
                                : Color.secondary.opacity(0.10),
                                in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected.contains(key) ? .isSelected : [])
            }
        }
    }

    private func offered(note: PresetNote, entry: LibraryEntry) -> [Key] {
        var keys: [Key] = []
        if let verdict = note.proposals.verdictValue, verdict != entry.verdict {
            keys.append(Key(entryID: entry.id, kind: .verdict,
                            value: verdict.slug))
        }
        if let category = note.proposals.categoryValue,
           category != entry.category {
            keys.append(Key(entryID: entry.id, kind: .category,
                            value: category.slug))
        }
        for tag in note.proposals.tagValues
        where !entry.tags.contains(where: { $0.lowercased() == tag.lowercased() }) {
            keys.append(Key(entryID: entry.id, kind: .tag, value: tag))
        }
        return keys
    }

    private func label(for key: Key) -> String {
        switch key.kind {
        case .verdict:
            return "Verdict: \(Verdict.fromSlug(key.value).displayName)"
        case .category:
            return "Type: \(FreakCore.Category.fromSlug(key.value).displayName)"
        case .tag:
            return key.value
        }
    }

    // -------------------------------------------------------- per-note acts

    @ViewBuilder
    private func noteActions(note: PresetNote,
                             section: NoteReviewRequest.Section) -> some View {
        HStack(spacing: 16) {
            if let previous = model.voiceNotes
                .previousEntryID(before: section.entryID) {
                Button {
                    move(note: note, from: section.entryID)
                } label: {
                    Label(moveLabel(previous), systemImage: "arrow.uturn.backward")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            Button(role: .destructive) {
                discard(note: note, from: section.entryID)
            } label: {
                Label("Discard", systemImage: "trash")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
    }

    private func moveLabel(_ previous: String) -> String {
        let name = model.libraryModel.entry(id: previous)?.name
        return name.map { "Move to \u{2018}\($0)\u{2019}" }
            ?? "Move to the previous preset"
    }

    // ------------------------------------------------------------- intents

    private func move(note: PresetNote, from entryID: String) {
        Task { @MainActor in
            await model.voiceNotes.moveToPreviousPreset(note: note,
                                                        from: entryID)
            resyncFromModel()
        }
    }

    private func discard(note: PresetNote, from entryID: String) {
        Task { @MainActor in
            await model.voiceNotes.discard(note: note, from: entryID)
            resyncFromModel()
        }
    }

    /// Rebuild the local sections from the model after a move or a discard,
    /// keeping the original visit order. Selections whose note is gone are
    /// dropped with it.
    private func resyncFromModel() {
        let captured = model.voiceNotes.captured
        sections = request.sections.compactMap { section in
            let notes = captured[section.entryID] ?? []
            guard !notes.isEmpty else { return nil }
            return NoteReviewRequest.Section(entryID: section.entryID,
                                             notes: notes)
        }
        let live = Set(sections.map(\.entryID))
        selected = selected.filter { live.contains($0.entryID) }
    }

    /// Apply commits through the EXISTING setters — `setVerdict`,
    /// `setCategory`, `addTag` — so every filter, census, Python consumer and
    /// .mfpreset export sees the result with no knowledge that a microphone
    /// was involved. The sidecar then records `accepted: true` and nothing
    /// more.
    private func apply() {
        guard !selected.isEmpty else {
            close()
            return
        }
        applying = true
        let work = selected
        Task { @MainActor in
            // Count what actually LANDED. Every accept path can early-return
            // (no app, no library) or swallow a write error into `failure`, so
            // reporting `work.count` regardless meant "Applied 3 note
            // suggestions" over three writes that never happened, followed by
            // a dismissal that took the evidence with it.
            var applied = 0
            var failed: [Key] = []
            for key in work.sorted(by: { $0.value < $1.value }) {
                let ok: Bool
                switch key.kind {
                case .verdict:
                    ok = await model.voiceNotes.acceptVerdict(
                        Verdict.fromSlug(key.value), for: key.entryID)
                case .category:
                    ok = await model.voiceNotes.acceptCategory(
                        FreakCore.Category.fromSlug(key.value), for: key.entryID)
                case .tag:
                    ok = await model.voiceNotes.acceptTag(key.value,
                                                          for: key.entryID)
                }
                if ok { applied += 1 } else { failed.append(key) }
            }
            applying = false
            if failed.isEmpty {
                model.toasts.show("Applied \(applied) note "
                    + "\(applied == 1 ? "suggestion" : "suggestions").")
                close()
            } else {
                // The sheet STAYS UP with the failures still ticked, so the
                // user can see what did not take and try again.
                selected = Set(failed)
                model.toasts.show("Applied \(applied) of \(work.count). "
                    + "\(failed.count) couldn't be saved — still ticked below.",
                    isError: true)
            }
        }
    }

    private func close() {
        model.voiceNotes.review = nil
        dismiss()
    }
}

// The entry id is taken from the preview's OWN library rather than hard-coded.
// With a made-up id `entry(id:)` returns nil, the section falls back to "Preset
// no longer in the library" and `if let entry` suppresses every chip — so the
// preview of a chip-picking sheet could not show a single chip.
#Preview("Note review") {
    PreviewHost { model in
        let entry = model.libraryModel.entries.first
        NoteReviewSheet(request: NoteReviewRequest(
            sessionID: "preview",
            sections: [
                NoteReviewRequest.Section(
                    entryID: entry?.id ?? "missing",
                    notes: [PresetNote.new(
                        source: .voice,
                        text: "this one is a really warm dark pad, keep it",
                        locale: "en-US", sessionID: "preview",
                        audioStart: 0, audioEnd: 3.2,
                        deviceIdentity: "practice:factoryFresh")])
            ]))
    }
}
