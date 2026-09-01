// ProgressBridge.swift — a FreakCore ProgressReporter pumped onto the
// MainActor (architecture spec §6 usage pattern).
//
// ProgressReporter's event stream is single-consumer; the bridge is that one
// consumer and fans events out to a @MainActor sink, in order. Used by
// DeviceOperationQueue so every long operation has exactly one progress
// surface (UX §1.3).

import Foundation
import FreakCore

/// Disambiguation: the iOS 27 SDK's Foundation ships its own
/// `ProgressReporter`; every unqualified use in this app means FreakCore's.
typealias ProgressReporter = FreakCore.ProgressReporter

@MainActor
struct ProgressBridge {
    /// Hand this to the FreakCore call's `progress:` parameter.
    let reporter: ProgressReporter
    private let pump: Task<Void, Never>

    /// `sink` runs on the MainActor for every event, in order.
    init(sink: @escaping @MainActor (ProgressEvent) -> Void) {
        let reporter = ProgressReporter()
        self.reporter = reporter
        self.pump = Task { @MainActor in
            for await event in reporter.events {
                sink(event)
            }
        }
    }

    /// Idempotent: FreakCore operations finish() the reporter on every exit
    /// path themselves; this covers operations that never touched it.
    func finish() async {
        reporter.finish()
        await pump.value
    }
}
