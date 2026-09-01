// SlotID.swift — the single slot-number conversion point (UX spec §2).
//
// Core addressing is 0-based 0…511 (bank = slot / 128); display addressing
// is 1-based 1…512, matching the synth's panel. Nothing else in the UI does
// arithmetic on slot numbers.
//
// The app layer deliberately does not import Wire (architecture spec §14) —
// the layout facts it needs (512 slots, 128 per bank, 4672-byte blobs,
// 23-char names) are user-facing vocabulary and live here as `SlotID.Layout`.

import Foundation

struct SlotID: Hashable, Comparable, Sendable, Identifiable, Codable {
    /// User-facing layout facts. These mirror the protocol constants but are
    /// owned by the UI vocabulary — the app never imports the wire module.
    enum Layout {
        static let slots = 512
        static let slotsPerBank = 128
        static let banks = 4
        static let blobBytes = 4672
        static let nameMax = 23
    }

    /// 0…511, the core's number. Every FreakCore call takes this.
    let raw: Int

    init(_ raw: Int) { self.raw = raw }

    var id: Int { raw }

    /// 1…512, the panel's number — what every list, dialog, and toast shows.
    var display: Int { raw + 1 }

    /// 0…3
    var bank: Int { raw / Layout.slotsPerBank }

    /// "413" — display number, 3 digits, monospaced digits at the call site.
    var label: String { String(format: "%03d", display) }

    /// "slot 413 (core 412)" — diagnostic detail views only (UX §2).
    var diagnosticLabel: String { "slot \(display) (core \(raw))" }

    /// "Bank 4 · 385–512"
    var bankLabel: String { SlotID.bankLabel(bank) }

    static func bankLabel(_ bank: Int) -> String {
        let lo = bank * Layout.slotsPerBank + 1
        let hi = (bank + 1) * Layout.slotsPerBank
        return "Bank \(bank + 1) · \(lo)–\(hi)"
    }

    static func < (lhs: SlotID, rhs: SlotID) -> Bool { lhs.raw < rhs.raw }

    static var all: [SlotID] { (0..<Layout.slots).map(SlotID.init) }

    static func bankSlots(_ bank: Int) -> [SlotID] {
        let lo = bank * Layout.slotsPerBank
        return (lo..<(lo + Layout.slotsPerBank)).map(SlotID.init)
    }
}
