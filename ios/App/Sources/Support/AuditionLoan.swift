// AuditionLoan.swift — the borrowed slot's original, on disk.
//
// An audition borrows a real slot: its contents are read, kept, and written
// back when the session stops. Between those two moments the ONLY copy of the
// user's preset used to be a field on an in-memory actor — so a crash, a
// force-quit, or iPadOS reclaiming a backgrounded app destroyed it, and the
// relaunched app did not even know which slot was still holding an audition
// preset.
//
// This record closes that hole. It is written the moment the original is read
// and deleted the moment it is verified back in place; anything found at
// launch is an outstanding loan, surfaced as a passive banner with a Put It
// Back action (AppModel.restorePendingAuditionLoan).
//
// The format is deliberately dull and self-describing (JSON + base64 of the
// exact wire bytes) so the file is readable by the Python tooling and by a
// human staring at Documents/ in the Files app.

import Foundation
import FreakCore

struct AuditionLoan: Codable, Equatable, Sendable {
    /// 0-based core slot number.
    let slot: Int
    /// Which device lent it — a hardware original is never put back into the
    /// practice sim (UX §11 identity separation).
    let identity: DeviceIdentity
    /// "Ambient Peaks · 32 presets in this collection" — what was playing.
    let sourceLabel: String
    let savedAt: Date
    let name: String
    /// The 4672-byte preset blob, base64.
    let blobBase64: String
    /// The 9-byte meta, base64.
    let metaBase64: String

    init(slot: Int, identity: DeviceIdentity, sourceLabel: String,
         savedAt: Date = Date(), preset: Preset) {
        self.slot = slot
        self.identity = identity
        self.sourceLabel = sourceLabel
        self.savedAt = savedAt
        self.name = preset.name
        self.blobBase64 = preset.blob.base64EncodedString()
        self.metaBase64 = preset.meta.base64EncodedString()
    }

    /// Rebuild the preset. Throws Preset's own validations, so a truncated or
    /// tampered record fails loudly instead of writing garbage to the synth.
    func preset() throws -> Preset {
        guard let blob = Data(base64Encoded: blobBase64),
              let meta = Data(base64Encoded: metaBase64) else {
            throw FreakError.protocolViolation(
                detail: "audition loan record is not decodable base64")
        }
        return try Preset(name: name, blob: blob, meta: meta)
    }
}

/// Read/write the single outstanding-loan record. Every operation is
/// best-effort and silent: a loan that cannot be written must never take down
/// the audition that is already running.
enum AuditionLoanStore {
    static func save(_ loan: AuditionLoan, to url: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(loan) else { return }
        try? data.write(to: url, options: .atomic)
    }

    static func load(_ url: URL) -> AuditionLoan? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(AuditionLoan.self, from: data)
    }

    static func clear(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}
