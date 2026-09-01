// HardwareTransportProvider.swift — the app's single hardware integration
// point (UX §12, architecture spec §12.2, §14).
//
// Wraps FreakCore's CoreMIDI-backed factory behind a platform-neutral face:
// endpoint enumeration for the Connect screen's live list, likely-match
// labeling (the same hints as the core's discovery), and device construction.
// Everything returned to AppModel is `any FreakDeviceProtocol`.

import Foundation
import FreakCore

/// One connectable candidate shown on the Connect screen.
struct HardwareEndpoint: Identifiable, Hashable, Sendable {
    let name: String
    let sourceID: Int32
    let destinationID: Int32
    let likelyMatch: Bool

    var id: String { "\(name)#\(sourceID)/\(destinationID)" }
}

enum HardwareTransportProvider {

    /// Is a hardware path even possible in this build?
    static var isAvailable: Bool {
        #if canImport(CoreMIDI)
        return true
        #else
        return false
        #endif
    }

    /// Pairs of (source, destination) endpoints sharing a display name —
    /// the Connect screen's list. Never throws; empty when MIDI is silent.
    static func endpoints() -> [HardwareEndpoint] {
        #if canImport(CoreMIDI)
        let seen = CoreMIDITransport.endpoints()
        let hints = CoreMIDITransport.defaultHints
        var out: [HardwareEndpoint] = []
        for source in seen.sources {
            // A usable device needs both directions; pair by display name.
            guard let dest = seen.destinations.first(where: {
                $0.name == source.name
            }) else { continue }
            let lowered = source.name.lowercased()
            guard !lowered.contains("mfcap") else { continue }  // our own proxy
            let likely = hints.contains { lowered.contains($0.lowercased()) }
            out.append(HardwareEndpoint(name: source.name,
                                        sourceID: source.uniqueID,
                                        destinationID: dest.uniqueID,
                                        likelyMatch: likely))
        }
        return out.sorted { ($0.likelyMatch ? 0 : 1, $0.name)
                          < ($1.likelyMatch ? 0 : 1, $1.name) }
        #else
        return []
        #endif
    }

    /// True when a likely MicroFreak is currently visible (hot-plug banner).
    static func microFreakVisible() -> Bool {
        endpoints().contains { $0.likelyMatch }
    }

    /// Open the device. nil endpoint = discovery by hint (the core's own
    /// matching); explicit endpoint = the user's pick from the list.
    /// Throws .deviceNotFound (listing every port seen) / .transport.
    static func openDevice(_ endpoint: HardwareEndpoint?) throws
        -> any FreakDeviceProtocol {
        #if canImport(CoreMIDI)
        guard let endpoint else {
            return try FreakDeviceFactory.hardware()
        }
        let seen = CoreMIDITransport.endpoints()
        guard
            let source = seen.sources.first(where: {
                $0.uniqueID == endpoint.sourceID
            }),
            let destination = seen.destinations.first(where: {
                $0.uniqueID == endpoint.destinationID
            })
        else {
            throw FreakError.deviceNotFound(
                inputs: seen.sources.map(\.name),
                outputs: seen.destinations.map(\.name))
        }
        let transport = try CoreMIDITransport.open(source: source,
                                                   destination: destination)
        return MicroFreakDevice(transport: transport)
        #else
        throw FreakError.transportUnavailable(
            detail: "CoreMIDI is unavailable on this platform")
        #endif
    }
}
