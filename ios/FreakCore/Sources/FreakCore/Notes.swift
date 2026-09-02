// Notes.swift — PresetNote: a spoken or typed note about ONE library entry,
// stored in a per-entry sidecar file. Pinned by docs/voice-notes.md §1; the
// Python core carries the identical format.
//
//     <root>/
//       index.json
//       blobs/<sha256>.bin
//       collections/<collection id>.json
//       notes/<entry id>.json          <-- this file's format
//
// WHY A SIDECAR AND NOT A FIELD ON LibraryEntry (§0): the Python
// `microfreak/library.py::_entry_to_json` builds a FIXED dict and every Python
// write path rewrites EVERY entry through it. A `note` field on LibraryEntry
// would be silently destroyed — no error, no diff, just gone — the first time
// any Python tooling touched the library. A separate file per entry, mirroring
// the existing collections/<id>.json precedent, is what whole-index rewrites
// cannot reach. Keyed on `entry.id` (uuid4 hex): it is minted at add(),
// survives rename (unlike `name`/`slot`) and is unique (unlike `sha256`, which
// two entries may share).
//
// THE TRUST RULES (§3), which this file exists to keep:
//
//   1. `text` is VERBATIM and IMMUTABLE. What the transcriber finalized is
//      what is stored, forever — never cleaned, re-cased, punctuation-fixed or
//      regenerated. A user correction is the SIBLING `textCorrected`; the
//      original stays, which is the only way a user can tell a mishearing from
//      a mistake they made.
//   2. Proposals are ADVISORY. The extractor writes into `proposals` and
//      nowhere else; a transcript never changes a preset attribute on its own.
//   3. The sidecar is PROVENANCE, never a second source of truth. An accepted
//      proposal is written to its canonical home through the existing setters
//      (setVerdict / setCategory / setTags), so every filter, census, Python
//      consumer and .mfpreset export sees it unchanged. NO READER ANYWHERE MAY
//      CONSULT notes/ TO DETERMINE AN ENTRY'S VERDICT, CATEGORY OR TAGS. Delete
//      notes/ and the library is exactly as correct as before; only the
//      provenance is gone.
//
// AND THE NO-AUDIO RULE (§1.5): NO RAW AUDIO IS EVER WRITTEN TO DISK. Not a
// temp file, not a ring buffer, not a debug build. `audioStart`/`audioEnd` are
// session-relative SECONDS on the capture clock — a timeline offset, never a
// pointer. There is no file they name and no file they could name. No field
// here may ever hold audio or a path to audio.

import Foundation

let noteSchema = 1

// ------------------------------------------------------------------- source

/// How a note was captured. Exactly these two values in schema 1.
public enum NoteSource: String, Sendable, Codable, Equatable, CaseIterable {
    case voice
    case typed

    /// Parse a file value. Unknown -> .voice (forward compatibility, the same
    /// idiom as `ProvenanceKind.fromString`); a document carrying an unknown
    /// source is a newer schema, which the §1.2 gate already makes read-only.
    public static func fromString(_ s: String) -> NoteSource {
        NoteSource(rawValue: s) ?? .voice
    }
}

// ---------------------------------------------------------------- proposals

/// One advisory extraction hit (§1.6). `value` is drawn from a CLOSED set —
/// `Verdict.slug`, `Category.slug`, or one of the 18 exact Arturia
/// characteristic display strings — because the extractor is table-driven and
/// can never invent a value.
public struct NoteProposal: Sendable, Equatable {
    public let value: String
    /// `[spanStart, spanEnd)` Unicode scalar (code point) offsets into the
    /// VERBATIM `text` — not the normalized form, and not `textCorrected`.
    public let spanStart: Int
    public let spanEnd: Int
    /// A match-strength tier from the fixed §2.8 table, in [0, 1]. Not a
    /// probability, and never from a model.
    public let confidence: Double
    /// `false` at write time. Becomes `true` at the moment the user taps to
    /// confirm AND the canonical setter succeeds. NEVER flipped back: a later
    /// user change to the entry does not rewrite history here. It records what
    /// the user confirmed, not what the entry currently says.
    public let accepted: Bool

    public init(value: String, spanStart: Int, spanEnd: Int,
                confidence: Double, accepted: Bool = false) {
        self.value = value
        self.spanStart = spanStart
        self.spanEnd = spanEnd
        self.confidence = confidence
        self.accepted = accepted
    }

