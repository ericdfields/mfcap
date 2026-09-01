// OpenDevice.swift — the open_device() equivalent.
//
// Hardware and demo are the same type behind the same seam:
//
//     let device = try FreakMIDI.openMicroFreak()                          // hardware
//     let device = MicroFreakDevice(transport: SimulatedMicroFreak.factoryFresh())  // demo
//
// Everything downstream of the device is byte-identical between modes.

import CoreMIDI
import FreakCore

/// Discover the MicroFreak and hand back a ready MicroFreakDevice actor.
///
/// Throws .deviceNotFound (listing every seen display name) when discovery
/// finds no match — the app's cue to offer demo mode — and .transport for
/// any CoreMIDI failure while opening.
///
/// iPadOS lifecycle (§5.2): reconnect by MIDIUniqueID on every
/// MIDISetupMonitor .setupChanged event and on foregrounding; the returned
/// device holds CoreMIDI port refs that survive suspension, so no re-open
/// is needed while both endpoint ids still resolve. On backgrounding, wrap
/// in-flight operations in a UIApplication background task whose expiration
/// handler cancels via CancelToken; owners call close() explicitly when the
/// device disappears.
public func openMicroFreak(hints: [String] = defaultHints,
                           exclude: String = "mfcap") throws -> MicroFreakDevice {
    MicroFreakDevice(transport: try CoreMIDITransport.open(hints: hints, exclude: exclude))
}
