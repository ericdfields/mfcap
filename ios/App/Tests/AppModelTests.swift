// AppModelTests.swift — app-layer model logic tests.
//
// These cover the pure app-side vocabulary (slot mapping, name rules, the
// §9 plan schema, identity stamping, history journal). Device behavior is
// FreakCore's to test; UI flows run against the practice device manually.

import XCTest
import FreakCore
@testable import FreakLibrarian

final class SlotIDTests: XCTestCase {
    func testDisplayMapping() {
        XCTAssertEqual(SlotID(0).display, 1)
        XCTAssertEqual(SlotID(511).display, 512)
        XCTAssertEqual(SlotID(412).display, 413)
        XCTAssertEqual(SlotID(412).label, "413")
    }

    func testBanks() {
        XCTAssertEqual(SlotID(0).bank, 0)
        XCTAssertEqual(SlotID(127).bank, 0)
        XCTAssertEqual(SlotID(128).bank, 1)
        XCTAssertEqual(SlotID(384).bank, 3)
        XCTAssertEqual(SlotID.bankLabel(3), "Bank 4 · 385–512")
        XCTAssertEqual(SlotID.all.count, 512)
        XCTAssertEqual(SlotID.bankSlots(3).first?.raw, 384)
        XCTAssertEqual(SlotID.bankSlots(3).count, 128)
    }
}

final class NameRulesTests: XCTestCase {
    func testLengthRules() {
        XCTAssertTrue(NameRules.isValid(String(repeating: "a", count: 23)))
        XCTAssertFalse(NameRules.isValid(String(repeating: "a", count: 24)))
        XCTAssertTrue(NameRules.isValid(""))
    }

    func testWhitespaceAndCharset() {
        XCTAssertFalse(NameRules.isValid(" leading"))
        XCTAssertFalse(NameRules.isValid("trailing "))
        XCTAssertFalse(NameRules.isValid("tab\tname"))
        XCTAssertFalse(NameRules.isValid("émigré"))
        XCTAssertTrue(NameRules.isValid("Bass Prophet v2"))
    }

    func testSanitizer() {
        XCTAssertEqual(NameRules.sanitizedWhileTyping("émigré"), "migr")
        XCTAssertEqual(
            NameRules.sanitizedWhileTyping(String(repeating: "x", count: 40))
                .count,
            NameRules.maxLength)
    }
}

@MainActor
final class OverwritePlanTests: XCTestCase {
    private func item(_ slot: Int, victim: OverwritePlan.Victim)
        -> OverwritePlan.Item {
        OverwritePlan.Item(target: SlotID(slot), incomingName: "X",
                           incoming: .libraryEntry(id: "e"), victim: victim)
    }

    func testSeverityScalesWithBlastRadius() {
        let empty = OverwritePlan(
            kind: .send,
            items: [item(509, victim: .empty(evidence: "identical to 268 other slots"))],
            title: "t", freshnessLine: "f", isPracticeDevice: false)
        XCTAssertEqual(empty.severity, .popover)

        let occupied = OverwritePlan(
            kind: .send,
            items: [item(412, victim: .named("Perc Organ", recoverable: .none))],
            title: "t", freshnessLine: "f", isPracticeDevice: false)
        XCTAssertEqual(occupied.severity, .dialog)

        let bulk = OverwritePlan(
            kind: .bulkSync,
            items: [item(1, victim: .empty(evidence: "e")),
                    item(2, victim: .empty(evidence: "e"))],
            title: "t", freshnessLine: "f", isPracticeDevice: false)
        XCTAssertEqual(bulk.severity, .planSheet)

        let fullRestore = OverwritePlan(
            kind: .restore,
            items: (0..<512).map { item($0, victim: .empty(evidence: "e")) },
            title: "t", freshnessLine: "f", isPracticeDevice: false)
        XCTAssertEqual(fullRestore.severity, .planSheetPlusFinalAlert)
    }

    func testConfirmLabelsStateActionAndCount() {
        let restore = OverwritePlan(
            kind: .restore,
            items: (0..<5).map { item($0, victim: .empty(evidence: "e")) },
            title: "t", freshnessLine: "f", isPracticeDevice: false)
        XCTAssertEqual(restore.confirmLabel, "Restore 5 Slots")

        let occupied = OverwritePlan(
            kind: .send,
            items: [item(412, victim: .named("P", recoverable: .none))],
            title: "t", freshnessLine: "f", isPracticeDevice: false)
        XCTAssertEqual(occupied.confirmLabel, "Replace Preset")
        XCTAssertTrue(occupied.items[0].victim.isUnrecoverable)
    }