    /// Copy with `accepted` set — the only field a caller may change.
    public func accepting(_ accepted: Bool = true) -> NoteProposal {
        NoteProposal(value: value, spanStart: spanStart, spanEnd: spanEnd,
                     confidence: confidence, accepted: accepted)
    }

    /// The proposal's slice of a verbatim string, or nil when the span does
    /// not address it (a corrected text, a foreign file).
    public func span(in text: String) -> String? {
        let scalars = Array(text.unicodeScalars)
        guard spanStart >= 0, spanEnd <= scalars.count, spanStart < spanEnd else {
            return nil
        }
        var view = String.UnicodeScalarView()
        view.append(contentsOf: scalars[spanStart..<spanEnd])
        return String(view)
    }
}

/// The whole advisory layer for one note (§1.6). Always present, never null:
/// `verdict` and `category` are single-valued (a proposal or nil); `tags` is
/// always an array, unique by value and ordered by FIRST APPEARANCE in `text`.
public struct NoteProposals: Sendable, Equatable {
    public let verdict: NoteProposal?
    public let category: NoteProposal?
    public let tags: [NoteProposal]

    public init(verdict: NoteProposal? = nil, category: NoteProposal? = nil,
                tags: [NoteProposal] = []) {
        self.verdict = verdict
        self.category = category
        self.tags = tags
    }

    public static let empty = NoteProposals()

    public var isEmpty: Bool { verdict == nil && category == nil && tags.isEmpty }

    /// The proposed verdict as the core type. `unrated` is never proposed, so
    /// a value that does not parse yields nil rather than a false `.unrated`.
    public var verdictValue: Verdict? {
        guard let verdict else { return nil }
        let parsed = Verdict.fromSlug(verdict.value)
        return parsed == .unrated ? nil : parsed
    }

    /// The proposed category as the core type. `uncategorized` is never
    /// proposed, so an unparseable value yields nil.
    public var categoryValue: Category? {
        guard let category else { return nil }
        let parsed = Category.fromSlug(category.value)
        return parsed == .uncategorized ? nil : parsed
    }

    /// The proposed characteristics, first-appearance order.
    public var tagValues: [String] { tags.map(\.value) }
}

// -------------------------------------------------------------------- note

public struct PresetNote: Sendable, Equatable, Identifiable {
    /// uuid4 hex — lowercase, 32 chars, NO hyphens.
    public let id: String
    /// "yyyy-MM-dd'T'HH:mm:ss", LOCAL time, no zone suffix, no fractional
    /// seconds — byte-identical in shape to `added_at` / `created_at`.
    public let recordedAt: String
    public let source: NoteSource
    /// VERBATIM and IMMUTABLE (§3 rule 1).
    public let text: String
    /// A user correction. Explicitly nil when the user has not corrected it;
    /// `text` is never overwritten.
    public let textCorrected: String?
    /// BCP-47 identifier of the transcriber locale, e.g. "en-US". For a typed
    /// note, the app's current locale.
    public let locale: String
    /// uuid4 hex; one value per audition session, shared by every note
    /// captured in it.
    public let sessionID: String
    /// Seconds, SESSION-RELATIVE. A timeline offset, never a pointer to audio.
    public let audioStart: Double
    /// Seconds, session-relative. nil only for a typed note: a voice note is
    /// only persisted from a finalized result, which always carries a
    /// complete range.
    public let audioEnd: Double?
    /// `DeviceIdentity.stamp`: "hardware", "practice:<profile>", or "none".
    /// A plain string here — the identity type lives in the app layer.
    public let deviceIdentity: String
    public let proposals: NoteProposals

    public init(id: String, recordedAt: String, source: NoteSource,
                text: String, textCorrected: String? = nil,
                locale: String, sessionID: String,
                audioStart: Double, audioEnd: Double?,
                deviceIdentity: String,
                proposals: NoteProposals = .empty) {
        self.id = id
        self.recordedAt = recordedAt
        self.source = source
        self.text = text
        self.textCorrected = textCorrected
        self.locale = locale
        self.sessionID = sessionID
        self.audioStart = audioStart
        self.audioEnd = audioEnd
        self.deviceIdentity = deviceIdentity
        self.proposals = proposals
    }

