// OverwritePlan.swift — one plan schema powers every §9 guard rail for
// singles, bulks, and restores (UX §9, §18.2).
//
// Rules it encodes: every overwrite previews its victim; recoverability is
// stated (with Save a Copy First as the escape when it isn't); backup
// freshness appears in every destructive dialog; confirm buttons state the
// action and count, never "OK"; severity scales with blast radius; an
// unjudged victim's primary action is Read First.

import Foundation
import FreakCore

struct OverwritePlan: Identifiable {
    /// How the incoming preset is obtained at execution time.
    enum Incoming: Sendable {
        case preset(Preset)                          // resolved locally already
        case libraryEntry(id: String)                // resolved at execution
        case deviceSlot(SlotID)                      // copy: one read mid-op
        case backupSlot(folderName: String, slot: SlotID)
        case mfFile(MFPresetFile)                    // imported .mfpreset content
    }

    enum Recoverability: Equatable, Sendable {
        case library(entryName: String)
        case backup(stamp: String)
        case none

        /// Exactly one of the §9.2 sentences.
        var line: String {
            switch self {
            case .library(let name):
                return "The current preset is in your library ('\(name)')."
            case .backup(let stamp):
                return "The current preset is in backup \(stamp)."
            case .none:
                return "The current preset is not in your library or any "
                    + "backup — it will be lost."
            }
        }
    }

    enum Victim: Equatable, Sendable {
        case empty(evidence: String)                 // judged empty, evidence shown
        case named(String, recoverable: Recoverability)
        /// Unjudged → Read First primary. A named-but-unhashed slot still
        /// previews its cached name (§9.1) via `knownName`.
        case unknown(knownName: String?)

        var isEmpty: Bool {
            if case .empty = self { return true }
            return false
        }
        var isUnknown: Bool {
            if case .unknown = self { return true }
            return false
        }
        var isUnrecoverable: Bool {
            if case .named(_, .none) = self { return true }
            return false
        }
    }

    struct Item: Identifiable, Sendable {
        let id = UUID()
        let target: SlotID
        let incomingName: String
        let incoming: Incoming
        let victim: Victim
        /// Restore rows without recorded meta are pre-disabled with the
        /// core's own sentence (UX §16.2).
        var disabledReason: String? = nil

        /// "replaces 'Perc Organ'" — drop feedback + plan-sheet rows.
        var victimLine: String {
            switch victim {
            case .empty(let evidence):
                return "replaces empty slot (\(evidence))"
            case .named(let name, _):
                return "replaces '\(name)'"
            case .unknown(let known):
                if let known { return "replaces '\(known)' — contents not read" }
                return "contents unknown"
            }
        }
    }

    enum Kind: Sendable {
        case send            // library/copy/paste/drag → device
        case bulkSync        // sync bulk apply
        case restore         // backup → device
        case undo            // undo/redo re-write (already §9-consented)
    }

    /// §9.5 — severity scales with blast radius.
    enum Severity {
        case popover                     // expendable single target: one tap
        case dialog                      // occupied or unjudged single target
        case planSheet                   // bulk / multi
        case planSheetPlusFinalAlert     // full-device restore
    }

    let id = UUID()
    let kind: Kind
    let items: [Item]
    let title: String
    /// §9.3 backup-freshness footer, captured at plan-build time.
    let freshnessLine: String
    /// §11: overwrite dialogs against practice devices say so in the footer.
    let isPracticeDevice: Bool
    /// Restore plans carry their source folder for execution + history.
    var backupFolderName: String? = nil

    var writeCount: Int {
        items.filter { $0.disabledReason == nil }.count
    }

    /// ~1 s per verified write (UX §17 estimate rule).
    var estimatedDuration: TimeInterval { Double(writeCount) * 1.0 }

    var severity: Severity {
        if case .restore = kind, writeCount >= SlotID.Layout.slots {
            return .planSheetPlusFinalAlert
        }
        if items.count > 1 { return .planSheet }
        guard let only = items.first else { return .dialog }
        return only.victim.isEmpty ? .popover : .dialog
    }

    /// "Replace Preset" / "Write 5 Slots" / "Restore 512 Slots" — never "OK".
    var confirmLabel: String {
        switch kind {
        case .restore:
            return "Restore \(writeCount) Slot\(writeCount == 1 ? "" : "s")"
        case .bulkSync:
            return "Write \(writeCount) Slot\(writeCount == 1 ? "" : "s") to Device"
        case .send, .undo:
            if items.count == 1, let item = items.first {
                if item.victim.isUnknown { return "Overwrite Anyway" }
                return item.victim.isEmpty ? "Send" : "Replace Preset"
            }
            return "Write \(writeCount) Slots"
        }
    }

    /// Dialog title per §9.1 — the judgment evidence is IN the dialog.
    var dialogTitle: String {
        guard items.count == 1, let item = items.first else { return title }
        switch item.victim {
        case .named(let name, _):
            return "Replace \"\(name)\" in slot \(item.target.display)?"
        case .empty(let evidence):
            return "Send to slot \(item.target.display)? "
                + "Currently: empty (\(evidence))"
        case .unknown(let known):
            if let known {
                return "Replace \"\(known)\" in slot \(item.target.display)? "
                    + "Contents not read yet"
            }
            return "Slot \(item.target.display) — contents unknown"
        }
    }
}