    func testDisabledRowsExcludedFromWriteCount() {
        var disabled = item(3, victim: .empty(evidence: "e"))
        disabled.disabledReason = "no meta recorded"
        let plan = OverwritePlan(
            kind: .restore,
            items: [item(1, victim: .empty(evidence: "e")), disabled],
            title: "t", freshnessLine: "f", isPracticeDevice: false)
        XCTAssertEqual(plan.writeCount, 1)
    }
}

final class DeviceIdentityTests: XCTestCase {
    func testStamps() {
        XCTAssertEqual(DeviceIdentity.hardware.stamp, "hardware")
        XCTAssertEqual(DeviceIdentity.practice(profile: "factoryFresh").stamp,
                       "practice:factoryFresh")
        XCTAssertTrue(DeviceIdentity.practice(profile: "full").isPractice)
        XCTAssertFalse(DeviceIdentity.hardware.isPractice)
    }

    func testBackupFolderIdentity() {
        XCTAssertTrue(DeviceIdentity
            .ofBackupFolder(named: "practice-2026-09-01-120000").isPractice)
        XCTAssertFalse(DeviceIdentity
            .ofBackupFolder(named: "2026-09-01-120000").isPractice)
    }
}

@MainActor
final class SlotHistoryStoreTests: XCTestCase {
    func testRecordCapAndIdentityIsolation() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("history-\(UUID().uuidString).json")
        let store = SlotHistoryStore(url: url)
        let practice = DeviceIdentity.practice(profile: "factoryFresh")
        for index in 0..<60 {
            store.record(.observed, slot: SlotID(3), identity: practice,
                         summary: "event \(index)")
        }
        XCTAssertEqual(store.events(slot: SlotID(3), identity: practice).count,
                       SlotHistoryStore.perSlotCap)
        // Newest first.
        XCTAssertEqual(store.events(slot: SlotID(3), identity: practice)
            .first?.summary, "event 59")
        // Cross-identity views never mix (UX §15).
        XCTAssertTrue(store.events(slot: SlotID(3), identity: .hardware)
            .isEmpty)

        // Round-trips through disk.
        let reloaded = SlotHistoryStore(url: url)
        XCTAssertEqual(reloaded.events(slot: SlotID(3), identity: practice)
            .count, SlotHistoryStore.perSlotCap)
        try? FileManager.default.removeItem(at: url)
    }
}

final class FormatTests: XCTestCase {
    func testClock() {
        XCTAssertEqual(Format.clock(130), "2:10")
        XCTAssertEqual(Format.clock(3730), "1:02:10")
        XCTAssertEqual(Format.clock(-5), "0:00")
    }

    func testShaPrefix() {
        XCTAssertEqual(Format.shaPrefix("9f3a01b2c4d6ffff"), "9f3a01b2c4d6")
        XCTAssertEqual(Format.shaPrefix(nil), "—")
    }

    func testCoreTimestampParsing() {
        XCTAssertNotNil(Format.parseCoreTimestamp("2026-09-01T12:00:00"))
        XCTAssertNil(Format.parseCoreTimestamp("not a date"))
    }
}

// ===================================================== derived library state
//
// `LibraryModel` precomputes the browser's rows, the faceted category census,
// the tag list and the any-favorite flag once per input change instead of
// recomputing them inside every view body. These assert the precomputed
// outputs agree with the facets that produced them — the guard against chip
// counts and rows disagreeing.

@MainActor
final class LibraryDerivedStateTests: XCTestCase {
    /// A throwaway library root, removed when the test ends.
    private func freshRoot() -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lib-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func preset(_ name: String, seed: UInt8) throws -> Preset {
        var blob = Data(repeating: 0x01, count: Wire.blobSize)
        blob[0] = seed
        return try Preset(name: name,
                          blob: blob,
                          meta: Data(repeating: 0, count: Wire.metaLength))
    }