    /// Mint a fresh note: uuid4 hex id, local ISO `recordedAt`, and — unless
    /// the caller supplies its own — proposals extracted from `text` by
    /// `NoteExtractor` under `locale`.
    public static func new(source: NoteSource, text: String, locale: String,
                           sessionID: String, audioStart: Double,
                           audioEnd: Double?, deviceIdentity: String,
                           proposals: NoteProposals? = nil) -> PresetNote {
        PresetNote(
            id: UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased(),
            recordedAt: isoNow(), source: source, text: text,
            textCorrected: nil, locale: locale, sessionID: sessionID,
            audioStart: audioStart, audioEnd: audioEnd,
            deviceIdentity: deviceIdentity,
            proposals: proposals ?? NoteExtractor.extract(text, locale: locale))
    }

    /// Attach (or clear) a user correction. `text` is untouched — that is the
    /// point of the field.
    public func correcting(_ corrected: String?) -> PresetNote {
        PresetNote(id: id, recordedAt: recordedAt, source: source, text: text,
                   textCorrected: corrected, locale: locale, sessionID: sessionID,
                   audioStart: audioStart, audioEnd: audioEnd,
                   deviceIdentity: deviceIdentity, proposals: proposals)
    }

    /// Record that the user confirmed proposals — after the canonical setter
    /// succeeded. Nothing else about the note changes.
    public func recordingAcceptance(_ proposals: NoteProposals) -> PresetNote {
        PresetNote(id: id, recordedAt: recordedAt, source: source, text: text,
                   textCorrected: textCorrected, locale: locale,
                   sessionID: sessionID, audioStart: audioStart,
                   audioEnd: audioEnd, deviceIdentity: deviceIdentity,
                   proposals: proposals)
    }

    /// The §1.3 canonical order both cores write: ascending by `recordedAt`,
    /// ties by `audioStart`, ties by `id` lexicographically. Readers may rely
    /// on it.
    public static func canonicalOrder(_ notes: [PresetNote]) -> [PresetNote] {
        notes.sorted { a, b in
            if a.recordedAt != b.recordedAt { return a.recordedAt < b.recordedAt }
            if a.audioStart != b.audioStart { return a.audioStart < b.audioStart }
            return a.id < b.id
        }
    }
}

// ---------------------------------------------------------------- document

/// One `notes/<entry_id>.json` file (§1.3).
public struct NoteDocument: Sendable, Equatable {
    /// The schema version READ FROM DISK — not necessarily this core's.
    public let schema: Int
    public let entryID: String
    public let notes: [PresetNote]

    public init(schema: Int = NoteDocument.currentSchema,
                entryID: String, notes: [PresetNote]) {
        self.schema = schema
        self.entryID = entryID
        self.notes = notes
    }

    public static let currentSchema = noteSchema

    /// §1.2, the forward-compatibility gate: a core reading a sidecar whose
    /// schema is GREATER than the version it knows must treat that file as
    /// read-only. It may display the notes it understands; it MUST NOT rewrite
    /// the file. That gate is the whole protection against the §0 failure mode
    /// happening again inside the sidecar, and it is what makes it safe not to
    /// round-trip unknown keys.
    public var isReadOnly: Bool { schema > NoteDocument.currentSchema }
}

// ------------------------------------------------------------------- codec

/// Mirrors `CollectionCodec`: a plain dictionary in, a value type out.
enum NoteCodec {

    /// JSONSerialization renders a bare `Double` with 17 significant digits —
    /// `0.9` becomes `0.90000000000000002` — which re-parses to exactly the
    /// same value but would make a Swift-vs-Python sidecar diff unreadable on
    /// every single proposal. Swift's own shortest round-trip description is
    /// what Python's `repr` writes, so the number is routed through a
    /// POSIX-parsed decimal. The SERIALIZED text is exact — it parses back
    /// bit-identical — but the intermediate `NSDecimalNumber`'s own
    /// `doubleValue` can sit an ULP away (12.481 reads as 12.480999999999998),
    /// so read a value back from PARSED JSON, never from a `toJSON` dictionary.
    static func number(_ x: Double) -> NSNumber {
        guard x.isFinite else { return NSNumber(value: 0) }
        return NSDecimalNumber(string: String(x), locale: Locale(identifier: "en_US_POSIX"))
    }

    static func toJSON(_ doc: NoteDocument) -> [String: Any] {
        [
            "schema": doc.schema,
            "entry_id": doc.entryID,
            "notes": doc.notes.map(noteToJSON),
        ]
    }

