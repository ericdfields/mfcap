// UndoStack.swift — undo where honest (UX §6.6).
//
// An overwrite is undoable exactly when the victim's exact bytes are held
// locally at overwrite time (library blob or covering backup with matching
// sha). Undo enqueues a verified write of the victim back; redo re-sends
// the incoming preset. When bytes are not held, nothing is recorded and no
// undo was promised.

import Foundation
import FreakCore

struct OverwriteRecord: Sendable {
    let slot: SlotID
    let victim: Preset          // the exact bytes that were replaced
    let incoming: Preset        // what replaced them (for redo)
    let description: String     // "Sent 'Fat Bass v2' to slot 510"
}

@MainActor @Observable
final class UndoStack {
    private(set) var undoRecords: [OverwriteRecord] = []
    private(set) var redoRecords: [OverwriteRecord] = []

    var canUndo: Bool { !undoRecords.isEmpty }
    var canRedo: Bool { !redoRecords.isEmpty }

    func record(_ record: OverwriteRecord) {
        undoRecords.append(record)
        redoRecords.removeAll()
        if undoRecords.count > 20 {
            undoRecords.removeFirst(undoRecords.count - 20)
        }
    }

    func popForUndo() -> OverwriteRecord? {
        guard let record = undoRecords.popLast() else { return nil }
        redoRecords.append(record)
        return record
    }

    func popForRedo() -> OverwriteRecord? {
        guard let record = redoRecords.popLast() else { return nil }
        undoRecords.append(record)
        return record
    }

    func reset() {
        undoRecords.removeAll()
        redoRecords.removeAll()
    }
}
