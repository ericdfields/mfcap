// AudioSessionCoordinator.swift — the one owner of AVAudioSession while voice
// notes are listening, and the one place that knows what the microphone is
// ACTUALLY hearing.
//
// Why the app owns the session rather than letting a capture API pick a
// device: the whole feature rests on the mic hearing the user and NOT the
// synth. The user wears headphones, so the built-in mic is the correct — and
// only correct — input. Owning the session is what lets us PIN it, read the
// route back, and refuse to transcribe when the pin did not take.
//
// The configuration, in the order iPadOS actually requires:
//
//   1. setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers])
//      .playAndRecord, not .record: .record silences system output, and the
//      audition is a listening exercise. .mixWithOthers so nothing the user
//      has playing is stopped. mode .default, not .measurement: measurement
//      disables the input leveling that rescues speech from an off-axis
//      mouth — which is exactly the geometry here (hands on the keys, iPad
//      on the desk). No voiceProcessing / .voiceChat: it buys nothing for a
//      near-field talker and it fights route pinning.
//   2. setActive(true)
//   3. setPreferredInput(built-in mic) — AFTER activation. Set before, it is
//      routinely ignored: the route is only resolved when the session goes
//      active.
//
// Plus three preferences that all exist to stop iPadOS from interrupting a
// hands-busy session: haptics and system sounds stay allowed, system alerts
// are asked not to interrupt, and a route disconnect must NOT kill the
// session (unplugging headphones should not end the audition).
//
// THE HARD CONSTRAINT this file exists to make visible: iPadOS gives one
// input route per process. The built-in mic and an attached USB interface
// (the user owns an Arturia MiniFuse 2) CANNOT both be captured. Voice notes
// and any future synth-audio capture are mutually exclusive modes. So the
// route is read BACK after pinning and published as `route`: if the live
// input is not the built-in mic, the caller SUSPENDS CAPTURE and says so,
// rather than silently transcribing whatever the interface is passing
// through. That is not advice — `LiveTranscriber` acts on every event this
// type raises, and the listening indicator follows.
//
// THREE NOTIFICATIONS, ALL LANDING OFF THE MAIN THREAD:
//
//   AVAudioSession.routeChangeNotification — posted on a secondary thread.
//   Everything it touches here is @MainActor, so the handler extracts the
//   Sendable bits it needs synchronously and hops.
//
//   AVAudioEngineConfigurationChange — the dangerous one. When the MiniFuse
//   is plugged in mid-session the engine STOPS AND UNINITIALIZES ITSELF and
//   the installed tap goes DEAD WITH NO ERROR THROWN. Nothing throws,
//   nothing returns false; buffers simply stop arriving. The only way to
//   notice is to observe this. And the rebuild must happen OFF the
//   notification queue — tearing an engine down inside its own configuration
//   -change handler is a documented deadlock — so the handler hops to the
//   main actor and raises the event there.
//
//   AVAudioSession.interruptionNotification — Siri, a phone call, another app
//   taking the input. iPadOS deactivates the session and stops the engine, and
//   a configuration change is NOT reliably posted for it, so without this
//   observer the tap simply stops delivering and the capture clock freezes
//   while the indicator still claims the microphone is live.

import AVFoundation
import Foundation
import Observation

@MainActor @Observable
final class AudioSessionCoordinator {

    /// What the session is actually hearing. Three states, not two: "we have
    /// not looked" and "the session has no input route yet" are different
    /// facts from "an interface is live", and only the last of them is a
    /// problem the user can act on.
    enum InputRoute: Equatable {
        /// `refreshRoute()` has never run.
        case unknown
        /// The route reports no inputs at all. Normal BEFORE a recording
        /// session has been configured, and normal again after `deactivate()`
        /// — it is not evidence that anything is wrong.
        case none
        case builtInMic(String)
        /// A USB interface, a headset mic, anything else. THE case capture is
        /// suspended for.
        case other(String)

        var isBuiltInMic: Bool { if case .builtInMic = self { return true }; return false }
    }

    /// Events the session owner must act on. Raised on the MAIN ACTOR, never
    /// from inside a notification handler.
    enum Event: Equatable {
        /// The route was re-read; `route` holds the new value.
        case routeChanged
        /// The engine has already stopped and uninitialized itself; the tap is
        /// dead with nothing thrown.
        case configurationChanged
        case interruptionBegan
        case interruptionEnded(shouldResume: Bool)
    }