    static func noteToJSON(_ n: PresetNote) -> [String: Any] {
        [
            "id": n.id,
            "recorded_at": n.recordedAt,
            "source": n.source.rawValue,
            "text": n.text,
            // explicit null, the way index.json writes "slot": null
            "text_corrected": n.textCorrected.map { $0 as Any } ?? NSNull(),
            "locale": n.locale,
            "session_id": n.sessionID,
            // at most 3 decimal places (§1.5)
            "audio_start": number(roundTo(n.audioStart, places: 3)),
            "audio_end": n.audioEnd.map { number(roundTo($0, places: 3)) as Any } ?? NSNull(),
            "device_identity": n.deviceIdentity,
            "proposals": proposalsToJSON(n.proposals),
        ]
    }

    static func proposalsToJSON(_ p: NoteProposals) -> [String: Any] {
        [
            "verdict": p.verdict.map { proposalToJSON($0) as Any } ?? NSNull(),
            "category": p.category.map { proposalToJSON($0) as Any } ?? NSNull(),
            "tags": p.tags.map(proposalToJSON),
        ]
    }

    static func proposalToJSON(_ p: NoteProposal) -> [String: Any] {
        ["value": p.value, "span": [p.spanStart, p.spanEnd],
         "confidence": number(p.confidence), "accepted": p.accepted]
    }

    /// Parse a sidecar document. Unparseable -> .libraryCorrupt(path:detail:),
    /// the same error the collection reader raises (§1.1).
    ///
    /// A schema GREATER than this core's is NOT an error (§1.2): it parses to
    /// a document whose `isReadOnly` is true, which the write path refuses to
    /// overwrite.
    static func fromJSON(_ d: [String: Any], path: String) throws -> NoteDocument {
        guard let schema = (d["schema"] as? NSNumber)?.intValue, schema >= 1 else {
            throw FreakError.libraryCorrupt(
                path: path, detail: "unsupported schema: \(d["schema"] ?? "nil")")
        }
        guard let entryID = d["entry_id"] as? String else {
            throw FreakError.libraryCorrupt(path: path, detail: "bad notes: missing entry_id")
        }
        guard let rawNotes = d["notes"] as? [Any] else {
            throw FreakError.libraryCorrupt(path: path, detail: "bad notes: missing notes array")
        }
        var notes: [PresetNote] = []
        for raw in rawNotes {
            guard let nd = raw as? [String: Any],
                  let id = nd["id"] as? String,
                  let text = nd["text"] as? String else {
                throw FreakError.libraryCorrupt(path: path, detail: "bad note: \(raw)")
            }
            notes.append(PresetNote(
                id: id,
                recordedAt: nd["recorded_at"] as? String ?? "",
                source: NoteSource.fromString(nd["source"] as? String ?? "voice"),
                text: text,
                textCorrected: nd["text_corrected"] as? String,
                locale: nd["locale"] as? String ?? "",
                sessionID: nd["session_id"] as? String ?? "",
                audioStart: seconds(nd["audio_start"]) ?? 0,
                audioEnd: seconds(nd["audio_end"]),
                deviceIdentity: nd["device_identity"] as? String ?? "none",
                proposals: proposalsFromJSON(nd["proposals"] as? [String: Any] ?? [:])))
        }
        return NoteDocument(schema: schema, entryID: entryID, notes: notes)
    }

    static func proposalsFromJSON(_ d: [String: Any]) -> NoteProposals {
        NoteProposals(
            verdict: proposalFromJSON(d["verdict"] as? [String: Any]),
            category: proposalFromJSON(d["category"] as? [String: Any]),
            tags: (d["tags"] as? [Any] ?? []).compactMap {
                proposalFromJSON($0 as? [String: Any])
            })
    }

    static func proposalFromJSON(_ d: [String: Any]?) -> NoteProposal? {
        guard let d, let value = d["value"] as? String else { return nil }
        let span = (d["span"] as? [Any] ?? []).compactMap(spanInteger)
        return NoteProposal(
            value: value,
            spanStart: span.count == 2 ? span[0] : 0,
            spanEnd: span.count == 2 ? span[1] : 0,
            confidence: seconds(d["confidence"]) ?? 0,
            accepted: (d["accepted"] as? NSNumber)?.boolValue ?? false)
    }

