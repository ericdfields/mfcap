// SysEx7.swift — pure UMP SysEx7 encode/decode + the inbound assembler.
//
// This file is deliberately free of CoreMIDI: it manipulates UInt32 UMP words
// and Data only, so every branch is unit-testable on any platform with no
// MIDI client, port, or hardware involved. CoreMIDITransport is the only
// consumer that ever touches CoreMIDI.
//
// UMP 64-bit Data message (MIDI 1.0 protocol SysEx7), two 32-bit words:
//
//     word0 = [mt=0x3][group][status][byteCount][b1][b2]
//              31..28  27..24  23..20   19..16   15..8  7..0
//     word1 = [b3][b4][b5][b6]
//             31..24 23..16 15..8 7..0
//
// status: 0x0 complete / 0x1 start / 0x2 continue / 0x3 end; byteCount 0–6.
// UMP carries only the INTERIOR bytes — the F0/F7 framing never travels in a
// packet; encode() strips it and the assembler re-wraps completed streams as
// F0…F7 because the Transport contract delivers complete SysEx messages.

import Foundation

public enum SysEx7 {
    /// UMP message-type nibble for 64-bit data messages (SysEx7).
    public static let messageType: UInt32 = 0x3

    /// Maximum interior bytes per SysEx7 packet.
    public static let maxBytesPerPacket = 6

    public enum Status: UInt32, Sendable {
        case complete = 0x0
        case start = 0x1
        case `continue` = 0x2
        case end = 0x3
    }

    /// Encode one complete SysEx message (F0..F7) as UMP SysEx7 words,
    /// group 0, 6 interior bytes per packet. A message whose interior fits
    /// in one packet becomes a single `complete` packet; anything longer is
    /// `start`, `continue`…, `end`. Returns pairs of words flattened in
    /// order — always an even count, ready for a MIDIEventList.
    ///
    /// The leading F0 and trailing F7 are stripped (UMP carries interior
    /// bytes only); the Transport contract guarantees callers pass complete
    /// F0..F7 messages.
    public static func encode(_ message: Data) -> [UInt32] {
        var interior = [UInt8](message)
        if interior.first == 0xF0 { interior.removeFirst() }
        if interior.last == 0xF7 { interior.removeLast() }

        var words: [UInt32] = []
        if interior.count <= maxBytesPerPacket {
            appendPacket(interior[...], status: .complete, to: &words)
            return words
        }
        var index = 0
        while index < interior.count {
            let n = Swift.min(maxBytesPerPacket, interior.count - index)
            let status: Status =
                index == 0 ? .start
                : (index + n == interior.count ? .end : .continue)
            appendPacket(interior[index ..< index + n], status: status, to: &words)
            index += n
        }
        return words
    }

    private static func appendPacket(_ bytes: ArraySlice<UInt8>, status: Status,
                                     to words: inout [UInt32]) {
        let b = Array(bytes)
        var w0: UInt32 = (messageType << 28)                 // group nibble = 0
            | (status.rawValue << 20)
            | (UInt32(b.count) << 16)
        if b.count > 0 { w0 |= UInt32(b[0]) << 8 }
        if b.count > 1 { w0 |= UInt32(b[1]) }
        var w1: UInt32 = 0
        if b.count > 2 { w1 |= UInt32(b[2]) << 24 }
        if b.count > 3 { w1 |= UInt32(b[3]) << 16 }
        if b.count > 4 { w1 |= UInt32(b[4]) << 8 }
        if b.count > 5 { w1 |= UInt32(b[5]) }
        words.append(w0)
        words.append(w1)
    }

    /// How many 32-bit words the UMP message beginning with `firstWord`
    /// occupies, per the UMP message-type table. Used to walk a packet's
    /// word stream and skip non-SysEx traffic without misparsing it.
    public static func wordCount(firstWord: UInt32) -> Int {
        switch firstWord >> 28 {
        case 0x0, 0x1, 0x2, 0x6, 0x7: return 1
        case 0x3, 0x4, 0x8, 0x9, 0xA: return 2
        case 0xB, 0xC: return 3
        default: return 4      // 0x5, 0xD, 0xE, 0xF
        }
    }
}

/// Reassembles inbound UMP SysEx7 packet streams into complete F0..F7
/// SysEx messages. Value type; the owner serializes access (the transport
/// guards it with a lock because CoreMIDI's receive block runs on a
/// CoreMIDI-owned thread).
///
/// Tear rules (mirroring the phase-0 rtmidi adapter's reassembly):
/// - a `start` or `complete` while a partial is pending DROPS the torn
///   partial and proceeds with the new message;
/// - a `continue` or `end` with no pending partial is dropped;
/// - non-type-3 UMP messages are ignored (the transport drops non-SysEx
///   MIDI at the adapter — §10 deviation 7);
/// - a malformed byteCount (> 6) or reserved status nibble (0x4–0xF) is
///   ignored without touching any pending partial.
///
/// The group nibble is ignored on inbound: the port is connected to exactly
/// one source (no promiscuous listening), and the MicroFreak's translated
/// MIDI 1.0 traffic arrives on a single group, so cross-group interleaving
/// cannot occur on this connection.
public struct SysEx7Assembler: Sendable {
    private var partial: [UInt8]?

    public init() {}

    /// Consume one 64-bit UMP message. Returns a complete SysEx message
    /// (F0..F7) when this packet finishes one, else nil.
    public mutating func consume(word0: UInt32, word1: UInt32) -> Data? {
        guard word0 >> 28 == SysEx7.messageType else { return nil }
        let count = Int((word0 >> 16) & 0xF)
        guard count <= SysEx7.maxBytesPerPacket,
              let status = SysEx7.Status(rawValue: (word0 >> 20) & 0xF) else {
            return nil       // malformed count or reserved status: ignore
        }
        let all: [UInt8] = [
            UInt8((word0 >> 8) & 0xFF), UInt8(word0 & 0xFF),
            UInt8((word1 >> 24) & 0xFF), UInt8((word1 >> 16) & 0xFF),
            UInt8((word1 >> 8) & 0xFF), UInt8(word1 & 0xFF),
        ]
        let bytes = Array(all.prefix(count))

        switch status {
        case .complete:
            partial = nil                    // drop any torn partial
            return wrap(bytes)
        case .start:
            partial = bytes                  // drop any torn partial
            return nil
        case .continue:
            guard partial != nil else { return nil }   // no pending: dropped
            partial!.append(contentsOf: bytes)
            return nil
        case .end:
            guard var pending = partial else { return nil }   // no pending: dropped
            pending.append(contentsOf: bytes)
            partial = nil
            return wrap(pending)
        }
    }

    /// Walk a heterogeneous UMP word stream (one MIDIEventPacket's words),
    /// skipping non-SysEx messages by their word counts, and consume every
    /// SysEx7 packet. Returns the complete messages finished by this batch,
    /// in arrival order. A truncated trailing message (fewer words than its
    /// type requires) is dropped.
    public mutating func consume(words: [UInt32]) -> [Data] {
        var out: [Data] = []
        var i = 0
        while i < words.count {
            let n = SysEx7.wordCount(firstWord: words[i])
            guard i + n <= words.count else { break }    // truncated tail
            if words[i] >> 28 == SysEx7.messageType,
               let message = consume(word0: words[i], word1: words[i + 1]) {
                out.append(message)
            }
            i += n
        }
        return out
    }

    private func wrap(_ interior: [UInt8]) -> Data {
        var out = Data(capacity: interior.count + 2)
        out.append(0xF0)
        out.append(contentsOf: interior)
        out.append(0xF7)
        return out
    }
}
