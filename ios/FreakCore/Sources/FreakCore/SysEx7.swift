// SysEx7.swift — pure UMP SysEx7 encode / streaming reassembly. NO CoreMIDI
// import; fully unit-tested headless (SysEx7Tests).
//
// CoreMIDI on iOS 17 is used through the UMP APIs with MIDI protocol 1.0.
// In UMP, SysEx travels as 64-bit SysEx7 packets (message type 0x3): status
// nibble 0 = complete, 1 = start, 2 = continue, 3 = end; a byte-count nibble
// (0–6); and up to six 7-bit data bytes per packet. The F0/F7 framing bytes
// are NOT carried in UMP data — the adapter strips them on send and restores
// them on receive.
//
// Packet layout (two UInt32 words, big-endian field order per the UMP spec):
//
//     word0 = [mt:4][group:4][status:4][byteCount:4][data1:8][data2:8]
//     word1 = [data3:8][data4:8][data5:8][data6:8]

import Foundation

public enum SysEx7 {
    static let messageType: UInt32 = 0x3
    static let maxAssembly = 8 * 1024      // runaway guard; largest real frame is 45 bytes

    /// One complete SysEx message (F0..F7) -> UMP words, group 0. Payload
    /// (the bytes between F0 and F7) is split into 6-byte groups: a single
    /// group emits status "complete"; otherwise "start", then "continue"*,
    /// then "end". Throws .protocolViolation when `message` lacks F0/F7
    /// framing or any inner byte > 0x7F.
    public static func encode(_ message: Data) throws -> [UInt32] {
        let bytes = [UInt8](message)
        guard bytes.count >= 2, bytes.first == 0xF0, bytes.last == 0xF7 else {
            throw FreakError.protocolViolation(
                detail: "SysEx7.encode requires F0..F7 framing, got \(bytes.count) bytes")
        }
        let payload = Array(bytes[1..<(bytes.count - 1)])
        if let bad = payload.firstIndex(where: { $0 > 0x7F }) {
            throw FreakError.protocolViolation(detail: String(
                format: "SysEx payload byte %d is 0x%02X: must be 7-bit clean",
                bad, payload[bad]))
        }
        var words: [UInt32] = []
        let groups = stride(from: 0, to: max(payload.count, 1), by: 6).map {
            Array(payload[$0..<min($0 + 6, payload.count)])
        }
        for (i, group) in groups.enumerated() {
            let status: UInt32
            if groups.count == 1 {
                status = 0x0                       // complete
            } else if i == 0 {
                status = 0x1                       // start
            } else if i == groups.count - 1 {
                status = 0x3                       // end
            } else {
                status = 0x2                       // continue
            }
            words.append(contentsOf: pack(status: status, bytes: group))
        }
        return words
    }

    static func pack(status: UInt32, bytes: [UInt8]) -> [UInt32] {
        precondition(bytes.count <= 6)
        var b = bytes
        b += [UInt8](repeating: 0, count: 6 - b.count)
        let word0 = (messageType << 28)
            | (0 << 24)                            // group 0
            | (status << 20)
            | (UInt32(bytes.count) << 16)
            | (UInt32(b[0]) << 8)
            | UInt32(b[1])
        let word1 = (UInt32(b[2]) << 24)
            | (UInt32(b[3]) << 16)
            | (UInt32(b[4]) << 8)
            | UInt32(b[5])
        return [word0, word1]
    }

    /// Streaming reassembler — a value-type state machine, one instance per
    /// source. Never throws: malformed input drops state.
    ///
    /// | state      | event (status)      | action -> next state             |
    /// |------------|---------------------|----------------------------------|
    /// | idle       | complete (0)        | emit F0+bytes+F7 -> idle         |
    /// | idle       | start (1)           | buffer = bytes -> assembling     |
    /// | idle       | continue (2)/end (3)| drop (orphan) -> idle            |
    /// | assembling | start (1)           | discard old, buffer = bytes      |
    /// | assembling | continue (2)        | append -> assembling             |
    /// | assembling | end (3)             | append, emit -> idle             |
    /// | assembling | complete (0)        | discard old, emit this one       |
    /// | any        | mt != 0x3           | ignore packet, state unchanged   |
    /// | assembling | buffer > 8 KiB      | drop buffer -> idle              |
    public struct Assembler: Sendable {
        private var assembling = false
        private var buffer: [UInt8] = []

        public init() {}

        /// Feed one 64-bit SysEx7 packet. Returns a complete F0..F7 message
        /// when this packet finishes one, else nil.
        public mutating func consume(word0: UInt32, word1: UInt32) -> Data? {
            guard (word0 >> 28) & 0xF == SysEx7.messageType else {
                return nil                          // not SysEx7; state unchanged
            }
            let status = (word0 >> 20) & 0xF
            let count = Int((word0 >> 16) & 0xF)
            guard count <= 6 else {
                return nil                          // out-of-range count: drop packet
            }
            let raw: [UInt8] = [
                UInt8((word0 >> 8) & 0xFF), UInt8(word0 & 0xFF),
                UInt8((word1 >> 24) & 0xFF), UInt8((word1 >> 16) & 0xFF),
                UInt8((word1 >> 8) & 0xFF), UInt8(word1 & 0xFF),
            ]
            let bytes = Array(raw.prefix(count))
            switch status {
            case 0x0:                               // complete (discards any partial)
                assembling = false
                buffer = []
                return Data([0xF0] + bytes + [0xF7])
            case 0x1:                               // start (discards any partial)
                assembling = true
                buffer = bytes
                return nil
            case 0x2:                               // continue
                guard assembling else { return nil } // orphan: drop
                buffer += bytes
                return guardRunaway()
            case 0x3:                               // end
                guard assembling else { return nil } // orphan: drop
                buffer += bytes
                if buffer.count > SysEx7.maxAssembly {
                    reset()
                    return nil
                }
                let message = Data([0xF0] + buffer + [0xF7])
                reset()
                return message
            default:
                return nil                          // unknown status: drop packet
            }
        }

        public mutating func reset() {
            assembling = false
            buffer = []
        }

        private mutating func guardRunaway() -> Data? {
            if buffer.count > SysEx7.maxAssembly {
                reset()
            }
            return nil
        }
    }
}
