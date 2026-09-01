// MIDIEndpoints.swift — endpoint discovery: listEndpoints, findMicroFreak.
//
// The matching logic (matchMicroFreak / firstMatch) is pure — it operates on
// MIDIEndpointInfo values only, so it is unit-tested without any CoreMIDI
// object. Only the enumerate*/resolve helpers talk to CoreMIDI, and they
// need no MIDI client (MIDIGetNumberOfSources & co. are clientless).
//
// Discovery is a per-backend factory concern, deliberately outside the
// Transport protocol (transport.py parity).

import CoreMIDI
import Foundation

public struct MIDIEndpointInfo: Sendable, Hashable {
    public let id: MIDIUniqueID          // kMIDIPropertyUniqueID — stable reconnect key
    public let name: String              // kMIDIPropertyDisplayName
    public let isOffline: Bool           // kMIDIPropertyOffline

    public init(id: MIDIUniqueID, name: String, isOffline: Bool) {
        self.id = id
        self.name = name
        self.isOffline = isOffline
    }
}

/// Case-insensitive substring hints that identify a MicroFreak endpoint
/// (transports.rtmidi.find_microfreak parity).
public let defaultHints = ["microfreak", "micro freak", "arturia microfreak"]

/// Every MIDI source and destination currently visible, in system order.
/// (`throws` is part of the seam's contract for future backends; the
/// CoreMIDI enumeration itself cannot fail.)
public func listEndpoints() throws -> (sources: [MIDIEndpointInfo],
                                       destinations: [MIDIEndpointInfo]) {
    (enumerateSources().map(\.info), enumerateDestinations().map(\.info))
}

/// First source/destination pair whose display names match a hint —
/// case-insensitive substring match, skipping offline endpoints and names
/// containing `exclude` (so the app's own virtual "mfcap" ports can never
/// match). nil when either side has no match; the caller decides whether
/// that is an error (CoreMIDITransport.open throws .deviceNotFound).
public func findMicroFreak(hints: [String] = defaultHints, exclude: String = "mfcap")
    throws -> (source: MIDIEndpointInfo, destination: MIDIEndpointInfo)? {
    let (sources, destinations) = try listEndpoints()
    return matchMicroFreak(sources: sources, destinations: destinations,
                           hints: hints, exclude: exclude)
}

// ------------------------------------------------------------ pure matching

/// Pure matcher behind findMicroFreak — unit-tested without CoreMIDI.
func matchMicroFreak(sources: [MIDIEndpointInfo], destinations: [MIDIEndpointInfo],
                     hints: [String], exclude: String)
    -> (source: MIDIEndpointInfo, destination: MIDIEndpointInfo)? {
    guard let source = firstMatch(in: sources, hints: hints, exclude: exclude),
          let destination = firstMatch(in: destinations, hints: hints, exclude: exclude)
    else { return nil }
    return (source, destination)
}

func firstMatch(in endpoints: [MIDIEndpointInfo], hints: [String],
                exclude: String) -> MIDIEndpointInfo? {
    let loweredHints = hints.map { $0.lowercased() }
    let loweredExclude = exclude.lowercased()
    return endpoints.first { endpoint in
        guard !endpoint.isOffline else { return false }
        let name = endpoint.name.lowercased()
        if !loweredExclude.isEmpty && name.contains(loweredExclude) { return false }
        return loweredHints.contains { name.contains($0) }
    }
}

// ------------------------------------------------------ CoreMIDI enumeration

struct EndpointHandle {
    let info: MIDIEndpointInfo
    let ref: MIDIEndpointRef
}

func enumerateSources() -> [EndpointHandle] {
    (0 ..< MIDIGetNumberOfSources()).compactMap { i in
        let ref = MIDIGetSource(i)
        guard ref != 0 else { return nil }
        return EndpointHandle(info: endpointInfo(ref), ref: ref)
    }
}

func enumerateDestinations() -> [EndpointHandle] {
    (0 ..< MIDIGetNumberOfDestinations()).compactMap { i in
        let ref = MIDIGetDestination(i)
        guard ref != 0 else { return nil }
        return EndpointHandle(info: endpointInfo(ref), ref: ref)
    }
}

func endpointInfo(_ ref: MIDIObjectRef) -> MIDIEndpointInfo {
    var name = "(unnamed)"
    var unmanaged: Unmanaged<CFString>?
    if MIDIObjectGetStringProperty(ref, kMIDIPropertyDisplayName, &unmanaged) == noErr,
       let cf = unmanaged?.takeRetainedValue() {
        name = cf as String
    }
    var uniqueID: Int32 = 0
    _ = MIDIObjectGetIntegerProperty(ref, kMIDIPropertyUniqueID, &uniqueID)
    var offline: Int32 = 0
    _ = MIDIObjectGetIntegerProperty(ref, kMIDIPropertyOffline, &offline)
    return MIDIEndpointInfo(id: uniqueID, name: name, isOffline: offline != 0)
}

/// Resolve a MIDIUniqueID back to a live endpoint of the expected kind
/// (MIDIObjectFindByUniqueID); nil when the id no longer resolves — the
/// §5.2 reconnect path treats that as "disconnected".
func resolveEndpoint(id: MIDIUniqueID, expecting type: MIDIObjectType) -> MIDIEndpointRef? {
    var object: MIDIObjectRef = 0
    var objectType: MIDIObjectType = .other
    let status = MIDIObjectFindByUniqueID(id, &object, &objectType)
    guard status == noErr, objectType == type, object != 0 else { return nil }
    return object
}