    private(set) var route: InputRoute = .unknown

    /// Is the live input route the built-in microphone? False means the
    /// session is hearing something else (a USB interface, a headset mic) and
    /// capture must be suspended rather than trusted — OR that there is no
    /// input route to judge yet, which `route` distinguishes and this flag
    /// deliberately does not.
    var isBuiltInMicLive: Bool { route.isBuiltInMic }
    private(set) var isActive = false
    /// The last configuration failure, in the user's words. nil when fine.
    /// Read by `VoiceNoteModel` when a start throws, because "the iPad
    /// wouldn't hand over the microphone" is a better sentence than whatever
    /// `localizedDescription` an OSStatus produces.
    private(set) var lastError: String?

    /// Installed by whoever owns the engine tap. Called ON THE MAIN ACTOR,
    /// never inside a notification handler.
    @ObservationIgnored var onEvent: (@MainActor (Event) -> Void)?

    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private weak var engine: AVAudioEngine?

    // No deinit: a @MainActor type's deinit is nonisolated and may not touch
    // its isolated storage. `deactivate()` removes the observers on every exit
    // path, and each block captures `[weak self]`, so a token that outlives
    // this object is an inert no-op rather than a dangling call.

    // ------------------------------------------------------------ lifecycle

    /// Configure and activate the session for capture, then pin the built-in
    /// mic and read the route back. Throws only when the session refuses to
    /// configure at all — a route that resolves to the WRONG input is not an
    /// error here, it is a published fact (`route`) the caller acts on,
    /// because there is nothing to fix and plenty to explain.
    func activate(engine: AVAudioEngine) throws {
        self.engine = engine
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .default,
                                    options: [.mixWithOthers])
            try session.setActive(true)
        } catch {
            lastError = "The iPad wouldn't hand over the microphone: "
                + "\(error.localizedDescription)"
            throw error
        }
        // Best-effort, in the sense that none of them are worth failing the
        // whole feature over: each one only makes a running session calmer.
        try? session.setAllowHapticsAndSystemSoundsDuringRecording(true)
        try? session.setPrefersNoInterruptionsFromSystemAlerts(true)
        try? session.setPrefersInterruptionOnRouteDisconnect(false)
        pinBuiltInMic()
        refreshRoute()
        isActive = true
        lastError = nil
        installObservers()
    }

    /// Give the session back. Idempotent, and safe to call from an error path.
    func deactivate() {
        removeObservers()
        onEvent = nil
        engine = nil
        isActive = false
        // .notifyOthersOnDeactivation so whatever we mixed with resumes its
        // own volume instead of staying ducked.
        try? AVAudioSession.sharedInstance()
            .setActive(false, options: [.notifyOthersOnDeactivation])
        // Back to "no input", which is the truth once we no longer hold a
        // recording session — and is NOT the "an interface is live" warning.
        refreshRoute()
    }

    // ---------------------------------------------------------------- route

    /// Ask for the built-in mic. Ignored (silently, by iPadOS) when a route
    /// the system prefers is attached — which is precisely why nothing here
    /// trusts it and `refreshRoute()` always follows.
    func pinBuiltInMic() {
        let session = AVAudioSession.sharedInstance()
        guard let builtIn = session.availableInputs?
            .first(where: { $0.portType == .builtInMic }) else { return }
        try? session.setPreferredInput(builtIn)
    }

    /// Read the TRUE live input and publish it. This is the readback that
    /// makes the one-input-route constraint visible instead of silent.
    func refreshRoute() {
        let current = AVAudioSession.sharedInstance().currentRoute
        guard let input = current.inputs.first else {
            // No inputs is what a session that has never been configured for
            // recording reports, and what one reports again after
            // deactivation. It is an absence of information, not a fault.
            route = .none
            return
        }
        route = input.portType == .builtInMic
            ? .builtInMic(input.portName)
            : .other(input.portName)
    }

    /// The honest one-liner for the readiness rows. nil when there is nothing
    /// to say — including before a session has ever run, when the route is
    /// unknown or empty and iPadOS has not yet resolved anything to warn
    /// about.
    var inputWarning: String? {
        guard case .other(let name) = route else { return nil }
        return "The iPad is listening through '\(name)', not "
            + "its own microphone. iPadOS gives an app one input at a time, so "
            + "an audio interface and the built-in mic can't both be used — "
            + "unplug the interface to take voice notes."
    }

    /// The pre-flight row, which must never claim to have checked something it
    /// has not. Before a session exists there is no input route to read, so
    /// the honest answer is "not yet known", drawn as the third state.
    var readinessRow: (ok: Bool?, text: String) {
        switch route {
        case .unknown, .none:
            return (nil, "The live microphone route is only known once the "
                + "audition starts. If an audio interface is plugged in, "
                + "iPadOS will hand it that one input instead of the built-in "
                + "mic — voice notes suspend themselves and say so if that "
                + "happens.")
        case .builtInMic(let name):
            return (true, "Listening through \u{201C}\(name)\u{201D}. Wear "
                + "headphones so the mic hears you and not the synth.")
        case .other:
            return (false, inputWarning ?? "")
        }
    }

    // -------------------------------------------------------- notifications

    private func installObservers() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default

        // Posted on a secondary thread. Pull out the Sendable reason first,
        // then hop — a Notification is not Sendable and must not cross.
        observers.append(center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil, queue: nil) { [weak self] note in
                let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey]
                    as? UInt
                Task { @MainActor [weak self] in
                    self?.handleRouteChange(reason: raw)
                }
            })

        // The silent killer: the engine has already stopped and uninitialized
        // itself by the time this arrives, and the tap is dead with nothing
        // thrown. Rebuild — but NEVER from inside this handler (tearing the
        // engine down on the notification queue deadlocks). Hop first.
        observers.append(center.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: nil, queue: nil) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.handleConfigurationChange()
                }
            })

        // Siri, a call, another app taking the input. The session is
        // deactivated and the engine stopped; no configuration change is
        // reliably posted, so this is the only warning we get that buffers
        // have stopped arriving.
        observers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil, queue: nil) { [weak self] note in
                let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
                let options = note.userInfo?[AVAudioSessionInterruptionOptionKey]
                    as? UInt ?? 0
                Task { @MainActor [weak self] in
                    self?.handleInterruption(type: raw, options: options)
                }
            })
    }

    private func removeObservers() {
        for token in observers { NotificationCenter.default.removeObserver(token) }
        observers.removeAll()
    }

    private func handleRouteChange(reason: UInt?) {
        refreshRoute()
        if let reason, let kind = AVAudioSession.RouteChangeReason(rawValue: reason) {
            switch kind {
            case .newDeviceAvailable, .oldDeviceUnavailable, .override,
                 .routeConfigurationChange:
                // A new input showing up is exactly the MiniFuse case: ask for
                // the built-in mic again, then read back what we actually got.
                pinBuiltInMic()
                refreshRoute()
            default:
                break
            }
        }
        onEvent?(.routeChanged)
    }

    private func handleConfigurationChange() {
        // Order matters: re-pin and re-read BEFORE anything rebuilds a tap, so
        // the rebuild sees the route we are actually going to keep rather than
        // the one that just went away. Whether a tap is rebuilt AT ALL is the
        // owner's decision, made against `route` — an interface that has just
        // taken the input must not be recorded.
        pinBuiltInMic()
        refreshRoute()
        onEvent?(.configurationChanged)
    }

    private func handleInterruption(type raw: UInt?, options: UInt) {
        guard let raw,
              let kind = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch kind {
        case .began:
            onEvent?(.interruptionBegan)
        case .ended:
            let shouldResume = AVAudioSession.InterruptionOptions(rawValue: options)
                .contains(.shouldResume)
            onEvent?(.interruptionEnded(shouldResume: shouldResume))
        @unknown default:
            break
        }
    }

    /// Re-activate after an interruption ended. Separate from `activate` so a
    /// resume does not reinstall observers or re-run the whole configuration.
    func reactivate() throws {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setActive(true)
        } catch {
            lastError = "The iPad wouldn't hand the microphone back: "
                + "\(error.localizedDescription)"
            throw error
        }
        pinBuiltInMic()
        refreshRoute()
        isActive = true
        lastError = nil
    }
}
