// NotesTests.swift — the notes/<entry_id>.json sidecar: the on-disk shape
// (docs/voice-notes.md §1, the interop surface the Python core must read
// byte-compatibly), the §1.2 forward-compatibility schema gate, the §1.3
// canonical order, the trust rules that keep `text` verbatim, and the two
// Library lifecycle hooks — remove() GCs an entry's sidecar, dedupe() MERGES
// the sidecars of the entries it collapses.
//
// The no-audio rule (§1.5) is asserted structurally: the exact key set of a
// written note is pinned, so a field that could hold audio or a path to audio
// cannot be added without this test failing.

import Foundation
import Testing
@testable import FreakCore

@Suite("PresetNote sidecar")
struct NotesTests {

    private func freshLibrary(_ tag: String) throws -> (Library, URL) {
        let root = tempDir("notes-\(tag)")
        return (try Library.create(at: root), root)
    }

    private func preset(_ name: String, _ seed: Int) throws -> Preset {
        try Preset(name: name, blob: blob7(seed), meta: testMeta)
    }

    /// A fully-populated note with EXPLICIT values, so the on-disk shape is
    /// asserted against something stable rather than against `isoNow()`.
    private func note(id: String, at recordedAt: String,
                      text: String = "nice dark pad, bit too noisy, keep",
                      source: NoteSource = .voice,
                      audioStart: Double = 12.48,
                      audioEnd: Double? = 15.92,
                      corrected: String? = nil,
                      session: String = "31d0b6c58f9e4a7d8b2c1e0f4a6d8b3c") -> PresetNote {
        PresetNote(id: id, recordedAt: recordedAt, source: source, text: text,
                   textCorrected: corrected, locale: "en-US", sessionID: session,
                   audioStart: audioStart, audioEnd: audioEnd,
                   deviceIdentity: "hardware",
                   proposals: NoteExtractor.extract(text))
    }

