// VoiceNoteTests.swift — the attribution rules, driven by ScriptedTranscriber.
//
// `SpeechTranscriber` is hardware-gated and does not run in the iOS Simulator,
// so these tests do what `SimulatedMicroFreak` does for the device layer: they
// substitute a real implementation of the protocol whose input comes from a
// script. Nothing here opens a microphone, an audio session, or a network
// connection.
//
// What is pinned:
//
//   MIDPOINT ASSIGNMENT — a finalized result belongs to the segment containing
//   the midpoint of its range, not its start and not its end.
//   DEFERRED BOUNDARY — a boundary requested while an utterance is in flight
//   commits at the END of that utterance, capped at 3 seconds.
//   THE TAP TIME — taken in closeCurrent() (the tap), not in markBoundary()
//   (after the device write), so speech during the write is charged correctly.
//   THE CONTENT GATE — fewer than two alphabetic tokens is not a note.
//   TWO-BUFFER VOLATILE — a volatile result REPLACES, it never appends.
//   THE TRUST RULES — a transcript never changes a preset attribute, and the
//   verbatim text is stored exactly as heard.

import XCTest
import FreakCore
@testable import FreakLibrarian

@MainActor
final class VoiceNoteAttributionTests: XCTestCase {

    private var scripted: ScriptedTranscriber!
    private var model: VoiceNoteModel!

    override func setUp() async throws {
        scripted = ScriptedTranscriber()
        model = VoiceNoteModel(transcriber: scripted)
        model.enabled = true
        await model.prepare()
    }

    override func tearDown() async throws {
        await model?.endSession()
        model = nil
        scripted = nil
    }

    /// A session with no library attached: attribution and the live transcript
    /// are pure in-memory logic, so they are testable without touching disk.
    private func startSession() {
        model.beginSession(app: nil, library: nil, identityStamp: "none")
        XCTAssertTrue(model.isListening)
    }

    private func final(_ text: String, _ start: Double, _ end: Double)
        -> VoiceNoteResult {
        VoiceNoteResult(text: text, start: start, end: end, isFinal: true)
    }

    private func volatile(_ text: String, _ start: Double, _ end: Double)
        -> VoiceNoteResult {
        VoiceNoteResult(text: text, start: start, end: end, isFinal: false)
    }

    private func texts(_ entryID: String) -> [String] {
        (model.captured[entryID] ?? []).map(\.text)
    }

    // -------------------------------------------------- midpoint assignment

    func testFinalizedResultGoesToTheSegmentHoldingItsMidpoint() {
        startSession()
        scripted.currentTimelineTime = 0
        model.markBoundary(to: "a")
        scripted.currentTimelineTime = 10
        model.closeCurrent()
        model.markBoundary(to: "b")

        // Starts before the boundary, ends after it, midpoint 9.5 -> "a".
        model.ingest(final("that filter sweep is lovely", 9, 10))
        // Midpoint 10.5 -> "b", even though it began at 9.9, before the tap.
        model.ingest(final("this one is much brighter", 9.9, 11.1))

        XCTAssertEqual(texts("a"), ["that filter sweep is lovely"])
        XCTAssertEqual(texts("b"), ["this one is much brighter"])
    }

    func testSpeechBeforeTheFirstBoundaryIsChargedToTheFirstPreset() {
        startSession()
        // The slot save takes a second or two; anything said while waiting is
        // about the preset that is coming, not thrown away.
        model.ingest(final("here we go then", 0.2, 1.4))
        scripted.currentTimelineTime = 2
        model.markBoundary(to: "a")
        XCTAssertEqual(texts("a"), ["here we go then"])
    }

    // -------------------------------------------------- deferred boundary

    func testABoundaryTappedMidUtteranceCommitsAtTheEndOfThatUtterance() {
        startSession()
        model.markBoundary(to: "a")

        // The user is mid-sentence when they tap: a volatile result is in
        // flight whose end is already past the tap.
        model.ingest(volatile("that pad is gorgeous keep", 8.0, 10.4))
        scripted.currentTimelineTime = 10.2
        model.closeCurrent()
        model.markBoundary(to: "b")

        // Without the deferral this sentence would be split by a boundary at
        // 10.2 and its midpoint (9.6) would still say "a" — so the rule is
        // proved by what happens to the NEXT one.
        model.ingest(final("that pad is gorgeous keep it", 8.0, 11.0))
        XCTAssertEqual(texts("a"), ["that pad is gorgeous keep it"])

        // The boundary committed at 11.0 (the end of that utterance), not at
        // the tap: a sentence starting at 11.2 belongs to "b".
        model.ingest(final("this next one is thin", 11.2, 12.6))
        XCTAssertEqual(texts("b"), ["this next one is thin"])
        XCTAssertEqual(texts("a").count, 1)
    }

