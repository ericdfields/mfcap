// DeviceOperations.swift — the single device-operation queue (UX §1.3, §18.2).
//
// The core session serializes; the app models this as ONE queue with ONE
// status surface. Quick ops (writes, renames, single reads) run FIFO behind
// exclusive long ops (backup, restore, full compare). The status bar renders
// `current` + `queued`; the Operations popover adds `recent`. Cancellation is
// Task cancellation (architecture spec §6) — there is no token type.

import Foundation
import FreakCore

@MainActor @Observable
final class DeviceOperation: Identifiable {
    enum Kind: Equatable, Sendable { case quick, long }
    enum Phase: Equatable, Sendable {
        case queued
        case running
        case succeeded
        case failed(String)
        case cancelled
    }

    nonisolated let id = UUID()
    let label: String
    let kind: Kind
    /// Slot the op targets, when it targets exactly one (row activity glyphs).
    let slot: SlotID?
    var phase: Phase = .queued
    /// Secondary status: "verifying", "queued behind backup", …
    var subLabel: String?
    var progress: ProgressEvent?
    var startedAt: Date?
    var finishedAt: Date?
    fileprivate var cancelAction: (@MainActor () -> Void)?

    init(label: String, kind: Kind, slot: SlotID?) {
        self.label = label
        self.kind = kind
        self.slot = slot
    }

    var isActive: Bool { phase == .queued || phase == .running }

    func cancel() { cancelAction?() }

    /// "Backup running — 2:10 left" (per-row disabled reason, UX §5).
    var busyLine: String {
        if let eta = progress?.etaSeconds {
            return "\(label) — \(Format.clock(eta)) left"
        }
        return label
    }
}

@MainActor @Observable
final class DeviceOperationQueue {
    /// Active (queued or running) operations, FIFO order.
    private(set) var active: [DeviceOperation] = []
    /// Finished operations, newest first, capped.
    private(set) var recent: [DeviceOperation] = []
    private var tail: Task<Void, Never>?

    var current: DeviceOperation? { active.first { $0.phase == .running } }
    var queued: [DeviceOperation] { active.filter { $0.phase == .queued } }

    /// A running exclusive long op, if any — quick device actions disable
    /// with this op's `busyLine` as the inline reason (UX §5 states).
    var exclusiveLongOp: DeviceOperation? {
        active.first { $0.kind == .long && $0.phase == .running }
    }

    /// Enqueue one device operation. The closure receives a ProgressReporter
    /// to pass to the FreakCore call (nil for quick ops without progress);
    /// the queue is the reporter's single consumer and republishes events to
    /// `operation.progress` and `onProgress` on the MainActor.
    @discardableResult
    func enqueue<T: Sendable>(
        _ label: String,
        kind: DeviceOperation.Kind = .quick,
        slot: SlotID? = nil,
        onProgress: (@MainActor (ProgressEvent) -> Void)? = nil,
        operation: @escaping @Sendable (ProgressReporter?) async throws -> T
    ) -> Task<T, Error> {
        let op = DeviceOperation(label: label, kind: kind, slot: slot)
        active.append(op)
        if exclusiveLongOp != nil {
            op.subLabel = "queued behind \(exclusiveLongOp?.label ?? "operation")"
        }

        let wantsProgress = kind == .long || onProgress != nil
        var bridge: ProgressBridge?
        if wantsProgress {
            bridge = ProgressBridge { [weak op] event in
                op?.progress = event
                onProgress?(event)
            }
        }
        let reporter = bridge?.reporter
        let previous = tail

        let work = Task { @MainActor [weak self] () throws -> T in
            // FIFO gate: wait for everything already enqueued.
            await previous?.value
            if Task.isCancelled {
                op.phase = .cancelled
                op.finishedAt = Date()
                self?.retire(op)
                throw FreakError.operationCancelled(done: 0, total: 0)
            }
            op.phase = .running
            op.subLabel = nil
            op.startedAt = Date()
            do {
                let value = try await operation(reporter)
                op.phase = .succeeded
                op.finishedAt = Date()
                self?.retire(op)
                return value
            } catch let error as FreakError {
                if case .operationCancelled = error {
                    op.phase = .cancelled
                } else {
                    op.phase = .failed(error.userMessage)
                }
                op.finishedAt = Date()
                self?.retire(op)
                throw error
            } catch is CancellationError {
                op.phase = .cancelled
                op.finishedAt = Date()
                self?.retire(op)
                throw FreakError.operationCancelled(done: 0, total: 0)
            } catch {
                op.phase = .failed(String(describing: error))
                op.finishedAt = Date()
                self?.retire(op)
                throw error
            }
        }
        op.cancelAction = { work.cancel() }

        // Extend the gate; drain the progress bridge after the op exits.
        let bridgeToFinish = bridge
        tail = Task { @MainActor in
            _ = try? await work.value
            await bridgeToFinish?.finish()
        }
        return work
    }

    private func retire(_ op: DeviceOperation) {
        active.removeAll { $0.id == op.id }
        recent.insert(op, at: 0)
        if recent.count > 20 { recent.removeLast(recent.count - 20) }
    }

    func reset() {
        for op in active { op.cancel() }
    }
}

// -------------------------------------------------------- error text helper

extension FreakError {
    /// The user-facing message for toasts and op records. FreakCore's
    /// LocalizedError conformance carries the information content; this only
    /// guarantees a non-empty string.
    var userMessage: String {
        errorDescription ?? String(describing: self)
    }
}
