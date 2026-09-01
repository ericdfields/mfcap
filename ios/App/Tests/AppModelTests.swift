// AppModelTests.swift — app-layer model logic tests.
//
// These cover the pure app-side vocabulary (slot mapping, name rules, the
// §9 plan schema, identity stamping, history journal). Device behavior is
// FreakCore's to test; UI flows run against the practice device manually.

import XCTest
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
