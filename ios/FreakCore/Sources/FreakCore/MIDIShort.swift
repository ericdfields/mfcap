// MIDIShort.swift — the few channel messages the librarian sends (port of
// protocol.py's channel-message builders).
//
// The MicroFreak switches presets on MIDI Program Change ("Program Change
// Receive" in its Utility settings — it can be turned off there, in which
// case selection silently does nothing). 512 presets = 4 banks x 128: Bank
// Select then Program Change. The manual does not say whether the device
// reads the MSB (CC0) or LSB (CC32) bank byte, so both carry the bank index
// (0...3); with only four banks no device combines them. HARDWARE-CONFIRMABLE
// in one try.

import Foundation

public enum MIDIShort {
    public static let ccBankMSB: UInt8 = 0x00
    public static let ccBankLSB: UInt8 = 0x20

    public static func controlChange(channel: UInt8, controller: UInt8,
                                     value: UInt8) -> Data {
        Data([0xB0 | (channel & 0x0F), controller & 0x7F, value & 0x7F])
    }

    public static func programChange(channel: UInt8, program: UInt8) -> Data {
        Data([0xC0 | (channel & 0x0F), program & 0x7F])
    }

    /// The short messages that make the device load `slot` (0-based).
    public static func selectPresetMessages(slot: Int, channel: UInt8 = 0) -> [Data] {
        let bank = UInt8(slot / Wire.slotsPerBank)
        let pos = UInt8(slot % Wire.slotsPerBank)
        return [controlChange(channel: channel, controller: ccBankMSB, value: bank),
                controlChange(channel: channel, controller: ccBankLSB, value: bank),
                programChange(channel: channel, program: pos)]
    }

    /// Pack one channel message as a MIDI 1.0 Channel Voice UMP word
    /// (message type 0x2, group 0): 0x2g ss d1 d2.
    static func umpWord(_ message: Data) -> UInt32? {
        guard let status = message.first, status & 0x80 != 0,
              (0x80...0xEF).contains(status) else { return nil }
        let d1 = message.count > 1 ? UInt32(message[message.startIndex + 1]) : 0
        let d2 = message.count > 2 ? UInt32(message[message.startIndex + 2]) : 0
        return 0x2000_0000 | (UInt32(status) << 16) | (d1 << 8) | d2
    }
}
