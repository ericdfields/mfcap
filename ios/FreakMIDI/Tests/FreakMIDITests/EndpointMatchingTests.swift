// EndpointMatchingTests.swift — the pure discovery matcher.
// MIDIEndpointInfo values only; no CoreMIDI client, port, or endpoint.

import Testing
@testable import FreakMIDI

private func endpoint(_ id: Int32, _ name: String,
                      offline: Bool = false) -> MIDIEndpointInfo {
    MIDIEndpointInfo(id: id, name: name, isOffline: offline)
}

@Suite("Endpoint hint matching")
struct EndpointMatchingTests {

    @Test func defaultHintsAreThePhase0Trio() {
        #expect(defaultHints == ["microfreak", "micro freak", "arturia microfreak"])
    }

    @Test func matchesArturiaMicroFreakCaseInsensitively() {
        for name in ["Arturia MicroFreak", "MICROFREAK", "microfreak",
                     "Micro Freak MIDI 1"] {
            let match = firstMatch(in: [endpoint(7, name)],
                                   hints: defaultHints, exclude: "mfcap")
            #expect(match?.id == 7, "should match '\(name)'")
        }
    }

    @Test func substringMatchWithinLongerName() {
        let match = firstMatch(in: [endpoint(1, "USB Hub - Arturia MicroFreak Port 1")],
                               hints: defaultHints, exclude: "mfcap")
        #expect(match != nil)
    }

    @Test func nonMatchingNamesYieldNil() {
        let eps = [endpoint(1, "IAC Driver Bus 1"), endpoint(2, "Minilogue XD")]
        #expect(firstMatch(in: eps, hints: defaultHints, exclude: "mfcap") == nil)
    }

    @Test func excludeSkipsOwnVirtualPortsCaseInsensitively() {
        // a virtual port whose name ALSO matches a hint must never win
        let eps = [endpoint(1, "mfcap MicroFreak bridge"),
                   endpoint(2, "MFCAP microfreak spy"),
                   endpoint(3, "Arturia MicroFreak")]
        let match = firstMatch(in: eps, hints: defaultHints, exclude: "mfcap")
        #expect(match?.id == 3)
    }

    @Test func offlineEndpointsAreSkipped() {
        let eps = [endpoint(1, "Arturia MicroFreak", offline: true),
                   endpoint(2, "Arturia MicroFreak")]
        let match = firstMatch(in: eps, hints: defaultHints, exclude: "mfcap")
        #expect(match?.id == 2)
        #expect(firstMatch(in: [endpoint(1, "Arturia MicroFreak", offline: true)],
                           hints: defaultHints, exclude: "mfcap") == nil)
    }

    @Test func firstMatchingEndpointWins() {
        let eps = [endpoint(1, "Arturia MicroFreak A"),
                   endpoint(2, "Arturia MicroFreak B")]
        #expect(firstMatch(in: eps, hints: defaultHints, exclude: "mfcap")?.id == 1)
    }

    @Test func pairRequiresBothSides() {
        let freak = [endpoint(1, "Arturia MicroFreak")]
        let other = [endpoint(9, "IAC Driver Bus 1")]
        #expect(matchMicroFreak(sources: freak, destinations: other,
                                hints: defaultHints, exclude: "mfcap") == nil)
        #expect(matchMicroFreak(sources: other, destinations: freak,
                                hints: defaultHints, exclude: "mfcap") == nil)
        let pair = matchMicroFreak(sources: freak, destinations: freak,
                                   hints: defaultHints, exclude: "mfcap")
        #expect(pair?.source.id == 1)
        #expect(pair?.destination.id == 1)
    }

    @Test func customHintsAndEmptyExclude() {
        let eps = [endpoint(4, "My Synth")]
        #expect(firstMatch(in: eps, hints: ["my synth"], exclude: "") != nil)
        #expect(firstMatch(in: eps, hints: defaultHints, exclude: "") == nil)
    }
}