    /// A numeric field, or nil when the file does not hold a number there.
    ///
    /// Anything unparseable FALLS BACK rather than throwing — `id` and `text`
    /// are the only required keys (§1.4) — and it falls back to exactly what
    /// `microfreak/notes.py::_seconds` falls back to, booleans included: JSON
    /// `true` is not 1.0 seconds in either core.
    static func seconds(_ any: Any?) -> Double? {
        guard let any, let n = any as? NSNumber, !isBoolean(n) else { return nil }
        let d = n.doubleValue
        return d.isFinite ? d : nil
    }

    /// JSONSerialization hands back the shared CFBoolean singletons for
    /// true/false; their objCType is "c", indistinguishable from a small
    /// integer, so identity is the only reliable test.
    private static func isBoolean(_ n: NSNumber) -> Bool {
        n === (kCFBooleanTrue as NSNumber) || n === (kCFBooleanFalse as NSNumber)
    }

    /// A span endpoint, or nil when the file does not hold an INTEGER there.
    ///
    /// Strict on purpose, and strict in the same way the Python core is
    /// (`microfreak/notes.py::_proposal_from_json`). A span is a pair of code
    /// point offsets; `[1.5, 3.5]` and `[true, false]` are not offsets, and
    /// truncating them — which `NSNumber.intValue` does silently — made the
    /// two cores disagree about the same malformed file (Swift read (1, 3),
    /// Python read (0, 0)). Both now fall back to (0, 0), which `span(in:)`
    /// rejects as un-addressable rather than underlining the wrong words.
    private static func spanInteger(_ any: Any) -> Int? {
        guard let n = any as? NSNumber, !isBoolean(n) else { return nil }
        switch String(cString: n.objCType) {
        case "f", "d":                      // float / double — not an offset
            return nil
        default:
            return n.intValue
        }
    }
}

// ------------------------------------------------------------ Library store

public extension Library {

    /// `<root>/notes` — created lazily on first write (§1.1).
    nonisolated func notesDir() -> URL {
        root.appendingPathComponent("notes")
    }

    nonisolated func notePath(_ entryID: String) -> URL {
        notesDir().appendingPathComponent("\(entryID).json")
    }

    /// The notes attached to one entry, in the §1.3 canonical order they were
    /// written in. A MISSING FILE MEANS ZERO NOTES and is never an error; an
    /// unparseable one throws .libraryCorrupt. A sidecar whose entry no longer
    /// exists is IGNORED (it is never resurrected), so this returns [] for an
    /// unknown id rather than throwing.
    func notes(entryID: String) throws -> [PresetNote] {
        try noteDocument(entryID: entryID)?.notes ?? []
    }

    /// The whole sidecar document, or nil when there is no file. Callers that
    /// care about the §1.2 schema gate — "can I still write to this?" — read
    /// `isReadOnly` here.
    func noteDocument(entryID: String) throws -> NoteDocument? {
        guard (try? entry(id: entryID)) != nil else { return nil }
        return try loadNoteDocument(entryID: entryID)
    }

    /// Append one note. The file is rewritten atomically in canonical order.
    /// Throws .entryNotFound for an unknown entry (a sidecar with no entry is
    /// garbage by construction) and .integrity when the existing file carries
    /// a NEWER schema than this core understands (§1.2).
    @discardableResult
    func appendNote(_ note: PresetNote, to entryID: String) throws -> [PresetNote] {
        let existing = try notesForWriting(entryID: entryID)
        return try writeNotes(existing + [note], entryID: entryID)
    }

    /// Replace the whole note list for an entry (the "move to previous preset"
    /// half of §4, and correction/acceptance edits). An empty list DELETES the
    /// sidecar rather than leaving an empty document behind.
    @discardableResult
    func replaceNotes(_ notes: [PresetNote], for entryID: String) throws -> [PresetNote] {
        _ = try notesForWriting(entryID: entryID)
        return try writeNotes(notes, entryID: entryID)
    }

    // ------------------------------------------------ atomic read-modify-write
    //
    // WHY THESE EXIST AT ALL. `notes(entryID:)` followed by
    // `replaceNotes(_:for:)` is TWO actor hops with a suspension between them.
    // Anything that lands in the gap — most obviously a `appendNote` for an
    // utterance the transcriber finalized a moment ago — is read by nobody and
    // then overwritten by the stale list the caller is still holding. The note
    // is gone from the file with no throw and no diagnostic, and because the
    // §1.5 no-audio rule means the verbatim transcript was the only copy that
    // ever existed, it is gone for good.
    //
    // Every mutation below does its read and its write inside ONE actor-
    // isolated, non-suspending call, so the pair cannot be split. Callers must
    // use these rather than reading, mapping and replacing themselves.