    private func makeModel() async throws -> LibraryModel {
        let model = LibraryModel(root: freshRoot())
        model.openOrCreate()
        XCTAssertNil(model.openFailure)
        _ = try await model.add(preset("Zeta", seed: 1), slot: nil,
                                tags: ["dark"], category: .bass)
        _ = try await model.add(preset("alpha", seed: 2), slot: nil,
                                tags: [], category: .lead, favorite: true)
        _ = try await model.add(preset("Mid", seed: 3), slot: SlotID(4),
                                tags: ["dark", "pad"], category: .bass)
        return model
    }

    func testDisplayRowsSortCaseInsensitivelyByName() async throws {
        let model = try await makeModel()
        XCTAssertEqual(model.displayRows.map(\.name), ["alpha", "Mid", "Zeta"])
        XCTAssertEqual(model.filtered(tag: nil).map(\.name),
                       model.displayRows.map(\.name))
        XCTAssertEqual(model.allTagNames, ["dark", "pad"])
        XCTAssertTrue(model.hasAnyFavorite)
    }

    func testCategoryCensusIgnoresTheCategoryFacetButHonorsTheRest() async throws {
        let model = try await makeModel()
        XCTAssertEqual(model.displayCategoryCounts[.bass], 2)
        XCTAssertEqual(model.displayCategoryCounts[.lead], 1)

        // Selecting a category narrows the rows but NOT the census (§22.2).
        model.categoryFilter = .bass
        XCTAssertEqual(model.displayRows.map(\.name), ["Mid", "Zeta"])
        XCTAssertEqual(model.displayCategoryCounts[.lead], 1)

        // Any other facet narrows both.
        model.categoryFilter = nil
        model.tagFilter = ["dark"]
        XCTAssertEqual(model.displayRows.map(\.name), ["Mid", "Zeta"])
        XCTAssertEqual(model.displayCategoryCounts[.lead], 0)
        XCTAssertEqual(model.displayCategoryCounts[.bass], 2)
    }

    func testSearchAndFavoritesFacetsRecomputeImmediately() async throws {
        let model = try await makeModel()
        model.searchText = "  AL "
        XCTAssertEqual(model.displayRows.map(\.name), ["alpha"])
        model.searchText = ""
        model.favoritesOnly = true
        XCTAssertEqual(model.displayRows.map(\.name), ["alpha"])
        model.favoritesOnly = false
        model.sort = .slot
        // Unassigned entries sort last, by name.
        XCTAssertEqual(model.displayRows.first?.name, "Mid")
    }

    func testSingleTagFilteringPreservesSortOrder() async throws {
        let model = try await makeModel()
        XCTAssertEqual(model.filtered(tag: "dark").map(\.name), ["Mid", "Zeta"])
        XCTAssertEqual(model.filtered(tag: "nope").count, 0)
    }

    func testEntryLookupIsIndexed() async throws {
        let model = try await makeModel()
        let target = try XCTUnwrap(model.displayRows.first)
        XCTAssertEqual(model.entry(id: target.id)?.name, target.name)
        XCTAssertNil(model.entry(id: "not-an-id"))
        try await model.delete(id: target.id)
        XCTAssertNil(model.entry(id: target.id))
    }
}

// ========================================================= audition requests

@MainActor
final class AuditionRequestTests: XCTestCase {
    private func entry(_ name: String, verdict: Verdict) -> LibraryEntry {
        LibraryEntry(id: name, name: name, sha256: name, metaHex: "",
                     slot: nil, addedAt: "2026-01-01T00:00:00", tags: [],
                     verdict: verdict)
    }

    func testUnratedIsTheQueueTheStartPopoverDefaultsTo() {
        let request = AuditionRequest(
            sourceLabel: "Ambient Peaks · 3 presets from this collection",
            candidates: [entry("a", verdict: .unrated),
                         entry("b", verdict: .keep),
                         entry("c", verdict: .unrated)],
            unresolvedCount: 2)
        // AuditionSession.unrated stays the single definition of "unrated",
        // shared with the Python core.
        XCTAssertEqual(request.unratedCandidates.map(\.name), ["a", "c"])
        XCTAssertEqual(request.candidates.count, 3)
        // Refs with no library entry are counted, never silently dropped.
        XCTAssertEqual(request.unresolvedCount, 2)
    }

    // ------------------------------------------- the collection-scoped queue