    func testTheDeferredBoundaryIsCappedAtThreeSeconds() {
        startSession()
        model.markBoundary(to: "a")
        // An utterance that never finalizes — a cough held open by room noise.
        model.ingest(volatile("uhhh", 4.0, 30.0))
        scripted.currentTimelineTime = 5.0
        model.closeCurrent()
        model.markBoundary(to: "b")
        XCTAssertEqual(model.boundaryCap, 3.0)

        // The next result starts past tap + cap, which proves the utterance
        // the boundary was waiting for is not coming back. The boundary
        // commits at 8.0, so this sentence (midpoint 8.9) is "b"'s.
        model.ingest(final("this one is a nice bright lead", 8.3, 9.5))
        XCTAssertEqual(texts("b"), ["this one is a nice bright lead"])
        XCTAssertTrue(texts("a").isEmpty)
    }

    func testTwoAdvancesBeforeAnUtteranceEndsDoNotLoseThePresetInBetween() {
        startSession()
        model.markBoundary(to: "a")
        model.ingest(volatile("still talking", 1.0, 20.0))
        scripted.currentTimelineTime = 2.0
        model.closeCurrent()
        model.markBoundary(to: "b")
        scripted.currentTimelineTime = 3.0
        model.closeCurrent()
        model.markBoundary(to: "c")
        // "b" was visited and must still be in the session's order, so its
        // notes (and "move to previous") have somewhere to go.
        XCTAssertEqual(model.visitOrder, ["a", "b", "c"])
        XCTAssertEqual(model.previousEntryID(before: "c"), "b")
    }

    // ------------------------------------------------------- the tap time

    func testTheBoundaryIsPlacedAtTheTapNotAtTheNextPresetsArrival() {
        startSession()
        model.markBoundary(to: "a")
        scripted.currentTimelineTime = 5.0
        model.closeCurrent()                 // the tap: t = 5.0
        // The verified device write takes a second and a half; the clock runs.
        scripted.currentTimelineTime = 6.5
        model.markBoundary(to: "b")

        model.ingest(final("that one was lovely", 4.0, 4.8))
        // Said DURING the write, after the tap. The boundary IS the tap, so
        // this belongs to the preset the user has already moved to. Had the
        // boundary been placed where the next preset arrived (6.5), a whole
        // sentence would be filed against the old preset every time the
        // device was slow.
        model.ingest(final("right lets hear the next one", 5.2, 6.2))

        XCTAssertEqual(texts("a"), ["that one was lovely"])
        XCTAssertEqual(texts("b"), ["right lets hear the next one"])
    }

    // --------------------------------------------------- volatile buffering

    func testVolatileResultsReplaceRatherThanAccumulate() {
        startSession()
        model.markBoundary(to: "a")
        model.ingest(volatile("that pad", 0, 1))
        XCTAssertEqual(model.liveTranscript, "that pad")
        model.ingest(volatile("that pad is", 0, 1.4))
        model.ingest(volatile("that pad is gorgeous", 0, 2))
        // Appending each revision would read "that pad that pad is that pad
        // is gorgeous".
        XCTAssertEqual(model.liveTranscript, "that pad is gorgeous")

        model.ingest(final("that pad is gorgeous", 0, 2))
        XCTAssertEqual(model.liveTranscript, "that pad is gorgeous")
        // A second sentence APPENDS to the finalized buffer.
        model.ingest(final("really warm too", 2.2, 3.4))
        XCTAssertEqual(model.liveTranscript,
                       "that pad is gorgeous really warm too")
    }

    func testAnIdenticalFinalResultRepeatedIsOneNote() {
        startSession()
        model.markBoundary(to: "a")
        model.ingest(final("this is a warm pad", 0, 2))
        model.ingest(final("this is a warm pad", 0, 2))
        XCTAssertEqual(texts("a").count, 1)
    }

    // -------------------------------------------------------- content gate

