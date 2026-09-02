// AuditionModel.swift — the app-side driver for FreakCore.AuditionSession:
// borrow one expendable slot, play through the unrated presets one tap at a
// time, file each verdict, put the slot back.
//
// Every device touch goes through the DeviceOperationQueue (quick ops, FIFO
// with everything else), so a running backup or collection switch simply
// queues the audition behind it and the busy line explains why.

import Foundation
import Observation
import FreakCore

@MainActor @Observable
final class AuditionModel {
    enum Phase: Equatable {
        case idle
        case starting          // reading the slot's original
        case loading           // writing + selecting the next preset
        case playing           // a preset is on the synth; awaiting a verdict
        case exhausted         // queue done; slot not yet restored
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var current: LibraryEntry?
    private(set) var remaining = 0
    private(set) var total = 0
    private(set) var judged = 0
    /// The borrowed slot (0-based). Defaults to the highest slot the browser
    /// judged expendable; the user can pick another before starting.
    var slot = Wire.slots - 1

    private var session: AuditionSession?
    private weak var app: AppModel?

    var isActive: Bool {
        switch phase {
        case .idle, .failed: return false
        default: return true
        }
    }

    // ------------------------------------------------------------ queue

    /// What a session started now would play: unrated presets that pass the
    /// library's current facets (category / tags / search), in list order.
    func queuePreview(_ app: AppModel) -> [LibraryEntry] {
        AuditionSession.unrated(app.libraryModel.filtered(tag: nil))
    }

    /// Slots the browser currently judges expendable, highest first — the
    /// safe choices for the audition slot.
    func expendableSlots(_ app: AppModel) -> [Int] {
        app.slots.rows.filter { $0.judgment.isExpendable }
            .map(\.slot.raw).sorted(by: >)
    }

    func adoptDefaultSlot(_ app: AppModel) {
        if let best = expendableSlots(app).first { slot = best }
    }

    // ------------------------------------------------------------ lifecycle

    func start(_ app: AppModel) {
        guard !isActive, let device = app.device,
              let library = app.libraryModel.library else { return }
        let queue = queuePreview(app)
        guard !queue.isEmpty else { return }
        self.app = app
        total = queue.count
        remaining = queue.count
        judged = 0
        current = nil
        phase = .starting
        let s = AuditionSession(device: device, library: library, queue: queue, slot: slot)
        session = s
        app.slots.setBusy(SlotID(slot), true)
        let slotID = SlotID(slot)
        let task = app.operations.enqueue("Audition: saving slot \(slotID.display)",
                                          kind: .quick, slot: slotID) { _ in
            try await s.start()
        }
        Task {
            do {
                _ = try await task.value
                await advance()
            } catch {
                fail(error)
            }
        }
    }

    /// File the verdict for the preset on the synth, then load the next one.
    func pick(_ verdict: Verdict) {
        guard phase == .playing, let s = session, let app else { return }
        phase = .loading
        Task {
            do {
                _ = try await s.verdict(verdict)
                judged += 1
                await app.libraryModel.refresh()
                await advance()
            } catch {
                fail(error)
            }
        }
    }

    /// Move on without judging.
    func skip() {
        guard phase == .playing else { return }
        phase = .loading
        Task { await advance() }
    }

    /// Restore the slot's original and end the session. Safe at any phase.
    func stop() {
        guard let s = session, let app else { reset(); return }
        let slotID = SlotID(slot)
        let task = app.operations.enqueue("Audition: restoring slot \(slotID.display)",
                                          kind: .quick, slot: slotID) { _ in
            try await s.stop()
        }
        Task {
            defer {
                app.slots.setBusy(slotID, false)
                reset()
            }
            do {
                _ = try await task.value
                app.toasts.show("Audition ended — slot \(slotID.display) restored. "
                                + "\(judged) verdict\(judged == 1 ? "" : "s") filed.")
            } catch {
                app.toasts.show("Slot \(slotID.display) could not be restored: "
                                + "\(error.localizedDescription). Restore it from a backup.")
            }
        }
    }

    // ------------------------------------------------------------ internals

    private func advance() async {
        guard let s = session, let app else { return }
        phase = .loading
        let slotID = SlotID(slot)
        let task = app.operations.enqueue("Audition: loading next preset",
                                          kind: .quick, slot: slotID) { _ in
            try await s.next()
        }
        do {
            if let entry = try await task.value {
                current = entry
                remaining = await s.remaining
                phase = .playing
            } else {
                phase = .exhausted
            }
        } catch {
            fail(error)
        }
    }

    private func fail(_ error: Error) {
        phase = .failed(error.localizedDescription)
    }

    private func reset() {
        session = nil
        current = nil
        phase = .idle
        remaining = 0
        total = 0
    }
}