    private func freshModel() -> AppModel {
        let model = AppModel(paths: .ephemeral(), seedFromBundle: false)
        addTeardownBlock { @MainActor in
            try? FileManager.default.removeItem(at: model.paths.libraryRoot)
            try? FileManager.default.removeItem(at: model.paths.backupsRoot)
            try? FileManager.default.removeItem(at: model.paths.auditionLoanURL)
        }
        return model
    }

    private func preset(_ name: String, seed: UInt8) throws -> Preset {
        var blob = Data(repeating: 0x01, count: Wire.blobSize)
        blob[0] = seed
        return try Preset(name: name, blob: blob,
                          meta: Data(repeating: 0, count: Wire.metaLength))
    }

    private func ref(_ entry: LibraryEntry) -> PresetRef {
        PresetRef(sha256: entry.sha256, name: entry.name,
                  metaHex: entry.metaHex)
    }

    /// "Auditioning a collection queues only that collection" — the whole
    /// point of the feature, previously uncovered.
    func testCollectionQueueIsSlotOrderedDedupedAndHonestAboutMisses() async throws {
        let model = freshModel()
        let a = try await model.libraryModel.add(preset("Ayla", seed: 1),
                                                 slot: nil, tags: [])
        let b = try await model.libraryModel.add(preset("Borea", seed: 2),
                                                 slot: nil, tags: [])
        let missing = PresetRef(sha256: String(repeating: "f", count: 64),
                                name: "Not Here", metaHex: "")
        // Slot order, one repeat of A, and one ref whose bytes the library
        // does not have.
        let coll = PresetCollection.new(
            name: "Ambient Peaks",
            provenance: Provenance(kind: .manual),
            slots: [3: ref(b), 1: ref(a), 7: ref(a), 9: missing])

        let request = model.auditionRequest(for: coll)
        XCTAssertEqual(request.candidates.map(\.name), ["Ayla", "Borea"])
        XCTAssertEqual(request.unresolvedCount, 1)
        // The label counts presets, not slots — the queue plays each preset
        // once, so "4 presets" over a queue of two was a lie.
        XCTAssertTrue(request.sourceLabel.hasPrefix("Ambient Peaks · 2 presets"),
                      request.sourceLabel)
        XCTAssertTrue(request.sourceLabel.contains("repeats played once"),
                      request.sourceLabel)

        // Filing a verdict narrows the default (unrated) queue, and nothing
        // outside the collection ever enters it.
        await model.libraryModel.setVerdict(id: b.id, .keep)
        _ = try await model.libraryModel.add(preset("Elsewhere", seed: 3),
                                             slot: nil, tags: [])
        let narrowed = model.auditionRequest(for: coll)
        XCTAssertEqual(narrowed.unratedCandidates.map(\.name), ["Ayla"])
        XCTAssertEqual(narrowed.candidates.map(\.name), ["Ayla", "Borea"])
        _ = a
    }
}

// ==================================================== the outstanding loan

@MainActor
final class AuditionLoanTests: XCTestCase {
    private func preset(_ name: String) throws -> Preset {
        var blob = Data(repeating: 0x02, count: Wire.blobSize)
        blob[1] = 0x7F
        return try Preset(name: name, blob: blob,
                          meta: Data(repeating: 0, count: Wire.metaLength))
    }

    /// The record that survives a force-quit: the borrowed slot's original,
    /// byte-for-byte, plus which device lent it.
    func testLoanRecordRoundTripsTheBorrowedOriginal() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("loan-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let original = try preset("Perc Organ")
        let loan = AuditionLoan(slot: 511,
                                identity: .practice(profile: "factoryFresh"),
                                sourceLabel: "All Presets", preset: original)
        AuditionLoanStore.save(loan, to: url)

        let loaded = try XCTUnwrap(AuditionLoanStore.load(url))
        XCTAssertEqual(loaded.slot, 511)
        XCTAssertEqual(loaded.identity, .practice(profile: "factoryFresh"))
        XCTAssertEqual(try loaded.preset(), original)
        XCTAssertEqual(try loaded.preset().sha256, original.sha256)

        AuditionLoanStore.clear(url)
        XCTAssertNil(AuditionLoanStore.load(url))
    }

