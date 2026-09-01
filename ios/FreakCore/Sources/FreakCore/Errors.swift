// Errors.swift — the complete error surface (errors.py).
//
// One enum replaces the Python class hierarchy; grouping predicates preserve
// the hierarchy's catch ergonomics. All payloads Sendable. Messages mirror
// the Python strings.

import Foundation

public enum TimeoutStage: String, Sendable {
    case nameRead = "name_read"
    case dump
    case nameWriteAck = "name_write_ack"
}

public enum WriteStage: String, Sendable {
    case nameWrite = "name_write"
    case open
    case go
    case chunk
    case finalRead = "final_read"
}

public struct VerifyMismatch: Sendable, Equatable {
    public let slot: Int
    public let expectedSha256: String          // "" for a rename verify
    public let actualSha256: String?
    public let expectedName: String
    public let actualName: String?
    public let firstDifference: Int?
    public let expectedLen: Int
    public let actualLen: Int

    public init(slot: Int, expectedSha256: String, actualSha256: String?,
                expectedName: String, actualName: String?,
                firstDifference: Int?, expectedLen: Int, actualLen: Int) {
        self.slot = slot
        self.expectedSha256 = expectedSha256
        self.actualSha256 = actualSha256
        self.expectedName = expectedName
        self.actualName = actualName
        self.firstDifference = firstDifference
        self.expectedLen = expectedLen
        self.actualLen = actualLen
    }
}

public enum FreakError: Error, Sendable, Equatable, CustomStringConvertible {
    // ProtocolError family
    case protocolViolation(detail: String)
    case slotOutOfRange(slot: Int)
    case blobSize(expected: Int, actual: Int)
    case invalidName(detail: String)
    // TransportError family — adapters wrap EVERY backend failure here,
    // with the backend's own description flattened into `detail`
    case transport(detail: String)
    case transportUnavailable(detail: String)          // parity case; see §10
    case deviceNotFound(inputs: [String], outputs: [String])
    // transaction
    case deviceTimeout(stage: TimeoutStage, slot: Int?)
    case replyMismatch(requestedSlot: Int, repliedSlot: Int?, attempts: Int)
    // WriteError family
    case chunkNotAcked(slot: Int, chunkIndex: Int)
    case writeAborted(stage: WriteStage, slot: Int, chunksSent: Int, underlying: String?)
    case verifyMismatch(VerifyMismatch)
    // cancellation
    case cancelled(done: Int, total: Int)
    // restore's ".completed" attachment (Python sets e.completed dynamically)
    indirect case restoreStopped(completed: [WriteReport], underlying: FreakError)
    // stored data
    case integrity(path: String, detail: String)
    // LibraryError family
    case entryNotFound(entryID: String)
    case libraryCorrupt(path: String, detail: String)
    case libraryExists(path: String)                   // Python FileExistsError
    case libraryNotFound(path: String)                 // Python FileNotFoundError
    // precondition failures (Python ValueError)
    case snapshotMissingHashes                         // diff on hash-less snapshot
    case snapshotMissingBlobs                          // importSnapshot without kept blobs

    // ---------------------------------------------------------- predicates

    /// Python `isinstance(e, ProtocolError)`.
    public var isProtocolError: Bool {
        switch self {
        case .protocolViolation, .slotOutOfRange, .blobSize, .invalidName:
            return true
        default:
            return false
        }
    }

    /// Python `isinstance(e, TransportError)`.
    public var isTransportError: Bool {
        switch self {
        case .transport, .transportUnavailable, .deviceNotFound:
            return true
        default:
            return false
        }
    }

    /// Python `isinstance(e, WriteError)`.
    public var isWriteError: Bool {
        switch self {
        case .chunkNotAcked, .writeAborted, .verifyMismatch:
            return true
        default:
            return false
        }
    }

    /// Python `isinstance(e, LibraryError)`.
    public var isLibraryError: Bool {
        switch self {
        case .entryNotFound, .libraryCorrupt, .libraryExists, .libraryNotFound:
            return true
        default:
            return false
        }
    }

    // --------------------------------------------------------- description

    public var description: String {
        switch self {
        case .protocolViolation(let detail):
            return detail
        case .slotOutOfRange(let slot):
            return "slot \(slot) out of range"
        case .blobSize(let expected, let actual):
            return "blob is \(actual) bytes, expected \(expected)"
        case .invalidName(let detail):
            return detail
        case .transport(let detail):
            return detail
        case .transportUnavailable(let detail):
            return detail
        case .deviceNotFound(let inputs, let outputs):
            return "No MicroFreak MIDI port found.\n"
                + "  inputs seen:  \(inputs)\n"
                + "  outputs seen: \(outputs)"
        case .deviceTimeout(let stage, let slot):
            let suffix = slot.map { " (slot \($0))" } ?? ""
            return "device timeout during \(stage.rawValue)" + suffix
        case .replyMismatch(let requested, let replied, let attempts):
            let rep = replied.map(String.init) ?? "nil"
            return "asked for slot \(requested), device kept answering for "
                + "slot \(rep) after \(attempts) attempts"
        case .chunkNotAcked(let slot, let chunkIndex):
            return "no 0x18 ack for chunk \(chunkIndex) writing slot \(slot)"
        case .writeAborted(let stage, let slot, let chunksSent, let underlying):
            let cause = underlying.map { ": \($0)" } ?? ""
            return "write to slot \(slot) aborted at stage '\(stage.rawValue)' "
                + "(\(chunksSent) chunks sent)" + cause
        case .verifyMismatch(let m):
            var detail: [String] = []
            if let actualName = m.actualName, actualName != m.expectedName {
                detail.append("name '\(actualName)' != '\(m.expectedName)'")
            }
            if let actualSha = m.actualSha256, actualSha != m.expectedSha256 {
                detail.append("sha \(actualSha.prefix(12)) != \(m.expectedSha256.prefix(12))")
            }
            let tail = detail.isEmpty ? "mismatch" : detail.joined(separator: "; ")
            return "verify failed for slot \(m.slot): " + tail
        case .cancelled(let done, let total):
            return "operation cancelled after \(done)/\(total)"
        case .restoreStopped(let completed, let underlying):
            return "restore stopped after \(completed.count) slots: \(underlying.description)"
        case .integrity(let path, let detail):
            return "\(path): \(detail)"
        case .entryNotFound(let entryID):
            return "no library entry \(entryID)"
        case .libraryCorrupt(let path, let detail):
            return "\(path): \(detail)"
        case .libraryExists(let path):
            return "\(path): a library already exists here — use "
                + "Library.open(); create() will not overwrite an index"
        case .libraryNotFound(let path):
            return "\(path): no library here — create one"
        case .snapshotMissingHashes:
            return "diff requires a snapshot with blob hashes"
        case .snapshotMissingBlobs:
            return "importSnapshot requires a snapshot with blobs "
                + "(snapshot(readBlobs: true, keepBlobs: true))"
        }
    }
}