    func testUtterancesUnderTwoAlphabeticTokensAreNotNotes() {
        startSession()
        model.markBoundary(to: "a")
        model.ingest(final("uh", 0, 0.4))
        model.ingest(final("", 0.5, 0.6))
        model.ingest(final("303", 0.7, 1.0))
        XCTAssertTrue(texts("a").isEmpty)
        XCTAssertEqual(model.suppressedCount, 2)   // "" is empty, not gated

        model.ingest(final("nice one", 1.2, 2.0))
        XCTAssertEqual(texts("a"), ["nice one"])
    }

    // -------------------------------------------------------- trust rules

    func testTextIsStoredVerbatimAndProposalsAreAdvisoryOnly() throws {
        startSession()
        model.markBoundary(to: "a")
        let heard = "Warm, dark pad \u{2014} keep it."
        model.ingest(final(heard, 0, 3))

        let note = try XCTUnwrap(model.captured["a"]?.first)
        // Verbatim: not lowercased, not stripped of punctuation, not tidied.
        XCTAssertEqual(note.text, heard)
        XCTAssertNil(note.textCorrected)
        XCTAssertEqual(note.source, .voice)
        // Session-relative seconds, never a pointer to audio.
        XCTAssertEqual(note.audioStart, 0)
        XCTAssertEqual(note.audioEnd, 3)
        // Proposals exist and are unaccepted \u{2014} a transcript changes
        // nothing on its own.
        XCTAssertEqual(note.proposals.verdictValue, .keep)
        XCTAssertEqual(note.proposals.verdict?.accepted, false)
        XCTAssertTrue(note.proposals.tagValues.contains("Dark"))
    }

    func testTheHeardVerdictPreAimsAChipAndQuotesTheWordsItHeard() {
        startSession()
        model.markBoundary(to: "a")
        model.ingest(final("this one is lovely, keep it", 0, 3))
        XCTAssertEqual(model.heardVerdictValue, .keep)
        // The caption quotes the LITERAL span that matched — "keep it", the
        // two-token synonym, not the canonical slug. That is the difference
        // between the user being able to check the machine and having to
        // trust it.
        XCTAssertEqual(model.heardVerdictCaption,
                       "heard \u{201C}keep it\u{201D}")

        // A verdict word buried mid-sentence is NOT a verdict (the positional
        // rule), so nothing is pre-aimed.
        model.markBoundary(to: "b")
        model.ingest(final("I would keep the filter setting but cut the noise "
                           + "on the oscillator side of things", 4, 9))
        XCTAssertNil(model.heardVerdictValue)
    }

    func testGhostedChipsOnlyOfferWhatTheEntryDoesNotAlreadyHave() {
        startSession()
        model.markBoundary(to: "a")
        model.ingest(final("really dark and gritty bass", 0, 3))

        let bare = LibraryEntry(id: "a", name: "A", sha256: "s", metaHex: "",
                                slot: nil, addedAt: "2026-01-01T00:00:00",
                                tags: [], category: .uncategorized)
        XCTAssertEqual(model.ghostedCategory(for: bare), .bass)
        XCTAssertTrue(model.ghostedTags(for: bare).contains("Dark"))

        // Already carried: nothing to offer, and — critically — the entry was
        // not changed by the transcript in the first place.
        let already = LibraryEntry(id: "a", name: "A", sha256: "s", metaHex: "",
                                   slot: nil, addedAt: "2026-01-01T00:00:00",
                                   tags: ["Dark"], category: .bass)
        XCTAssertNil(model.ghostedCategory(for: already))
        XCTAssertFalse(model.ghostedTags(for: already).contains("Dark"))
    }

    // ------------------------------------------------------ session review

    func testTheReviewSnapshotsEveryPresetInVisitOrder() {
        startSession()
        model.markBoundary(to: "a")
        model.ingest(final("warm and round", 0, 2))
        scripted.currentTimelineTime = 3
        model.closeCurrent()
        model.markBoundary(to: "b")
        model.ingest(final("thin and harsh", 3.2, 5))
        scripted.currentTimelineTime = 6
        model.closeCurrent()
        model.markBoundary(to: "c")            // nothing said about "c"

        model.requestReview()
        let review = model.review
        XCTAssertEqual(review?.sections.map(\.entryID), ["a", "b"])
        XCTAssertEqual(review?.noteCount, 2)
    }