    /// A truncated or tampered record must fail loudly, never write garbage
    /// to the synth.
    func testUndecodableLoanRefusesToProduceAPreset() throws {
        let json = """
        {"blobBase64":"!!!not base64!!!","identity":{"hardware":{}},\
        "metaBase64":"AAAAAAAAAAAA","name":"Perc Organ",\
        "savedAt":"2026-09-02T10:00:00Z","slot":0,"sourceLabel":""}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let loan = try decoder.decode(AuditionLoan.self,
                                      from: Data(json.utf8))
        XCTAssertThrowsError(try loan.preset())
    }

    /// Nothing borrowed → nothing blocked. (The blocked case needs a live
    /// session and is exercised against the practice device by hand.)
    func testPerSlotBlockIsSilentWithNoSession() {
        let model = AppModel(paths: .ephemeral(), seedFromBundle: false)
        addTeardownBlock { @MainActor in
            try? FileManager.default.removeItem(at: model.paths.libraryRoot)
            try? FileManager.default.removeItem(at: model.paths.backupsRoot)
        }
        XCTAssertNil(model.audition.borrowedSlot)
        XCTAssertNil(model.auditionBlockReason())
        XCTAssertNil(model.auditionBlockReason(for: SlotID(511)))
    }
}

// ===================================================== sync baseline (§17)

/// Sync compares the device against ONE collection the user chose. These pin
/// the state machine and the two properties the library rows read, all
/// offline: no device, no MIDI, no hardware.
@MainActor
final class SyncBaselineTests: XCTestCase {

    private func record(_ slot: Int, _ name: String, _ sha: String) -> SlotRecord {
        SlotRecord(slot: slot, name: name, sha256: sha, meta: nil, blob: nil)
    }

    private func snapshot(_ records: [SlotRecord]) -> DeviceSnapshot {
        DeviceSnapshot(takenAt: "2026-09-01T00:00:00", records: records,
                       timing: TimingReport(totalSeconds: 0, perSlotSeconds: 0,
                                            nameMsMedian: nil, dumpMsMedian: nil))
    }

    private func ref(_ name: String, _ sha: String) -> PresetRef {
        PresetRef(sha256: sha, name: name,
                  metaHex: String(repeating: "0", count: 18))
    }

    private func collection(_ name: String,
                            _ slots: [Int: PresetRef]) -> PresetCollection {
        PresetCollection.new(name: name,
                             provenance: Provenance(kind: .importedBank,
                                                    source: "\(name).mfprojz"),
                             slots: slots)
    }

    /// No baseline → the picker state, and never a diff. This is the state a
    /// fresh install lands in, so it has to carry real weight.
    func testNoBaselineIsTheExplanatoryStateNotADiff() {
        let sync = SyncModel()
        sync.recompute(snapshot: snapshot([record(0, "A", "sha-a")]),
                       baseline: nil, provenance: nil)
        XCTAssertEqual(sync.state, .needsBaseline)
        XCTAssertNil(sync.diff)
        XCTAssertNil(sync.allInSyncSummary)
        XCTAssertTrue(sync.badges.isEmpty)
    }

    /// The reported symptom, inverted: a 2-slot pack against a full device
    /// used to read "changed 148 / missing 268". It must now read as in sync,
    /// with the rest simply outside the collection.
    func testDeviceMatchingItsCollectionReadsAsInSync() {
        let records = (0..<8).map { record($0, "P\($0)", "sha-\($0)") }
        let coll = collection("Ambient Peaks",
                              [0: ref("P0", "sha-0"), 1: ref("P1", "sha-1")])
        let sync = SyncModel()
        sync.recompute(snapshot: snapshot(records), baseline: coll,
                       provenance: nil)
        XCTAssertEqual(sync.state, .ready)
        XCTAssertEqual(sync.counts[.differs] ?? 0, 0)
        XCTAssertEqual(sync.counts[.baselineOnly] ?? 0, 0)
        XCTAssertEqual(sync.counts[.inSync], 2)
        XCTAssertEqual(sync.counts[.unlisted], 6)
        // Default filter shows only real disagreements — so: no rows at all.
        XCTAssertTrue(sync.visibleRows.isEmpty)
        let summary = sync.allInSyncSummary ?? ""
        XCTAssertTrue(summary.contains("Device matches 'Ambient Peaks'"), summary)
        XCTAssertTrue(summary.contains("6 slots aren't part"), summary)
        // Slots the collection is silent about are never badged in the browser.
        XCTAssertEqual(Set(sync.badges.keys), [0, 1])
    }

    /// Library rows key their hint on CONTENT: the catalog has no slot claim
    /// to look up any more.
    func testLibraryHintsAreKeyedByContentNotBySlotClaim() {
        let records = [record(0, "P0", "sha-0"), record(1, "Changed", "sha-x")]
        let coll = collection("Pack", [0: ref("P0", "sha-0"),
                                       1: ref("P1", "sha-1")])
        let sync = SyncModel()
        sync.recompute(snapshot: snapshot(records), baseline: coll,
                       provenance: nil)
        XCTAssertEqual(sync.statusBySha["sha-0"], .inSync)
        XCTAssertEqual(sync.statusBySha["sha-1"], .differs)
        let entry = LibraryEntry(id: "e0", name: "P0", sha256: "sha-0",
                                 metaHex: String(repeating: "0", count: 18),
                                 slot: nil, addedAt: "", tags: [])
        XCTAssertEqual(LibraryRowView.syncHint(for: entry,
                                               statusBySha: sync.statusBySha,
                                               baselineName: "Pack"),
                       "in sync in 'Pack'")
    }

    /// A device-side RENAME is a real disagreement: `planApply` writes that
    /// slot. The diff keeps `.inSync` (status is content-based, by core
    /// contract), so the screen has to surface it anyway — this is the exact
    /// screen-vs-plan disagreement the sync redesign claims is impossible.
    /// Before the fix the row was hidden by the default filter AND the green
    /// "Device matches" all-clear fired on top of it.
    func testANameOnlyDifferenceIsVisibleAndSuppressesTheAllClear() {
        // Byte-identical to the baseline except slot 1, renamed on the synth.
        let records = [record(0, "P0", "sha-0"), record(1, "RENAMED", "sha-1")]
        let coll = collection("Ambient Peaks", [0: ref("P0", "sha-0"),
                                                1: ref("P1", "sha-1")])
        let sync = SyncModel()
        sync.recompute(snapshot: snapshot(records), baseline: coll,
                       provenance: nil)
        XCTAssertEqual(sync.state, .ready)
        // Content-based status is untouched: both rows are still .inSync.
        XCTAssertEqual(sync.counts[.inSync], 2)
        XCTAssertEqual(sync.counts[.differs] ?? 0, 0)

        // …but the row is actionable, visible by default, and rides the
        // .differs chip, whose count matches the rows it reveals.
        XCTAssertEqual(sync.actionableRows.map(\.slot), [1])
        XCTAssertEqual(sync.visibleRows.map(\.slot), [1])
        XCTAssertEqual(sync.filterCount(.differs), 1)
        XCTAssertEqual(sync.filterCount(.inSync), 1)

        // No green all-clear while Apply would write a slot.
        XCTAssertNil(sync.allInSyncSummary)

        // Turning the .differs chip off still hides it, like any other row.
        sync.visibleStatuses = [.baselineOnly]
        XCTAssertTrue(sync.visibleRows.isEmpty)
    }

    /// The summary's "aren't part of this collection" count must not subtract
    /// baseline slots the snapshot never read — those are reported separately
    /// in the very next sentence, so subtracting them contradicts it.
    func testOutsideCountExcludesUnreadBaselineSlots() {
        // Read slots 0…3; the collection also defines 400 and 401 (unread).
        let records = (0..<4).map { record($0, "P\($0)", "sha-\($0)") }
        let coll = collection("Pack", [0: ref("P0", "sha-0"),
                                       1: ref("P1", "sha-1"),
                                       400: ref("P400", "sha-400"),
                                       401: ref("P401", "sha-401")])
        let sync = SyncModel()
        sync.recompute(snapshot: snapshot(records), baseline: coll,
                       provenance: nil)
        XCTAssertEqual(sync.diff?.unreadBaselineSlots, [400, 401])
        let summary = sync.allInSyncSummary ?? ""
        // 4 read slots, 2 of them covered by the collection -> 2 outside.
        // The old arithmetic (4 - 4) reported 0 and dropped the sentence.
        XCTAssertTrue(summary.contains("2 slots aren't part"), summary)
        XCTAssertTrue(summary.contains("2 slots this collection defines "
                                       + "weren't read"), summary)
        XCTAssertTrue(summary.contains("2 of 4 slots in sync"), summary)
    }

    /// A hashed snapshot is still required — refusing beats guessing.
    func testNoSnapshotIsTheReadCTA() {
        let sync = SyncModel()
        sync.recompute(snapshot: nil, baseline: collection("Pack", [:]),
                       provenance: nil)
        XCTAssertEqual(sync.state, .needsSnapshot)
        XCTAssertNil(sync.diff)
    }
}

/// The shipped seed library must carry NO slot claims: the arrangement lives
/// in its 17 collections, and the flat catalog is a pure content catalog.
///
/// "No slot claims" alone is a weak guard — a regeneration that silently drops
/// a whole bank satisfies it. These also pin the seed's SHAPE (17 collections,
/// 966 unique blobs), the index's key set, and the invariant that binds the
/// two halves together: every collection ref resolves to a real blob.
final class SeedLibraryShapeTests: XCTestCase {
    private static let expectedEntries = 966
    private static let expectedCollections = 17

    private func seedRoot() throws -> URL {
        guard let seed = SeedInstaller.bundledSeedLibrary() else {
            throw XCTSkip("SeedBanks not in this test bundle")
        }
        return seed
    }

    private func indexEntries(_ seed: URL) throws -> [[String: Any]] {
        let raw = try Data(contentsOf: seed.appendingPathComponent("index.json"))
        let object = try JSONSerialization.jsonObject(with: raw) as! [String: Any]
        return object["entries"] as! [[String: Any]]
    }

    func testShippedSeedIndexHasNoSlotClaims() throws {
        let entries = try indexEntries(try seedRoot())
        XCTAssertFalse(entries.isEmpty)
        let claiming = entries.filter { !($0["slot"] is NSNull) && $0["slot"] != nil }
        XCTAssertEqual(claiming.count, 0,
                       "the seed catalog must carry no slot opinion")
    }

    /// The acceptance criteria for the regenerated seed, asserted instead of
    /// checked by hand: a run that drops a bank changes these numbers.
    func testShippedSeedHasTheExpectedCensus() throws {
        let seed = try seedRoot()
        let entries = try indexEntries(seed)
        XCTAssertEqual(entries.count, Self.expectedEntries)
        let shas = Set(entries.compactMap { $0["sha256"] as? String })
        XCTAssertEqual(shas.count, Self.expectedEntries,
                       "the catalog is a set of UNIQUE patches")

        let fm = FileManager.default
        let blobs = try fm.contentsOfDirectory(
            atPath: seed.appendingPathComponent("blobs").path)
            .filter { $0.hasSuffix(".bin") }
        XCTAssertEqual(blobs.count, Self.expectedEntries)

        let collections = try fm.contentsOfDirectory(
            atPath: seed.appendingPathComponent("collections").path)
            .filter { $0.hasSuffix(".json") }
        XCTAssertEqual(collections.count, Self.expectedCollections)
    }

    /// The index must be exactly what the cores' index writer emits — the
    /// shipped artifact once had `verdict` stripped from all 966 entries,
    /// which is only possible if it was hand-edited after generation.
    func testShippedSeedIndexCarriesEveryKeyTheCoresWrite() throws {
        let expected: Set<String> = ["id", "name", "sha256", "meta_hex", "slot",
                                     "added_at", "tags", "category", "favorite",
                                     "verdict"]
        for entry in try indexEntries(try seedRoot()) {
            XCTAssertEqual(Set(entry.keys), expected,
                           "entry \(entry["id"] ?? "?") is not what saveIndex writes")
        }
    }

    /// Every collection ref must name a blob the store actually holds — the
    /// binding that makes "Make Device Match '<name>'" able to write anything.
    func testEverySeedCollectionRefResolvesToABlob() async throws {
        let seed = try seedRoot()
        let library = try Library.open(at: seed)
        let collections = try await library.collections()
        XCTAssertEqual(collections.count, Self.expectedCollections)
        var refs = 0
        for coll in collections {
            for (_, ref) in coll.slots {
                _ = try await library.presetForRef(ref)   // throws on a hole
                refs += 1
            }
        }
        XCTAssertGreaterThanOrEqual(refs, Self.expectedEntries,
                                    "every catalogued patch is placed somewhere")
    }
}
