// History.swift — the local slot-history journal (UX §15).
//
// One journal per device identity ("hardware", "practice:<profile>") in
// Documents/history.json, written by AppModel on each event, capped at 50
// events per slot. Purely an app-side observation log — never rendered as
// truth about the synth (the header caveat in SlotDetailView is mandatory
// copy). History is excluded from cross-identity views.

import Foundation

struct SlotHistoryEvent: Identifiable, Codable, Sendable, Equatable {
    enum Kind: String, Codable, Sendable {
        case observed          // snapshot observation (name, sha when read)
        case verifiedWrite     // source + name + sha
        case rename            // old → new
        case restore           // which backup
        case verifyFailure
        case tornWrite
        case cancelledBatch
    }

    var id = UUID()
    let kind: Kind
    let date: Date
    let summary: String        // one-line, pre-composed at record time
    var sha256: String?

    var icon: String {
        switch kind {
        case .observed: return "eye"
        case .verifiedWrite: return "checkmark.seal"
        case .rename: return "pencil"
        case .restore: return "arrow.uturn.backward.circle"
        case .verifyFailure: return "exclamationmark.triangle"
        case .tornWrite: return "bolt.trianglebadge.exclamationmark"
        case .cancelledBatch: return "stop.circle"
        }
    }
}

/// Documents/history.json: { "<identity stamp>": { "<slot raw>": [events…] } }
@MainActor @Observable
final class SlotHistoryStore {
    static let perSlotCap = 50

    private let url: URL
    /// identity stamp → slot raw → newest-first events
    private var journals: [String: [Int: [SlotHistoryEvent]]] = [:]
    /// Bumped on every record so views re-read.
    private(set) var revision = 0

    init(url: URL) {
        self.url = url
        load()
    }

    func record(_ kind: SlotHistoryEvent.Kind, slot: SlotID,
                identity: DeviceIdentity, summary: String,
                sha256: String? = nil) {
        guard identity != .none else { return }
        var events = journals[identity.stamp, default: [:]][slot.raw, default: []]
        events.insert(SlotHistoryEvent(kind: kind, date: Date(),
                                       summary: summary, sha256: sha256),
                      at: 0)
        if events.count > Self.perSlotCap {
            events.removeLast(events.count - Self.perSlotCap)
        }
        journals[identity.stamp, default: [:]][slot.raw] = events
        revision += 1
        save()
    }

    /// Newest-first events for one slot under one identity only (UX §15).
    func events(slot: SlotID, identity: DeviceIdentity) -> [SlotHistoryEvent] {
        journals[identity.stamp]?[slot.raw] ?? []
    }

    // ------------------------------------------------------------ disk I/O

    private struct FileShape: Codable {
        var journals: [String: [String: [SlotHistoryEvent]]]
    }

    private func load() {
        guard let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(FileShape.self, from: data)
        else { return }
        for (identity, slots) in file.journals {
            var bySlot: [Int: [SlotHistoryEvent]] = [:]
            for (key, events) in slots {
                if let raw = Int(key) { bySlot[raw] = events }
            }
            journals[identity] = bySlot
        }
    }

    private func save() {
        var out: [String: [String: [SlotHistoryEvent]]] = [:]
        for (identity, slots) in journals {
            var byKey: [String: [SlotHistoryEvent]] = [:]
            for (raw, events) in slots { byKey[String(raw)] = events }
            out[identity] = byKey
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(FileShape(journals: out)) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