    func testNoCaptureWithoutTheOptIn() async {
        let scripted = ScriptedTranscriber()
        let off = VoiceNoteModel(transcriber: scripted)
        off.enabled = false
        off.beginSession(app: nil, library: nil, identityStamp: "none")
        XCTAssertFalse(off.isListening)
        XCTAssertEqual(scripted.startCount, 0)
        off.markBoundary(to: "a")
        off.ingest(VoiceNoteResult(text: "this should never be stored",
                                   start: 0, end: 2, isFinal: true))
        XCTAssertTrue(off.captured.isEmpty)
    }

    // ------------------------------------------- the indicator's honesty

    /// The pill is drawn from `isCapturing`, not `isListening`. A session
    /// whose capture is suspended — an interface took the input, an
    /// interruption, a tap that could not be rebuilt — is still armed and
    /// hearing nothing, and an indicator that pulses over a dead microphone
    /// teaches the user that the indicator means nothing.
    func testASuspendedSessionStopsClaimingToBeListening() {
        startSession()
        XCTAssertTrue(model.isCapturing)
        XCTAssertNil(model.suspendedReason)

        scripted.reportStatus(.suspended("an interface has the input"))
        XCTAssertTrue(model.isListening)          // still armed
        XCTAssertFalse(model.isCapturing)         // but not hearing anything
        XCTAssertEqual(model.suspendedReason, "an interface has the input")

        scripted.reportStatus(.live)
        XCTAssertTrue(model.isCapturing)
        XCTAssertNil(model.suspendedReason)
    }

    /// A suspension commits a boundary that was waiting on an utterance which
    /// can no longer arrive, rather than leaving it pending until the cap.
    func testASuspensionCommitsAPendingBoundary() {
        startSession()
        model.markBoundary(to: "a")
        model.ingest(volatile("still talking", 1.0, 30.0))
        scripted.currentTimelineTime = 2.0
        model.closeCurrent()
        model.markBoundary(to: "b")

        scripted.currentTimelineTime = 2.5
        scripted.reportStatus(.suspended("the microphone went away"))
        XCTAssertEqual(model.volatileTranscript, "")

        scripted.reportStatus(.live)
        model.ingest(final("this one is a nice bright lead", 3.0, 4.0))
        XCTAssertEqual(texts("b"), ["this one is a nice bright lead"])
        XCTAssertTrue(texts("a").isEmpty)
    }

    /// Input mute is PROCESS-global and outlives a session. Starting one while
    /// the process was still muted drew a pulsing "Listening" over an input
    /// that was zeroing every sample.
    func testMuteIsResetAtBothEndsOfASession() async {
        startSession()
        XCTAssertFalse(model.isMuted)
        model.toggleMuted()
        XCTAssertTrue(model.isMuted)

        await model.endSession()
        XCTAssertFalse(model.isMuted)

        model.setMuted(true)
        startSession()
        XCTAssertFalse(model.isMuted)
    }

    /// A start that throws must leave nothing armed: the transcriber is torn
    /// down, `isListening` is false, and the failure is stated. Otherwise the
    /// next `beginSession` sails past its `!isListening` guard and builds a
    /// second analyzer over the first.
    func testAFailedStartLeavesNothingArmed() async {
        let scripted = ScriptedTranscriber()
        scripted.startError = NSError(domain: "test", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "the microphone reported no input."])
        let failing = VoiceNoteModel(transcriber: scripted)
        failing.enabled = true
        await failing.prepare()
        failing.beginSession(app: nil, library: nil, identityStamp: "none")
        for _ in 0..<200 where failing.isListening { await Task.yield() }