    private func readSidecar(_ root: URL, _ entryID: String) throws -> [String: Any]? {
        let url = root.appendingPathComponent("notes/\(entryID).json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONSerialization.jsonObject(with: try Data(contentsOf: url))
            as? [String: Any]
    }

    // -------------------------------------------------------- round-trip

    /// Append, read back, and check the file on disk against §1.3 / §1.4:
    /// snake_case keys, explicit nulls, the proposals object always present.
    @Test func sidecarRoundTrip() async throws {
        let (lib, root) = try freshLibrary("roundtrip")
        defer { try? FileManager.default.removeItem(at: root) }
        let entry = try await lib.add(try preset("Dusk", 1))

        #expect(try await lib.notes(entryID: entry.id).isEmpty,
                "a missing file means zero notes, never an error")
        #expect(try await lib.noteDocument(entryID: entry.id) == nil)

        let first = note(id: "9f2c4a1e7b0d4f6a8c3e5d7b9a1c2e4f", at: "2026-09-02T14:03:11")
        let stored = try await lib.appendNote(first, to: entry.id)
        #expect(stored.count == 1)
        #expect(stored[0] == first)

        // read back through the actor
        let read = try await lib.notes(entryID: entry.id)
        #expect(read == [first], "the note round-trips with no field loss")

        // ... and on disk
        let doc = try #require(try readSidecar(root, entry.id))
        #expect(doc["schema"] as? Int == 1)
        #expect(doc["entry_id"] as? String == entry.id)
        let notes = try #require(doc["notes"] as? [[String: Any]])
        #expect(notes.count == 1)
        let n = notes[0]

        // §1.5: the EXACT key set. No field here may ever hold audio or a path
        // to audio — this assertion is the guard.
        #expect(Set(n.keys) == [
            "id", "recorded_at", "source", "text", "text_corrected", "locale",
            "session_id", "audio_start", "audio_end", "device_identity",
            "proposals",
        ])
        #expect(n["id"] as? String == "9f2c4a1e7b0d4f6a8c3e5d7b9a1c2e4f")
        #expect(n["recorded_at"] as? String == "2026-09-02T14:03:11")
        #expect(n["source"] as? String == "voice")
        #expect(n["text"] as? String == "nice dark pad, bit too noisy, keep")
        #expect(n["text_corrected"] is NSNull, "explicit null, not an omitted key")
        #expect(n["locale"] as? String == "en-US")
        #expect(n["session_id"] as? String == "31d0b6c58f9e4a7d8b2c1e0f4a6d8b3c")
        #expect((n["audio_start"] as? NSNumber)?.doubleValue == 12.48)
        #expect((n["audio_end"] as? NSNumber)?.doubleValue == 15.92)
        #expect(n["device_identity"] as? String == "hardware")

        // §1.6: proposals is always an object with all three keys present
        let props = try #require(n["proposals"] as? [String: Any])
        #expect(Set(props.keys) == ["verdict", "category", "tags"])
        let verdict = try #require(props["verdict"] as? [String: Any])
        #expect(Set(verdict.keys) == ["value", "span", "confidence", "accepted"])
        #expect(verdict["value"] as? String == "keep")
        #expect(verdict["span"] as? [Int] == [30, 34])
        #expect((verdict["confidence"] as? NSNumber)?.doubleValue == 0.9)
        #expect(verdict["accepted"] as? Bool == false, "false at write time")
        #expect((props["category"] as? [String: Any])?["value"] as? String == "pad")
        let tags = try #require(props["tags"] as? [[String: Any]])
        #expect(tags.map { $0["value"] as? String } == ["Dark", "Noise"],
                "first-appearance order")
    }

    /// A typed note writes `audio_end: null` and an empty tags array, and a
    /// note with no proposals at all still writes the three keys.
    @Test func typedNoteAndEmptyProposals() async throws {
        let (lib, root) = try freshLibrary("typed")
        defer { try? FileManager.default.removeItem(at: root) }
        let entry = try await lib.add(try preset("Quiet", 2))
        try await lib.appendNote(
            note(id: "5b1e8d3c7a094f2b6d8e0c4a2f7b9d13", at: "2026-09-02T14:07:44",
                 text: "hmm okay", source: .typed, audioStart: 285.0, audioEnd: nil),
            to: entry.id)
        let n = try #require(try readSidecar(root, entry.id)?["notes"]
                                as? [[String: Any]]).first!
        #expect(n["source"] as? String == "typed")
        #expect(n["audio_end"] is NSNull, "null only for a typed note")
        let props = try #require(n["proposals"] as? [String: Any])
        #expect(props["verdict"] is NSNull)
        #expect(props["category"] is NSNull)
        #expect((props["tags"] as? [Any])?.isEmpty == true)
    }

    /// §1.3: ascending recorded_at, ties by audio_start, ties by id — written
    /// in that order however the caller appends.
    @Test func notesAreWrittenInCanonicalOrder() async throws {
        let (lib, root) = try freshLibrary("order")
        defer { try? FileManager.default.removeItem(at: root) }
        let entry = try await lib.add(try preset("Order", 3))
        // deliberately out of order, with a recorded_at tie and an id tie-break
        try await lib.appendNote(note(id: "cc", at: "2026-09-02T14:05:00",
                                      audioStart: 9), to: entry.id)
        try await lib.appendNote(note(id: "aa", at: "2026-09-02T14:03:00",
                                      audioStart: 3), to: entry.id)
        try await lib.appendNote(note(id: "bb", at: "2026-09-02T14:05:00",
                                      audioStart: 1), to: entry.id)
        try await lib.appendNote(note(id: "ab", at: "2026-09-02T14:05:00",
                                      audioStart: 1), to: entry.id)
        let ids = try await lib.notes(entryID: entry.id).map(\.id)
        #expect(ids == ["aa", "ab", "bb", "cc"])
    }

    /// replaceNotes is how "move to previous preset" and correction edits
    /// land; an empty list removes the file rather than leaving a husk.
    @Test func replaceAndEmptyReplaceDeletesTheFile() async throws {
        let (lib, root) = try freshLibrary("replace")
        defer { try? FileManager.default.removeItem(at: root) }
        let entry = try await lib.add(try preset("Replace", 4))
        try await lib.appendNote(note(id: "aa", at: "2026-09-02T14:03:00"), to: entry.id)
        try await lib.appendNote(note(id: "bb", at: "2026-09-02T14:04:00"), to: entry.id)

        let kept = try await lib.notes(entryID: entry.id).filter { $0.id == "bb" }
        try await lib.replaceNotes(kept, for: entry.id)
        #expect(try await lib.notes(entryID: entry.id).map(\.id) == ["bb"])

        try await lib.replaceNotes([], for: entry.id)
        #expect(try await lib.notes(entryID: entry.id).isEmpty)
        #expect(try readSidecar(root, entry.id) == nil, "no empty husk left behind")
    }

    // ------------------------------------------------------- trust rules

    /// §3 rule 1: `text` is verbatim and immutable; a correction is a SIBLING.
    /// §3 rule 3: accepting a proposal writes through the canonical setters,
    /// and the sidecar only records that it happened.
    @Test func correctionsAndAcceptanceNeverRewriteHistory() async throws {
        let (lib, root) = try freshLibrary("trust")
        defer { try? FileManager.default.removeItem(at: root) }
        let entry = try await lib.add(try preset("Trust", 5))
        let original = note(id: "aa", at: "2026-09-02T14:03:00")
        try await lib.appendNote(original, to: entry.id)

        let corrected = original.correcting("nice dark pad, bit too noisy, keep it")
        #expect(corrected.text == original.text, "text is never overwritten")
        #expect(corrected.textCorrected == "nice dark pad, bit too noisy, keep it")
        #expect(corrected.proposals == original.proposals)

        // the user taps the pre-aimed chip: the value goes to its CANONICAL
        // home first, and only then is `accepted` recorded
        let proposals = original.proposals
        let verdict = try #require(proposals.verdictValue)
        let updated = try await lib.setVerdict(id: entry.id, to: verdict)
        #expect(updated.verdict == .keep)
        let accepted = corrected.recordingAcceptance(NoteProposals(
            verdict: proposals.verdict?.accepting(),
            category: proposals.category,
            tags: proposals.tags))
        try await lib.replaceNotes([accepted], for: entry.id)

        let readBack = try await lib.notes(entryID: entry.id)[0]
        #expect(readBack.text == original.text)
        #expect(readBack.textCorrected == "nice dark pad, bit too noisy, keep it")
        #expect(readBack.proposals.verdict?.accepted == true)
        #expect(readBack.proposals.category?.accepted == false)
        // and the canonical home, not the sidecar, is what the library reports
        #expect(try await lib.entry(id: entry.id).verdict == .keep)
    }

    /// PresetNote.new mints the ids and runs the extractor for the caller.
    @Test func newMintsIdentityAndProposals() {
        let n = PresetNote.new(source: .voice, text: "decent pad, revisit",
                               locale: "en-US", sessionID: "abc",
                               audioStart: 1.2345, audioEnd: 4.5,
                               deviceIdentity: "practice:factoryFresh")
        #expect(n.id.count == 32)
        #expect(n.id.lowercased() == n.id)
        #expect(!n.id.contains("-"))
        #expect(n.recordedAt.count == 19, "yyyy-MM-dd'T'HH:mm:ss, no zone, no fraction")
        #expect(n.textCorrected == nil)
        #expect(n.proposals.verdictValue == .tryLater)
        #expect(n.proposals.categoryValue == .pad)
    }

    // ------------------------------------------------------- error paths

    @Test func writesRequireAnEntryAndReadsIgnoreOrphans() async throws {
        let (lib, root) = try freshLibrary("orphan")
        defer { try? FileManager.default.removeItem(at: root) }
        let ghost = "00000000000000000000000000000000"

        let e = await expectFreakErrorAsync("appendNote to an unknown entry", {
            try await lib.appendNote(note(id: "aa", at: "2026-09-02T14:03:00"), to: ghost)
        })
        guard case .entryNotFound = e else {
            Issue.record("expected .entryNotFound, got \(String(describing: e))")
            return
        }

        // an orphaned sidecar is IGNORED on read and never resurrected
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("notes"), withIntermediateDirectories: true)
        try AtomicFile.write(
            Data(#"{"schema": 1, "entry_id": "\#(ghost)", "notes": []}"#.utf8),
            to: root.appendingPathComponent("notes/\(ghost).json"))
        #expect(try await lib.notes(entryID: ghost).isEmpty)
        #expect(try await lib.noteDocument(entryID: ghost) == nil)
    }

    @Test func unparseableSidecarIsLibraryCorrupt() async throws {
        let (lib, root) = try freshLibrary("corrupt")
        defer { try? FileManager.default.removeItem(at: root) }
        let entry = try await lib.add(try preset("Corrupt", 6))
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("notes"), withIntermediateDirectories: true)
        let path = root.appendingPathComponent("notes/\(entry.id).json")

        try AtomicFile.write(Data("not json at all".utf8), to: path)
        guard case .libraryCorrupt = await expectFreakErrorAsync("unparseable sidecar", {
            try await lib.notes(entryID: entry.id)
        }) else {
            Issue.record("expected .libraryCorrupt for unparseable JSON")
            return
        }

        try AtomicFile.write(Data(#"{"schema": 0, "entry_id": "x", "notes": []}"#.utf8),
                             to: path)
        guard case .libraryCorrupt(_, let detail) = await expectFreakErrorAsync("schema 0", {
            try await lib.notes(entryID: entry.id)
        }) else {
            Issue.record("expected .libraryCorrupt for schema 0")
            return
        }
        #expect(detail.contains("unsupported schema"))
    }

    /// §1.2: a NEWER schema is readable but must never be rewritten. That gate
    /// is the whole protection against the §0 failure mode — a core silently
    /// destroying fields it does not understand — happening inside the sidecar.
    @Test func newerSchemaIsReadableButNeverRewritten() async throws {
        let (lib, root) = try freshLibrary("gate")
        defer { try? FileManager.default.removeItem(at: root) }
        let entry = try await lib.add(try preset("Future", 7))
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("notes"), withIntermediateDirectories: true)
        let path = root.appendingPathComponent("notes/\(entry.id).json")
        let future = """
        {"schema": 2, "entry_id": "\(entry.id)", "notes": [
          {"id": "aa", "recorded_at": "2026-09-02T14:03:00", "source": "voice",
           "text": "from the future", "text_corrected": null, "locale": "en-US",
           "session_id": "s", "audio_start": 1.0, "audio_end": 2.0,
           "device_identity": "hardware",
           "proposals": {"verdict": null, "category": null, "tags": []},
           "some_future_field": 42}
        ]}
        """
        try AtomicFile.write(Data(future.utf8), to: path)

        let doc = try #require(try await lib.noteDocument(entryID: entry.id))
        #expect(doc.schema == 2)
        #expect(doc.isReadOnly)
        #expect(doc.notes.map(\.text) == ["from the future"],
                "it may still DISPLAY the notes it understands")

        let refusals = [
            await expectFreakErrorAsync("appendNote onto a newer schema", {
                try await lib.appendNote(note(id: "bb", at: "2026-09-02T14:09:00"),
                                         to: entry.id)
            }),
            await expectFreakErrorAsync("replaceNotes onto a newer schema", {
                try await lib.replaceNotes([], for: entry.id)
            }),
        ]
        for e in refusals {
            guard case .integrity(_, let detail) = e else {
                Issue.record("expected .integrity, got \(String(describing: e))")
                continue
            }
            #expect(detail.contains("newer"))
        }
        // untouched on disk, unknown field and all
        let onDisk = try #require(try readSidecar(root, entry.id))
        #expect(onDisk["schema"] as? Int == 2)
        #expect(((onDisk["notes"] as? [[String: Any]])?.first?["some_future_field"]
                    as? NSNumber)?.intValue == 42)
    }

    // ------------------------------------------------------- lifecycle

    /// remove() takes the sidecar with it. The blob may survive (another entry
    /// shares it); the notes never do — they are keyed on THIS entry's id.
    @Test func removeGarbageCollectsTheSidecar() async throws {
        let (lib, root) = try freshLibrary("remove")
        defer { try? FileManager.default.removeItem(at: root) }
        let a = try await lib.add(try preset("Shared", 8))
        let b = try await lib.add(try preset("Shared other name", 8))   // same blob
        try await lib.appendNote(note(id: "aa", at: "2026-09-02T14:03:00"), to: a.id)
        try await lib.appendNote(note(id: "bb", at: "2026-09-02T14:04:00"), to: b.id)
        #expect(try readSidecar(root, a.id) != nil)

        try await lib.remove(id: a.id)
        #expect(try readSidecar(root, a.id) == nil, "the sidecar goes with the entry")
        #expect(try readSidecar(root, b.id) != nil, "the sibling's sidecar is untouched")
        #expect(await lib.hasBlob(a.sha256), "the shared blob still has a referent")

        try await lib.remove(id: b.id)
        #expect(try readSidecar(root, b.id) == nil)
        #expect(!(await lib.hasBlob(b.sha256)))
    }

    /// dedupe() merges the collapsed entries' notes into the survivor, in the
    /// §1.3 canonical order, and deletes the losers' files. Notes merge like
    /// tags, not like slots: two catalog rows for one (sha256, name) were
    /// always the same preset.
    @Test func dedupeMergesNoteArrays() async throws {
        let (lib, root) = try freshLibrary("dedupe")
        defer { try? FileManager.default.removeItem(at: root) }
        let p = try preset("Twin", 9)
        let a = try await lib.add(p)
        let b = try await lib.add(p)
        let c = try await lib.add(p)
        let other = try await lib.add(try preset("Alone", 10))
        try await lib.appendNote(note(id: "a1", at: "2026-09-02T14:05:00"), to: a.id)
        try await lib.appendNote(note(id: "b1", at: "2026-09-02T14:03:00"), to: b.id)
        try await lib.appendNote(note(id: "b2", at: "2026-09-02T14:09:00"), to: b.id)
        try await lib.appendNote(note(id: "c1", at: "2026-09-02T14:07:00"), to: c.id)
        try await lib.appendNote(note(id: "o1", at: "2026-09-02T14:01:00"), to: other.id)

        #expect(try await lib.dedupe() == 2)

        // the survivor is the FIRST of the group and now holds every note
        #expect(try await lib.notes(entryID: a.id).map(\.id) == ["b1", "a1", "c1", "b2"],
                "concatenated, then re-sorted by recorded_at")
        #expect(try readSidecar(root, b.id) == nil, "the losers' files are gone")
        #expect(try readSidecar(root, c.id) == nil)
        // an un-collapsed entry is untouched
        #expect(try await lib.notes(entryID: other.id).map(\.id) == ["o1"])
        // and nothing was invented: every merged note kept its text verbatim
        #expect(try await lib.notes(entryID: a.id).allSatisfy {
            $0.text == "nice dark pad, bit too noisy, keep"
        })
    }

    /// The one refusal: a newer-schema sidecar anywhere in a collapsing group
    /// leaves EVERY file in that group alone. An unreachable-but-intact
    /// sidecar beats one this core rewrote lossily.
    @Test func dedupeLeavesANewerSchemaGroupAlone() async throws {
        let (lib, root) = try freshLibrary("dedupe-gate")
        defer { try? FileManager.default.removeItem(at: root) }
        let p = try preset("Twin", 11)
        let a = try await lib.add(p)
        let b = try await lib.add(p)
        try await lib.appendNote(note(id: "a1", at: "2026-09-02T14:05:00"), to: a.id)
        try AtomicFile.write(
            Data(#"{"schema": 7, "entry_id": "\#(b.id)", "notes": []}"#.utf8),
            to: root.appendingPathComponent("notes/\(b.id).json"))

        #expect(try await lib.dedupe() == 1)
        #expect(try await lib.notes(entryID: a.id).map(\.id) == ["a1"],
                "the survivor's file was not rewritten")
        #expect(try readSidecar(root, b.id)?["schema"] as? Int == 7,
                "the newer file was not destroyed either")
    }

    /// mergeBundle needs nothing: a seed bundle ships blobs and collections
    /// only, the merge mints fresh entry ids, and no sidecar can ride along.
    @Test func mergeBundleCarriesNoNotes() async throws {
        let (seed, seedRoot) = try freshLibrary("bundle-seed")
        let (dest, destRoot) = try freshLibrary("bundle-dest")
        defer {
            try? FileManager.default.removeItem(at: seedRoot)
            try? FileManager.default.removeItem(at: destRoot)
        }
        let p = try preset("Seeded", 12)
        let seedEntry = try await seed.add(p)
        let ref = try await seed.storePreset(p)
        try await seed.saveCollection(
            PresetCollection.new(name: "Seed Bank",
                                 provenance: Provenance(kind: .importedBank, source: "seed"),
                                 slots: [0: ref]))
        // a seed would never carry one; write one anyway to prove the merge
        // cannot pick it up
        try await seed.appendNote(note(id: "s1", at: "2026-09-02T14:03:00"),
                                  to: seedEntry.id)

        #expect(try await dest.mergeBundle(from: seed) == 1)
        #expect(try await dest.collections().count == 1)
        #expect(await dest.entries().count == 1)
        #expect(!FileManager.default.fileExists(
                    atPath: destRoot.appendingPathComponent("notes").path),
                "the destination has no notes/ directory at all")
        let merged = try #require(await dest.entries().first)
        #expect(merged.id != seedEntry.id, "the merge mints its own entry id")
        #expect(try await dest.notes(entryID: merged.id).isEmpty)
    }

    // ----------------------------------------------------------- codec

    /// NoteCodec is symmetric on its own, independent of the file system.
    @Test func codecRoundTrip() throws {
        let doc = NoteDocument(entryID: "c78e5cd14acb49b1bf08b66d609a714a", notes: [
            note(id: "aa", at: "2026-09-02T14:03:11"),
            note(id: "bb", at: "2026-09-02T14:07:44", text: "revisit with the filter opened up",
                 source: .typed, audioStart: 285.0, audioEnd: nil,
                 corrected: "revisit with the filter opened up more"),
        ])
        let json = NoteCodec.toJSON(doc)
        let data = try jsonData(json)
        let reparsed = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let back = try NoteCodec.fromJSON(reparsed, path: "<test>")
        #expect(back == doc)
        #expect(back.schema == 1)
        #expect(!back.isReadOnly)
        #expect(back.notes[1].textCorrected == "revisit with the filter opened up more")
        #expect(back.notes[1].audioEnd == nil)
        #expect(back.notes[1].proposals.verdict?.value == "try_later")
    }

    /// audio offsets are written with at most 3 decimal places (§1.5), and
    /// every number is written in its SHORTEST round-trip form so a
    /// Swift-vs-Python sidecar diff is readable — a bare Double would
    /// serialize the 0.9 confidence tier as 0.90000000000000002.
    @Test func numbersAreRoundedAndWrittenShort() throws {
        let n = note(id: "aa", at: "2026-09-02T14:03:11",
                     audioStart: 12.4812345, audioEnd: 15.9199999)
        let json = NoteCodec.noteToJSON(n)
        let text = try #require(String(data: try jsonData(json), encoding: .utf8))
        #expect(text.contains("\"audio_start\" : 12.481"))
        #expect(text.contains("\"audio_end\" : 15.92"))
        #expect(text.contains("\"confidence\" : 0.9"))
        #expect(!text.contains("0.90000000000000002"))

        // shortest form is not lossy: the values parse back BIT-EXACT, which
        // is what the round trip through the file actually does
        let reparsed = try #require(
            try JSONSerialization.jsonObject(with: try jsonData(json)) as? [String: Any])
        #expect((reparsed["audio_start"] as? NSNumber)?.doubleValue == 12.481)
        #expect((reparsed["audio_end"] as? NSNumber)?.doubleValue == 15.92)
        let back = try #require(NoteCodec.proposalFromJSON(
            (reparsed["proposals"] as? [String: Any])?["verdict"] as? [String: Any]))
        #expect(back.confidence == 0.9)
    }

    /// The rounded VALUE must be the one Python's `round(x, 3)` produces, not
    /// merely something with three decimals.
    ///
    /// Scaling first (`(x * 1000).rounded(.toNearestOrEven) / 1000`) breaks a
    /// tie that the true binary value does not have: 0.0685 — frame 3288 at
    /// 48 kHz, an ordinary audio-clock reading — is really
    /// 0.068500000000000005 and rounds UP, but the scaled product lands on
    /// exactly 68.5 and banker's rounding took it DOWN. The two cores then
    /// wrote different numbers for the same note, in opposite directions on
    /// audio_start and audio_end.
    @Test func roundingAgreesWithPythonsRound() {
        #expect(roundTo(0.0685, places: 3) == 0.069)      // was 0.068
        #expect(roundTo(0.2055, places: 3) == 0.205)      // was 0.206
        #expect(roundTo(3288.0 / 48_000.0, places: 3) == 0.069)
        // the genuine half-to-even cases still round to even
        #expect(roundTo(2.25, places: 1) == 2.2)
        #expect(roundTo(2.35, places: 1) == 2.4)
        #expect(roundTo(12.4812345, places: 3) == 12.481)
        #expect(roundTo(0, places: 3) == 0)
    }

    /// A malformed sidecar falls back exactly where the Python core falls
    /// back. `[1.5, 3.5]` is not a span and `true` is not a number of seconds;
    /// silently truncating them made the two cores read the same bytes
    /// differently.
    @Test func malformedNumbersFallBackTheWayPythonDoes() throws {
        let bad: [String: Any] = [
            "schema": 1, "entry_id": "e",
            "notes": [[
                "id": "a", "text": "dark pad, keep it",
                "audio_start": "oops", "audio_end": true,
                "proposals": ["verdict": ["value": "keep", "span": [1.5, 3.5],
                                          "confidence": true, "accepted": false],
                              "category": NSNull(), "tags": []],
            ]],
        ]
        let doc = try NoteCodec.fromJSON(bad, path: "<test>")
        let n = try #require(doc.notes.first)
        #expect(n.audioStart == 0)
        #expect(n.audioEnd == nil)
        let v = try #require(n.proposals.verdict)
        #expect(v.spanStart == 0 && v.spanEnd == 0)
        #expect(v.confidence == 0)
        // a (0, 0) span addresses nothing, so nothing is underlined
        #expect(v.span(in: n.text) == nil)
    }

    // ------------------------------------------- atomic read-modify-write

    /// `notes()` then `replaceNotes()` is two hops with a suspension between
    /// them; a note appended in the gap is read by nobody and overwritten by
    /// the stale list. `mutateNotes` closes the gap inside the actor.
    @Test func mutateNotesIsIndivisible() async throws {
        let (lib, root) = try freshLibrary("mutate")
        defer { try? FileManager.default.removeItem(at: root) }
        let entry = try await lib.add(try preset("Dusk", 1))
        try await lib.appendNote(note(id: "n1", at: "2026-09-02T10:00:00"),
                                 to: entry.id)

        // The append and the acceptance race; neither may lose the other.
        async let accept: Void = {
            _ = try await lib.mutateNotes(entryID: entry.id) { notes in
                notes.map { $0.recordingAcceptance(
                    NoteProposals(verdict: $0.proposals.verdict?.accepting(),
                                  category: $0.proposals.category,
                                  tags: $0.proposals.tags)) }
            }
        }()
        async let append: Void = {
            _ = try await lib.appendNote(
                note(id: "n2", at: "2026-09-02T11:00:00",
                     text: "this next one is a bright lead"),
                to: entry.id)
        }()
        _ = try await (accept, append)

        let after = try await lib.notes(entryID: entry.id)
        #expect(after.map(\.id).sorted() == ["n1", "n2"])
    }

    /// The move appends to the destination FIRST. A destination that cannot be
    /// written must leave the note where it was rather than consuming it — the
    /// verbatim text is the only copy that ever existed (§1.5).
    @Test func moveNoteAppendsBeforeItRemoves() async throws {
        let (lib, root) = try freshLibrary("move")
        defer { try? FileManager.default.removeItem(at: root) }
        let a = try await lib.add(try preset("A", 1))
        let b = try await lib.add(try preset("B", 2))
        try await lib.appendNote(note(id: "n1", at: "2026-09-02T10:00:00"),
                                 to: b.id)

        // a destination that does not exist: the note must survive in place
        await #expect(throws: (any Error).self) {
            _ = try await lib.moveNote(id: "n1", from: b.id, to: "deadbeef")
        }
        #expect(try await lib.notes(entryID: b.id).map(\.id) == ["n1"])

        let moved = try await lib.moveNote(id: "n1", from: b.id, to: a.id)
        #expect(moved?.id == "n1")
        #expect(try await lib.notes(entryID: b.id).isEmpty)
        #expect(try await lib.notes(entryID: a.id).map(\.id) == ["n1"])
        // session-relative offsets are untouched by a move
        #expect(try await lib.notes(entryID: a.id).first?.audioStart == 12.48)
        // a note that is not there is not an error
        #expect(try await lib.moveNote(id: "nope", from: b.id, to: a.id) == nil)
    }

    @Test func removeNoteDropsExactlyOne() async throws {
        let (lib, root) = try freshLibrary("removenote")
        defer { try? FileManager.default.removeItem(at: root) }
        let e = try await lib.add(try preset("A", 1))
        try await lib.appendNote(note(id: "n1", at: "2026-09-02T10:00:00"), to: e.id)
        try await lib.appendNote(note(id: "n2", at: "2026-09-02T11:00:00"), to: e.id)
        _ = try await lib.removeNote(id: "n1", from: e.id)
        #expect(try await lib.notes(entryID: e.id).map(\.id) == ["n2"])
        _ = try await lib.removeNote(id: "n1", from: e.id)      // idempotent
        #expect(try await lib.notes(entryID: e.id).map(\.id) == ["n2"])
    }
}