    /// Read, transform and rewrite an entry's notes as one indivisible step.
    /// The transform runs on the actor and must not suspend.
    @discardableResult
    func mutateNotes(entryID: String,
                     _ transform: @Sendable ([PresetNote]) -> [PresetNote]) throws -> [PresetNote] {
        let existing = try notesForWriting(entryID: entryID)
        return try writeNotes(transform(existing), entryID: entryID)
    }

    /// Drop one note by id. Returns the surviving notes; a note that was never
    /// there is not an error.
    @discardableResult
    func removeNote(id: String, from entryID: String) throws -> [PresetNote] {
        try mutateNotes(entryID: entryID) { $0.filter { $0.id != id } }
    }

    /// Move one note between two sidecars — the "that was about the previous
    /// preset" repair (§4).
    ///
    /// THE APPEND LANDS FIRST, deliberately. `appendNote` can throw for
    /// reasons that belong entirely to the destination (.entryNotFound if the
    /// entry has been deleted, .integrity if its sidecar carries a newer
    /// schema, any write error), and doing the removal first meant such a
    /// throw destroyed the note instead of moving it. This order can at worst
    /// leave the note in BOTH files, which the user can see and fix; the other
    /// order left it in neither.
    ///
    /// Returns the moved note, or nil when the source does not hold it.
    @discardableResult
    func moveNote(id: String, from entryID: String,
                  to destination: String) throws -> PresetNote? {
        let source = try notesForWriting(entryID: entryID)
        guard let note = source.first(where: { $0.id == id }) else { return nil }
        guard destination != entryID else { return note }
        _ = try appendNote(note, to: destination)
        _ = try writeNotes(source.filter { $0.id != id }, entryID: entryID)
        return note
    }

    /// Delete an entry's sidecar. Idempotent, and never an error when there is
    /// no file. Deliberately does NOT require the entry to exist: this is also
    /// how an orphaned sidecar is garbage-collected. No schema gate — §1.2
    /// forbids REWRITING a newer file, and §1.1 says flatly that deleting an
    /// entry deletes its sidecar.
    func deleteNotes(entryID: String) throws {
        try? FileManager.default.removeItem(at: notePath(entryID))
    }

    // ------------------------------------------------------------- internals

    /// Read + parse, or nil when the file is absent. Shared by the public
    /// readers, remove()'s GC and dedupe()'s merge.
    internal func loadNoteDocument(entryID: String) throws -> NoteDocument? {
        let path = notePath(entryID)
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: try Data(contentsOf: path))
        } catch {
            throw FreakError.libraryCorrupt(path: path.path,
                                            detail: String(describing: error))
        }
        guard let d = object as? [String: Any] else {
            throw FreakError.libraryCorrupt(path: path.path, detail: "not a JSON object")
        }
        return try NoteCodec.fromJSON(d, path: path.path)
    }

    /// The write preflight: the entry must exist, and the file on disk must
    /// not be a newer schema.
    private func notesForWriting(entryID: String) throws -> [PresetNote] {
        _ = try entry(id: entryID)                     // .entryNotFound
        guard let doc = try loadNoteDocument(entryID: entryID) else { return [] }
        guard !doc.isReadOnly else {
            throw FreakError.integrity(
                path: notePath(entryID).path,
                detail: "notes sidecar schema \(doc.schema) is newer than this "
                    + "core's \(noteSchema) — refusing to rewrite it")
        }
        return doc.notes
    }

    /// Atomic write in canonical order; an empty list removes the file.
    @discardableResult
    internal func writeNotes(_ notes: [PresetNote], entryID: String) throws -> [PresetNote] {
        let ordered = PresetNote.canonicalOrder(notes)
        guard !ordered.isEmpty else {
            try? FileManager.default.removeItem(at: notePath(entryID))
            return []
        }
        do {
            try FileManager.default.createDirectory(at: notesDir(),
                                                    withIntermediateDirectories: true)
        } catch {
            throw FreakError.integrity(path: notesDir().path,
                                       detail: "cannot create notes dir: \(error)")
        }
        let doc = NoteDocument(entryID: entryID, notes: ordered)
        try AtomicFile.write(try jsonData(NoteCodec.toJSON(doc)), to: notePath(entryID))
        return ordered
    }
}