        XCTAssertFalse(failing.isListening)
        XCTAssertFalse(failing.isCapturing)
        XCTAssertGreaterThan(scripted.stopCount, 0)
        XCTAssertNotNil(failing.failure)
        // and a second start is a clean start, not a second analyzer
        scripted.startError = nil
        failing.beginSession(app: nil, library: nil, identityStamp: "none")
        XCTAssertTrue(failing.isListening)
        await failing.endSession()
    }

    // ------------------------------------------ session state does not leak

    /// The advisory layer belongs to the preset on screen in THIS session.
    /// `AuditionModel.start` calls `beginSession` unconditionally, so a run
    /// with voice notes turned OFF used to inherit the previous run's
    /// pre-aimed verdict and ghosted chips — the app claiming to have heard
    /// something that was never said in the session the user is looking at.
    func testASessionThatCannotCaptureStillClearsTheLastOne() async {
        startSession()
        model.markBoundary(to: "a")
        model.ingest(final("this one is lovely, keep it", 0, 3))
        XCTAssertEqual(model.heardVerdictValue, .keep)
        XCTAssertFalse(model.captured.isEmpty)

        await model.endSession()
        // The session screen is gone, so nothing may still be pre-aimed…
        XCTAssertNil(model.heardVerdictValue)
        XCTAssertNil(model.heardVerdictCaption)
        // …but what was captured survives for the review sheet.
        XCTAssertFalse(model.captured.isEmpty)
        XCTAssertEqual(model.visitOrder, ["a"])

        model.enabled = false
        model.beginSession(app: nil, library: nil, identityStamp: "none")
        XCTAssertFalse(model.isListening)
        XCTAssertNil(model.heardVerdictValue)
        XCTAssertTrue(model.captured.isEmpty)
        XCTAssertTrue(model.visitOrder.isEmpty)
        let bare = LibraryEntry(id: "a", name: "A", sha256: "s", metaHex: "",
                                slot: nil, addedAt: "2026-01-01T00:00:00",
                                tags: [], category: .uncategorized)
        XCTAssertNil(model.ghostedCategory(for: bare))
        XCTAssertTrue(model.ghostedTags(for: bare).isEmpty)
    }

    // --------------------------------------------------- ghosted provenance

    /// A ghosted chip captions itself with the LITERAL words that produced it
    /// — but only when they differ from the chip's own label, which is the one
    /// time the user cannot otherwise tell where the suggestion came from.
    func testGhostChipCaptionsQuoteOnlyASynonym() {
        startSession()
        model.markBoundary(to: "a")
        model.ingest(final("really sparkly bass", 0, 2))
        XCTAssertEqual(model.ghostedTagCaption("Bright"),
                       "heard \u{201C}sparkly\u{201D}")
        XCTAssertNil(model.ghostedCategoryCaption(.bass))   // they said "bass"

        model.markBoundary(to: "b")
        model.ingest(final("nice dark pad", 3, 5))
        XCTAssertNil(model.ghostedTagCaption("Dark"))       // they said "dark"
    }

    // -------------------------------------------------- the streamed path

    /// The other tests call `ingest` directly for determinism; this one proves
    /// the AsyncStream plumbing between the transcriber and the model is real.
    func testResultsArriveThroughTheTranscribersStream() async throws {
        startSession()
        model.markBoundary(to: "a")
        let before = model.resultsHandled
        scripted.emit("this one is a lovely warm pad", from: 0, to: 3)
        for _ in 0..<200 where model.resultsHandled == before {
            await Task.yield()
        }
        XCTAssertGreaterThan(model.resultsHandled, before)
        XCTAssertEqual(texts("a"), ["this one is a lovely warm pad"])
    }
}

// ============================================================ persistence

@MainActor
final class VoiceNotePersistenceTests: XCTestCase {

    private func freshLibrary() throws -> (LibraryModel, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let model = LibraryModel(root: root)
        model.openOrCreate()
        return (model, root)
    }

    private func preset(_ name: String, seed: UInt8) throws -> Preset {
        var blob = Data(repeating: 0x01, count: Wire.blobSize)
        blob[0] = seed
        return try Preset(name: name, blob: blob,
                          meta: Data(repeating: 0, count: Wire.metaLength))
    }

    /// Notes reach the per-entry sidecar, and the model's cache — which the
    /// row glyph and search read — agrees with what is on disk.
    func testCapturedNotesLandInTheSidecarAndTheCache() async throws {
        let (library, _) = try freshLibrary()
        let entry = try await library.add(preset("Zeta", seed: 1), slot: nil,
                                          tags: [])

        let scripted = ScriptedTranscriber()
        let voice = VoiceNoteModel(transcriber: scripted)
        voice.enabled = true
        await voice.prepare()
        voice.beginSession(app: nil, library: library.library,
                           identityStamp: "practice:factoryFresh")
        voice.markBoundary(to: entry.id)
        voice.ingest(VoiceNoteResult(text: "a broken kalimba, sort of",
                                     start: 0, end: 2.5, isFinal: true))
        await voice.flushWrites()

        let onDisk = try await XCTUnwrap(library.library).notes(entryID: entry.id)
        XCTAssertEqual(onDisk.map(\.text), ["a broken kalimba, sort of"])
        XCTAssertEqual(onDisk.first?.audioStart, 0)
        XCTAssertEqual(onDisk.first?.audioEnd, 2.5)

        await library.refreshNotes(force: true)
        XCTAssertEqual(library.noteCount(entry.id), 1)

        // Search matches what was SAID, not only the name and tags.
        library.searchText = "kalimba"
        XCTAssertEqual(library.displayRows.map(\.id), [entry.id])
        library.searchText = "marimba"
        XCTAssertTrue(library.displayRows.isEmpty)
    }

    /// The one-tap repair: a delete from one sidecar and an append to another,
    /// with the session-relative times unchanged.
    func testMoveToPreviousPresetRewritesBothSidecars() async throws {
        let (library, _) = try freshLibrary()
        let first = try await library.add(preset("First", seed: 1), slot: nil,
                                          tags: [])
        let second = try await library.add(preset("Second", seed: 2), slot: nil,
                                           tags: [])

        let scripted = ScriptedTranscriber()
        let voice = VoiceNoteModel(transcriber: scripted)
        voice.enabled = true
        await voice.prepare()
        voice.beginSession(app: nil, library: library.library,
                           identityStamp: "practice:factoryFresh")
        voice.markBoundary(to: first.id)
        scripted.currentTimelineTime = 5
        voice.closeCurrent()
        voice.markBoundary(to: second.id)
        voice.ingest(VoiceNoteResult(text: "that was actually the last one",
                                     start: 5.2, end: 7, isFinal: true))
        await voice.flushWrites()

        let note = try XCTUnwrap(voice.captured[second.id]?.first)
        await voice.moveToPreviousPreset(note: note, from: second.id)

        let core = try XCTUnwrap(library.library)
        let leftBehind = try await core.notes(entryID: second.id)
        XCTAssertTrue(leftBehind.isEmpty)
        let moved = try await core.notes(entryID: first.id)
        XCTAssertEqual(moved.map(\.text), ["that was actually the last one"])
        // Session-relative, so the move does not touch them.
        XCTAssertEqual(moved.first?.audioStart, 5.2)
        XCTAssertEqual(moved.first?.audioEnd, 7)
    }

    // ------------------------------------------------ arming, once and once

    /// The persisted opt-in must actually arm the feature.
    ///
    /// `prepare()` was reachable only from `enabled`'s `didSet`, and Swift
    /// does not run `didSet` for the value `init` reads out of UserDefaults —
    /// so for every returning user whose toggle was already ON, permission was
    /// never requested, the model was never checked, `canCapture` was false,
    /// and the whole feature was silently dead behind a setup panel that said
    /// otherwise. The only workaround was to toggle off and on again.
    func testAPersistedOptInStillArmsTheFeature() async {
        let key = VoiceNoteModel.defaultsKey
        let previous = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.set(true, forKey: key)
        defer {
            if let previous { UserDefaults.standard.set(previous, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }

        let voice = VoiceNoteModel(transcriber: ScriptedTranscriber())
        XCTAssertTrue(voice.enabled)              // restored, no didSet
        XCTAssertEqual(voice.permission, .notDetermined)
        XCTAssertEqual(voice.assets, .unknown)
        XCTAssertFalse(voice.canCapture)

        // What the setup panel's .task does.
        await voice.prepareIfNeeded()
        XCTAssertEqual(voice.permission, .granted)
        XCTAssertEqual(voice.assets, .installed)
        XCTAssertTrue(voice.canCapture)

        // Idempotent: a second appearance re-asks for nothing.
        await voice.prepareIfNeeded()
        XCTAssertTrue(voice.canCapture)
    }

    // --------------------------------------------- concurrent sidecar edits

    /// THE data-loss case. A user taps a ghosted chip while the transcriber is
    /// still running; the acceptance reads the note list, suspends, and the
    /// utterance that finalizes in that gap is appended — and was then wiped
    /// out when the acceptance wrote back the stale list it was still holding.
    /// No throw, no message, and because §1.5 keeps no audio, that verbatim
    /// transcript was the only copy that ever existed.
    func testAcceptingAChipCannotDestroyANoteFinalizedAtTheSameMoment() async throws {
        let scripted = ScriptedTranscriber()
        let app = AppModel(paths: .ephemeral(), seedFromBundle: false,
                           voiceTranscriber: scripted)
        let entry = try await app.libraryModel.add(preset("Race", seed: 4),
                                                   slot: nil, tags: [])
        let voice = app.voiceNotes
        voice.enabled = true
        await voice.prepare()
        voice.beginSession(app: app)
        voice.markBoundary(to: entry.id)
        voice.ingest(VoiceNoteResult(text: "a really dark gritty pad",
                                     start: 0, end: 2, isFinal: true))
        await voice.flushWrites()

        // The tap and the next finalized utterance, interleaved.
        let accepting = Task { @MainActor in
            await voice.acceptTag("Dark", for: entry.id)
        }
        await Task.yield()
        voice.ingest(VoiceNoteResult(text: "this next one is a bright lead",
                                     start: 2.2, end: 4, isFinal: true))
        await voice.flushWrites()
        let ok = await accepting.value
        XCTAssertTrue(ok)

        let core = try XCTUnwrap(app.libraryModel.library)
        let onDisk = try await core.notes(entryID: entry.id)
        XCTAssertEqual(onDisk.map(\.text).sorted(),
                       ["a really dark gritty pad",
                        "this next one is a bright lead"])
        // the acceptance still landed
        XCTAssertTrue(onDisk.contains { $0.proposals.tags.contains {
            $0.value == "Dark" && $0.accepted } })
        // and the in-memory copy the session UI reads agrees with the file
        XCTAssertEqual((voice.captured[entry.id] ?? []).count, 2)
    }

    /// `accepted` records what the user CONFIRMED. Stamping it onto a note
    /// from an earlier session — one whose identical proposal they deliberately
    /// left untapped — makes the sidecar claim a confirmation that never
    /// happened, which is the one thing provenance may not do.
    func testAcceptanceOnlyMarksThisSessionsNotes() async throws {
        let scripted = ScriptedTranscriber()
        let app = AppModel(paths: .ephemeral(), seedFromBundle: false,
                           voiceTranscriber: scripted)
        let entry = try await app.libraryModel.add(preset("Old", seed: 5),
                                                   slot: nil, tags: [])
        let core = try XCTUnwrap(app.libraryModel.library)
        // A note from a session two weeks ago, left unaccepted on purpose.
        let older = PresetNote.new(
            source: .voice, text: "this one is lovely, keep it", locale: "en-US",
            sessionID: "0000000000000000000000000000aaaa",
            audioStart: 1, audioEnd: 3, deviceIdentity: "hardware")
        XCTAssertEqual(older.proposals.verdictValue, .keep)
        try await core.appendNote(older, to: entry.id)

        let voice = app.voiceNotes
        voice.enabled = true
        await voice.prepare()
        voice.beginSession(app: app)
        voice.markBoundary(to: entry.id)
        voice.ingest(VoiceNoteResult(text: "yeah, keep this one",
                                     start: 10, end: 12, isFinal: true))
        await voice.flushWrites()
        let accepted = await voice.acceptVerdict(.keep, for: entry.id)
        XCTAssertTrue(accepted)

        let onDisk = try await core.notes(entryID: entry.id)
        let old = try XCTUnwrap(onDisk.first { $0.id == older.id })
        let new = try XCTUnwrap(onDisk.first { $0.id != older.id })
        XCTAssertEqual(old.proposals.verdict?.accepted, false)
        XCTAssertEqual(new.proposals.verdict?.accepted, true)
        // and the canonical home did change, through the existing setter
        XCTAssertEqual(app.libraryModel.entry(id: entry.id)?.verdict, .keep)
    }

    /// Deleting an entry takes its sidecar with it — no orphan is left to be
    /// resurrected by a later entry that happens to reuse the id.
    func testDeletingAnEntryRemovesItsNotes() async throws {
        let (library, root) = try freshLibrary()
        let entry = try await library.add(preset("Gone", seed: 3), slot: nil,
                                          tags: [])
        let scripted = ScriptedTranscriber()
        let voice = VoiceNoteModel(transcriber: scripted)
        voice.enabled = true
        await voice.prepare()
        voice.beginSession(app: nil, library: library.library,
                           identityStamp: "none")
        voice.markBoundary(to: entry.id)
        voice.ingest(VoiceNoteResult(text: "goodbye little preset",
                                     start: 0, end: 2, isFinal: true))
        await voice.flushWrites()

        let path = root.appendingPathComponent("notes/\(entry.id).json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: path.path))
        try await library.delete(id: entry.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
    }
}
