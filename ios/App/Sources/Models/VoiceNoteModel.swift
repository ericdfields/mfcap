// VoiceNoteModel.swift — spoken notes attached to the preset that was playing
// when they were said.
//
// THE SITUATION this model is shaped by: the user is standing at the
// MicroFreak wearing HEADPHONES, so the microphone hears them and not the
// synth. Their hands are on the keys. That rules out push-to-talk (no hand
// free), a wake word (no public API, and it would mean continuous
// transcription anyway), and per-preset restarts of the recognizer. What is
// left is continuous, VAD-gated listening for the whole audition session,
// opt-in and default OFF, with attribution done by TIMELINE.
//
// ---------------------------------------------------------------- the rules
//
// ONE ANALYZER for the whole session (see VoiceNoteTranscriber). The session
// keeps SEGMENTS — (entryID, start, end?) — on the capture clock, and two
// rules decide which preset a sentence belongs to:
//
//   DEFERRED BOUNDARY. The user advances manually, so every boundary is a
//   deliberate tap at a known instant T_tap. But a tap can land mid-sentence:
//   "that pad is gorgeous, keep— [tap] —it". A boundary requested while an
//   utterance is in flight (any volatile result whose end is past T_tap) does
//   not commit; it commits when that utterance finalizes, or after 3 seconds,
//   whichever comes first. The cap matters: a recognizer that never finalizes
//   (a cough held open by room noise) must not park every later note on the
//   wrong preset forever.
//
//   MIDPOINT ASSIGNMENT. A finalized result belongs to the segment containing
//   the MIDPOINT of its range — not its start (a sentence begun about the old
//   preset while reaching for the tap) and not its end (a sentence begun after
//   the tap that the recognizer back-dated).
//
// Neither rule is load-bearing on its own: the visible live transcript under
// the preset name plus one-tap "move to previous preset" is what actually
// makes a misattribution cheap. The rules only make it rare.
//
// TWO BUFFERS, NOT AN ACCUMULATOR. `SpeechTranscriber` re-emits the utterance
// in flight over and over as it revises it. A running transcript that appends
// every result reads "that pad that pad is that pad is gorgeous". So there
// are exactly two: `finalizedTranscript`, appended to only by FINAL results,
// and `volatileTranscript`, REPLACED wholesale by each volatile result and
// cleared when the utterance finalizes. That replacement IS the
// de-duplication.
//
// ---------------------------------------------------------- the trust rules
//
// Everything captured here is stored VERBATIM (docs/voice-notes.md §3) in a
// per-entry sidecar. Extraction output is advisory and lives in `proposals`.
// NOTHING in this file writes a verdict, a category or a tag: a proposal only
// PRE-AIMS the existing controls, and the canonical setters are called only
// from `accept…`, which is only ever reached by a user's tap. A mishearing
// therefore costs one glance and no data.
//
// AND NO AUDIO IS EVER WRITTEN. Not a temp file, not a ring buffer, not in a
// debug build. `audioStart`/`audioEnd` are seconds on the session clock — an
// offset into a timeline that no longer exists once the session ends. That is
// what the microphone purpose string promises, and this file is where it is
// kept.

import AVFoundation
import Foundation
import FreakCore
import Observation
import Speech

/// The end-of-session catch-all: everything captured, per preset, in visit
/// order. A SNAPSHOT — the sheet outlives the session that produced it, so it
/// must not read live model state that `endSession()` has already cleared.
struct NoteReviewRequest: Identifiable {
    let id = UUID()
    let sessionID: String
    /// (entry id, its notes) in the order the session visited the presets.
    let sections: [Section]

    struct Section: Identifiable {
        var id: String { entryID }
        let entryID: String
        let notes: [PresetNote]
    }

    var noteCount: Int { sections.reduce(0) { $0 + $1.notes.count } }
}

@MainActor @Observable
final class VoiceNoteModel {

    /// The opt-in, persisted. Default OFF, and it stays off until the user
    /// turns it on in the audition setup — never at launch, never implicitly.
    static let defaultsKey = "MFVoiceNotes"

    /// Can this iPad do it at all? Three distinguishable answers, because
    /// "never on this iPad" and "not yet" are different sentences.
    enum Support: Equatable {
        /// Below iPadOS 26. The feature is ABSENT — one explanatory line and
        /// nothing else. There is deliberately no older-API fallback.
        case unsupportedOS
        /// iPadOS 26+, but `SpeechTranscriber.isAvailable` is false.
        case transcriberUnavailable
        case available
    }

    enum Permission: Equatable { case notDetermined, granted, denied }

    /// The on-device model. Transcription itself is offline; only this
    /// one-time fetch needs the network, and it is shown with real progress
    /// rather than a spinner that means nothing.
    enum Assets: Equatable {
        case unknown
        case checking
        case installing(Double)
        case installed
        case unsupportedLocale(String)
        case failed(String)
    }

    // ------------------------------------------------------------- published

    private(set) var support: Support = .unsupportedOS
    private(set) var permission: Permission = .notDetermined
    private(set) var assets: Assets = .unknown
    /// A session is ARMED: a transcriber exists and results are being read.
    /// Not the same thing as the microphone being live — see `isCapturing`.
    private(set) var isListening = false
    private(set) var isMuted = false
    /// Why capture stopped when it was not the user's doing (backgrounded,
    /// the route moved off the built-in mic, an interruption, the recognizer
    /// died). Written by `handleCaptureStatus`, which every one of those
    /// causes now routes through — a suspension that nothing reported would
    /// leave the pill claiming the microphone is live over a dead one.
    private(set) var suspendedReason: String?
    private(set) var failure: String?

    /// The microphone is live RIGHT NOW. THE predicate the in-app listening
    /// indicator is drawn from, because App Review 2.5.14 asks for an
    /// indication of the microphone being in use and an indicator that is on
    /// while nothing is being heard is worse than none: it teaches the user
    /// that the light means nothing.
    var isCapturing: Bool { isListening && suspendedReason == nil }

    /// Final text for the preset on screen, appended to only by final results.
    private(set) var finalizedTranscript = ""
    /// The utterance in flight. Replaced wholesale, never appended.
    private(set) var volatileTranscript = ""
    /// What the user sees under the preset name, within about a second of
    /// saying it — the real defence against a misattribution going unnoticed.
    var liveTranscript: String {
        [finalizedTranscript, volatileTranscript]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Notes captured THIS session, per entry, in arrival order.
    private(set) var captured: [String: [PresetNote]] = [:]
    /// The presets this session has visited, in order. "Previous preset" is
    /// defined by this list and nothing else.
    private(set) var visitOrder: [String] = []

    /// The advisory layer for the preset on screen. All three PRE-AIM the
    /// existing controls; none of them has changed anything.
    private(set) var heardVerdict: NoteProposal?
    /// The literal words heard — `heard "keep it"`, not `heard "keep"`. The
    /// user can tell a lucky guess from a real hit.
    private(set) var heardVerdictPhrase: String?
    private(set) var heardCategory: NoteProposal?
    private(set) var heardTags: [NoteProposal] = []
    /// The literal words behind a ghosted chip, for the same reason the
    /// verdict caption exists: `Bright` offered because the user said
    /// "sparkly" is a very different claim from `Bright` offered because they
    /// said "bright", and only one of them is worth checking.
    private(set) var heardCategoryPhrase: String?
    private(set) var heardTagPhrases: [String: String] = [:]

    /// The end-of-session review, presented by RootView once the session
    /// screen is gone.
    var review: NoteReviewRequest?

    /// How many utterances the content gate threw away. Key clatter, breath
    /// and headphone bleed mostly transcribe to one word or none.
    private(set) var suppressedCount = 0
    /// Bumped on every ingested result. Tests spin on it to know a streamed
    /// result has landed.
    private(set) var resultsHandled = 0

    let audio = AudioSessionCoordinator()

    /// The opt-in toggle. Turning it ON does the expensive, interruptive work
    /// once — permission, then the model download — so that Start does not
    /// stall behind a system prompt with the user's hands on the keys.
    var enabled: Bool {
        didSet {
            guard oldValue != enabled else { return }
            UserDefaults.standard.set(enabled, forKey: Self.defaultsKey)
            if enabled { Task { await prepare() } }
        }
    }

    /// True when a `ScriptedTranscriber` is standing in for the real one. The
    /// setup panel says so: on the Simulator every readiness row would
    /// otherwise be green over a microphone that is never opened.
    var isScripted: Bool { injected != nil }

    // ------------------------------------------------------------- internals

    @ObservationIgnored private var transcriber: (any VoiceNoteTranscribing)?
    @ObservationIgnored private let injected: (any VoiceNoteTranscribing)?
    @ObservationIgnored private weak var app: AppModel?
    @ObservationIgnored private var library: Library?
    @ObservationIgnored private var resultsTask: Task<Void, Never>?
    /// Appends are serialized through one chain so two notes finalized back to
    /// back are written in the order they were said. It is NOT what makes a
    /// sidecar write safe against a concurrent edit — that is `Library`'s
    /// atomic `mutateNotes` / `moveNote` / `removeNote`, which every other
    /// writer here goes through. A chain only orders the writers that join it,
    /// and the ones that used to bypass it were the ones losing notes.
    @ObservationIgnored private var writeChain: Task<Void, Never>?

    @ObservationIgnored private(set) var sessionID = ""
    @ObservationIgnored private var localeID = "en-US"
    @ObservationIgnored private var deviceIdentityStamp = "none"

    /// (entry, start, end?) on the capture clock. §4's attribution table.
    private struct Segment {
        let entryID: String
        let start: Double
        var end: Double?
    }
    @ObservationIgnored private var segments: [Segment] = []
    /// The preset whose NAME IS ON SCREEN. Not the same thing as the last
    /// segment's entry: while a boundary is deferred the timeline still
    /// belongs to the previous preset for up to three seconds, but the user is
    /// already looking at the next one. The live transcript, the ghosted chips
    /// and the pre-aimed verdict all follow the screen, or they would spend
    /// those seconds describing a preset that is no longer visible.
    @ObservationIgnored private var displayedEntryID: String?
    /// A boundary the user has asked for whose commit is waiting on an
    /// utterance to finish.
    @ObservationIgnored private var pendingBoundary: (entryID: String, tapTime: Double)?
    /// The instant `closeCurrent()` was called — the real tap, captured
    /// BEFORE the device write that loads the next preset, which can take a
    /// second and would otherwise be charged to the wrong side of the line.
    @ObservationIgnored private var pendingTapTime: Double?
    @ObservationIgnored private var boundaryTimer: Task<Void, Never>?
    /// The end of the utterance currently in flight, or nil when nothing is.
    @ObservationIgnored private var volatileEnd: Double?
    @ObservationIgnored private var lastFinal: VoiceNoteResult?
    /// Finalized utterances that arrived before the first segment existed —
    /// said while the borrowed slot's original was still being read. Replayed
    /// onto the first preset as soon as there is one.
    @ObservationIgnored private var preSegmentFinals: [VoiceNoteResult] = []
    /// The end-of-session review is offered once per session, no matter how
    /// many exits ask for it.
    @ObservationIgnored private var reviewOffered = false
    /// `prepare()` is in flight; a second call would put two permission
    /// prompts and two downloads in the air.
    @ObservationIgnored private var preparing = false

    /// §4's cap on how long a boundary may wait for an utterance to end.
    let boundaryCap: Double = 3.0

    // ------------------------------------------------------------------ init

    /// `transcriber` is injected by tests, #Previews and the Simulator, where
    /// `SpeechTranscriber` does not exist. In the app it is nil and a
    /// `LiveTranscriber` is built per session.
    init(transcriber: (any VoiceNoteTranscribing)? = nil) {
        injected = transcriber
        enabled = UserDefaults.standard.bool(forKey: Self.defaultsKey)
        support = Self.detectSupport(injected: transcriber != nil)
    }

    private static func detectSupport(injected: Bool) -> Support {
        if injected { return .available }
        if #available(iOS 26, *) {
            return LiveTranscriber.isFrameworkAvailable
                ? .available : .transcriberUnavailable
        }
        return .unsupportedOS
    }

    /// The single line shown below iPadOS 26, and the reason there is no
    /// fallback path to write instead.
    static let unsupportedLine =
        "Voice notes need iPadOS 26 or later — the on-device transcriber this "
        + "feature is built on doesn't exist before that. The older speech API "
        + "sends audio to a server, which would break the promise this feature "
        + "makes."

    // -------------------------------------------------------- arm / readiness

    /// Permission and the on-device model, in that order, both at ARM time —
    /// never at launch. The microphone prompt should arrive when the user has
    /// just asked for the microphone, not the first time they open a librarian.
    func prepare() async {
        guard support == .available else { return }
        preparing = true
        defer { preparing = false }
        failure = nil
        await requestPermission()
        guard permission == .granted else { return }
        await ensureModelInstalled()
    }

    /// Arm-time preparation for a session that is ABOUT to start, called from
    /// the audition setup panel's `.task`.
    ///
    /// WITHOUT THIS THE FEATURE IS DEAD FOR EVERY RETURNING USER. `prepare()`
    /// used to be reachable only from `enabled`'s `didSet`, and Swift does not
    /// run `didSet` for a value assigned in `init` — so a toggle restored from
    /// UserDefaults as `true` never triggered it. `permission` stayed
    /// `.notDetermined` and `assets` stayed `.unknown` forever, `canCapture`
    /// was false, `beginSession` returned at its guard, and the user auditioned
    /// a whole queue with the panel telling them the microphone would be asked
    /// for and the model was being checked. Nothing was. The only workaround
    /// was to toggle off and on again, which nobody would ever find.
    ///
    /// Idempotent and cheap to call on every appearance: it does nothing once
    /// permission is granted and the model is installed, nothing while a
    /// download is running, and nothing when the user has said no.
    func prepareIfNeeded() async {
        guard enabled, support == .available, !preparing, !isListening else { return }
        guard permission != .denied else { return }
        switch assets {
        case .checking, .installing, .unsupportedLocale, .failed:
            // Already looked, or already told the user the answer. Retrying a
            // failed download behind their back would just re-fail silently.
            guard permission != .granted else { return }
        case .unknown, .installed:
            break
        }
        guard permission != .granted || assets != .installed else { return }
        await prepare()
    }

    func requestPermission() async {
        if injected != nil {          // Simulator / tests: nothing to ask.
            permission = .granted
            return
        }
        let granted = await AVAudioApplication.requestRecordPermission()
        permission = granted ? .granted : .denied
    }

    /// `AssetInventory.status -> reserve -> assetInstallationRequest ->
    /// downloadAndInstall`, with the request's own Progress polled so the row
    /// shows a real percentage. Transcription is offline; this fetch is the
    /// only thing that ever touches the network.
    func ensureModelInstalled() async {
        guard support == .available else { return }
        if injected != nil {
            assets = .installed
            return
        }
        guard #available(iOS 26, *) else { return }
        assets = .checking
        guard let locale = await SpeechTranscriber
            .supportedLocale(equivalentTo: Locale.current) else {
            assets = .unsupportedLocale(Locale.current.identifier)
            return
        }
        localeID = locale.identifier(.bcp47)
        let modules = Self.speechModules(locale: locale)
        switch await AssetInventory.status(forModules: modules) {
        case .installed:
            assets = .installed
            return
        case .unsupported:
            assets = .unsupportedLocale(locale.identifier)
            return
        case .downloading, .supported:
            break
        @unknown default:
            break
        }
        do {
            _ = try await AssetInventory.reserve(locale: locale)
            guard let request = try await AssetInventory
                .assetInstallationRequest(supporting: modules) else {
                assets = .installed
                return
            }
            assets = .installing(0)
            let progress = request.progress
            let poll = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self, case .installing = self.assets else { return }
                    self.assets = .installing(progress.fractionCompleted)
                    try? await Task.sleep(for: .milliseconds(250))
                }
            }
            defer { poll.cancel() }
            try await request.downloadAndInstall()
            assets = .installed
        } catch {
            assets = .failed(error.localizedDescription)
        }
    }

    @available(iOS 26, *)
    private static func speechModules(locale: Locale) -> [any SpeechModule] {
        [SpeechDetector(detectionOptions: .init(sensitivityLevel: .medium),
                        reportResults: false),
         SpeechTranscriber(locale: locale,
                           preset: .timeIndexedProgressiveTranscription)]
    }

    /// Would a session ARM if it started right now?
    ///
    /// Deliberately no route term. The live input route cannot be read until a
    /// recording session exists, so a pre-flight route test would be a guess;
    /// and the right response to "an interface has the input" is not to refuse
    /// to arm but to arm SUSPENDED and say so, which is what
    /// `LiveTranscriber.start()` does. The session then recovers by itself the
    /// moment the interface is unplugged.
    var canCapture: Bool {
        enabled && support == .available && permission == .granted
            && assets == .installed
    }

    // ------------------------------------------------------------- listening

    /// Called from `AuditionModel.start`. Never opens the microphone unless
    /// the user armed it AND everything it needs is in place.
    func beginSession(app: AppModel) {
        beginSession(app: app, library: app.libraryModel.library,
                     identityStamp: app.deviceIdentity.stamp)
    }

    /// The injectable form. `app` is what the canonical setters go through, so
    /// a session without one still captures, attributes and persists notes —
    /// it simply cannot accept a proposal, which is exactly the surface the
    /// attribution tests want to exercise without building a whole AppModel.
    func beginSession(app: AppModel?, library: Library?,
                      identityStamp: String) {
        guard !isListening else { return }
        // BEFORE the capability guard, deliberately. A run with voice notes
        // OFF must not inherit the last run's advisory layer: `AuditionModel`
        // calls this unconditionally, so returning at the guard with
        // `heardVerdict` still set from the previous session pre-aimed a
        // verdict chip and offered ghosted Type/Characteristic chips on
        // presets nobody had said a word about — the exact misattribution the
        // trust rules exist to prevent, and the worst kind, because it claims
        // to have heard something that was never said in this session at all.
        clearSessionState()
        guard canCapture else { return }
        self.app = app
        self.library = library
        deviceIdentityStamp = identityStamp
        sessionID = UUID().uuidString.replacingOccurrences(of: "-", with: "")
            .lowercased()

        let transcriber = injected ?? makeLiveTranscriber()
        guard let transcriber else { return }
        // Input mute is PROCESS-global and outlives a session: a user who
        // muted during the last audition would otherwise start this one with
        // the hardware still muted while the pill pulsed "Listening" and every
        // sample was zeroed. Set it, do not assume it.
        setMuted(false)
        transcriber.onStatusChange = { [weak self] status in
            self?.handleCaptureStatus(status)
        }
        self.transcriber = transcriber
        isListening = true

        resultsTask = Task { [weak self] in
            for await result in transcriber.results {
                guard let self else { return }
                self.ingest(result)
            }
        }
        Task { [weak self] in
            do {
                try await transcriber.start()
            } catch {
                guard let self else { return }
                // `start()` has already given the audio session back, but this
                // model still holds a transcriber, a results task and an
                // `isListening` it must clear itself — otherwise the next
                // `beginSession` sails past its `!isListening` guard and
                // builds a SECOND analyzer over the first (the
                // insufficientResources risk the one-analyzer rule exists to
                // avoid), and `AuditionModel.endVoiceCapture` never reaches
                // `endSession()` because it gates on exactly the flags this
                // path clears.
                await transcriber.stop()
                self.transcriber = nil
                self.resultsTask = nil
                self.isListening = false
                self.suspendedReason = nil
                self.failure = "Voice notes couldn't start: "
                    + "\(self.audio.lastError ?? error.localizedDescription) "
                    + "The audition is unaffected."
            }
        }
    }

    /// Everything a session owns, back to zero. Called at the START of every
    /// session — including one that will not arm.
    private func clearSessionState() {
        boundaryTimer?.cancel()
        boundaryTimer = nil
        segments.removeAll()
        captured.removeAll()
        visitOrder.removeAll()
        displayedEntryID = nil
        pendingBoundary = nil
        pendingTapTime = nil
        volatileEnd = nil
        lastFinal = nil
        preSegmentFinals.removeAll()
        reviewOffered = false
        review = nil
        suppressedCount = 0
        sessionID = ""
        finalizedTranscript = ""
        volatileTranscript = ""
        suspendedReason = nil
        failure = nil
        clearHeard()
    }

    /// The transcriber says capture stopped, or started again. The one writer
    /// of `suspendedReason` other than backgrounding — and therefore the one
    /// thing standing between "the route moved to the MiniFuse" and a pill
    /// that keeps saying "Listening" while the synth is transcribed.
    func handleCaptureStatus(_ status: VoiceCaptureStatus) {
        switch status {
        case .live:
            suspendedReason = nil
        case .suspended(let why):
            suspendedReason = why
            // A boundary waiting on an utterance that can no longer arrive
            // would sit until its cap; commit it against the clock as it
            // stands, which is where the audio really stopped.
            flushPendingBoundary(at: transcriber?.currentTimelineTime ?? 0)
            volatileTranscript = ""
            volatileEnd = nil
        }
    }

    private func makeLiveTranscriber() -> (any VoiceNoteTranscribing)? {
        guard #available(iOS 26, *) else { return nil }
        let locale = Locale(identifier: localeID)
        return LiveTranscriber(audio: audio, locale: locale)
    }

    /// Drain and shut down. Safe at any point, and safe to call twice.
    ///
    /// `captured` and `visitOrder` deliberately SURVIVE: the review sheet is
    /// presented after the session screen is gone and reads both of them, as
    /// do "move to previous preset" and Discard from inside it. What does not
    /// survive is the advisory layer — a pre-aimed verdict or a ghosted chip
    /// belongs to a preset that is on screen right now, and there is no longer
    /// one.
    func endSession() async {
        boundaryTimer?.cancel()
        boundaryTimer = nil
        // Close the open segment at the clock's end so a final result that
        // arrives during the drain still lands somewhere.
        let now = transcriber?.currentTimelineTime ?? 0
        flushPendingBoundary(at: now)
        if let transcriber {
            transcriber.onStatusChange = nil
            await transcriber.stop()
        }
        resultsTask = nil
        transcriber = nil
        isListening = false
        volatileTranscript = ""
        finalizedTranscript = ""
        volatileEnd = nil
        segments.removeAll()
        displayedEntryID = nil
        pendingBoundary = nil
        pendingTapTime = nil
        clearHeard()
        // Input mute is process-global; leaving it set would silence the next
        // session (and anything else in this process that opens the mic).
        setMuted(false)
        await flushWrites()
    }

    /// The app left the foreground. There is no background-audio entitlement
    /// — deliberately — so the microphone is given back rather than pretending
    /// to keep listening.
    func suspendForBackground() async {
        guard isListening else { return }
        await endSession()
        suspendedReason = "Voice notes stopped when Freak Librarian left the "
            + "screen. The notes taken so far are saved."
    }

    /// The in-app mute, which is also a real mute: `isInputMuted` stops the
    /// hardware, so the indicator and the microphone always agree.
    ///
    /// The published flag is READ BACK from the process rather than assumed,
    /// because that is the only way the two can be kept honest — and the
    /// scripted stand-in never touches the process at all, so a test or a
    /// Simulator run cannot mute the real one.
    func setMuted(_ muted: Bool) {
        guard injected == nil else {
            isMuted = muted
            return
        }
        try? AVAudioApplication.shared.setInputMuted(muted)
        isMuted = AVAudioApplication.shared.isInputMuted
    }

    func toggleMuted() { setMuted(!isMuted) }

    // ------------------------------------------------------------ boundaries

    /// Called as the FIRST statement of `pick` / `skip`. It records only the
    /// instant of the tap: the entry that follows is not known yet, because
    /// the next preset has not been chosen, let alone written to the synth.
    ///
    /// Taking the time here rather than in `markBoundary` is the whole point.
    /// Between the tap and the next preset arriving there is a verified device
    /// write — often more than a second — and anything said in that gap
    /// belongs to the preset the user just judged.
    func closeCurrent() {
        guard isListening else { return }
        pendingTapTime = transcriber?.currentTimelineTime ?? 0
    }

    /// Open a segment for `entryID`. Called from `advance()`, where `current`
    /// is set — so the segment and the name on screen change together.
    func markBoundary(to entryID: String) {
        guard isListening else { return }
        let tap = pendingTapTime ?? transcriber?.currentTimelineTime ?? 0
        pendingTapTime = nil

        // A second advance before the first boundary settled: commit the
        // older one now rather than losing the preset in between.
        if let pending = pendingBoundary {
            pendingBoundary = nil
            boundaryTimer?.cancel()
            boundaryTimer = nil
            applyBoundary(to: pending.entryID, at: pending.tapTime)
        }

        // The display switches immediately even when the timeline boundary is
        // deferred: the preset name on screen has already changed, and a
        // transcript left under it would be a lie about which preset it is
        // about. The tail of the in-flight sentence still goes to the OLD
        // preset — that is the deferral — it just is not shown under the new
        // name while it finishes.
        //
        // The VISIT is recorded here too, for the same reason. Deferring it
        // with the timeline would leave "move to previous preset" pointing at
        // the wrong entry for the first three seconds of every preset, which
        // is exactly when a misattribution is most likely to be noticed.
        displayedEntryID = entryID
        if visitOrder.last != entryID { visitOrder.append(entryID) }
        finalizedTranscript = ""
        volatileTranscript = ""
        recomputeHeard()

        // The first segment of a session has nothing to be deferred behind.
        guard !segments.isEmpty else {
            applyBoundary(to: entryID, at: tap)
            return
        }
        if let volatileEnd, volatileEnd > tap {
            pendingBoundary = (entryID: entryID, tapTime: tap)
            armBoundaryTimer(tapTime: tap)
        } else {
            applyBoundary(to: entryID, at: tap)
        }
    }

    /// The 3-second cap, for the case where no result ever arrives to release
    /// the boundary. The `ingest` path enforces the same cap against the
    /// timeline, so a busy session never depends on this timer.
    private func armBoundaryTimer(tapTime: Double) {
        boundaryTimer?.cancel()
        let cap = boundaryCap
        boundaryTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(cap))
            guard !Task.isCancelled, let self else { return }
            self.flushPendingBoundary(at: tapTime + cap)
        }
    }

    private func flushPendingBoundary(at time: Double) {
        boundaryTimer?.cancel()
        boundaryTimer = nil
        guard let pending = pendingBoundary else { return }
        pendingBoundary = nil
        applyBoundary(to: pending.entryID, at: max(time, pending.tapTime))
    }

    private func applyBoundary(to entryID: String, at time: Double) {
        var start = time
        if var last = segments.last, last.end == nil {
            last.end = max(last.start, time)
            start = last.end ?? time
            segments[segments.count - 1] = last
        }
        segments.append(Segment(entryID: entryID, start: start, end: nil))
        drainPreSegmentFinals()
        recomputeHeard()
    }

    /// The entry a finalized result belongs to: the segment containing the
    /// MIDPOINT of its range. Speech that started before the first boundary
    /// (during the initial slot save) is charged to the first preset rather
    /// than dropped.
    private func entryID(forMidpoint midpoint: Double) -> String? {
        guard let first = segments.first else { return nil }
        if midpoint < first.start { return first.entryID }
        for segment in segments.reversed() where midpoint >= segment.start {
            if let end = segment.end, midpoint >= end { continue }
            return segment.entryID
        }
        return segments.last?.entryID
    }

    /// The entry the session is currently SHOWING — which, during a deferred
    /// boundary, is deliberately not the entry the timeline is still in.
    var currentEntryID: String? { displayedEntryID ?? segments.last?.entryID }

    // --------------------------------------------------------------- ingest

    /// The single entry point for a transcription result — used by the stream
    /// loop above, and called directly by tests so the attribution rules can
    /// be exercised without a microphone.
    func ingest(_ result: VoiceNoteResult) {
        guard isListening else { return }
        resultsHandled += 1

        // The cap, enforced against the TIMELINE rather than wall time: a
        // result that begins more than `boundaryCap` after the tap proves the
        // utterance the boundary was waiting for is over (or never coming).
        if let pending = pendingBoundary,
           result.start >= pending.tapTime + boundaryCap {
            flushPendingBoundary(at: pending.tapTime + boundaryCap)
        }

        guard result.isFinal else {
            // Two-buffer de-duplication: REPLACE, never append.
            volatileTranscript = result.text
                .trimmingCharacters(in: .whitespacesAndNewlines)
            volatileEnd = result.end
            return
        }

        volatileTranscript = ""
        volatileEnd = nil
        // A finalized result is attributed against the segments as they stand
        // BEFORE the deferred boundary commits — which is exactly why the
        // sentence the user was mid-way through stays with the preset they
        // were talking about.
        handleFinal(result)
        if let pending = pendingBoundary {
            flushPendingBoundary(at: max(result.end, pending.tapTime))
        }
    }

    private func handleFinal(_ result: VoiceNoteResult) {
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Defensive: an identical final result repeated is one utterance.
        if let last = lastFinal, last.text == result.text,
           last.start == result.start, last.end == result.end {
            return
        }
        lastFinal = result
        guard !text.isEmpty else { return }
        // §2.9's content gate. Key clatter, breath and headphone bleed almost
        // always transcribe to fewer than two alphabetic tokens, and a
        // library full of one-word notes is worse than no notes.
        guard NoteExtractor.meetsContentGate(text) else {
            suppressedCount += 1
            return
        }
        // Capture starts when the audition does, which is BEFORE the borrowed
        // slot's original has been read and the first preset written — several
        // seconds of "right, let's hear this one then". There is no segment to
        // attribute that to yet, so it is held and replayed onto the first
        // preset the moment one exists. Dropping it instead would silently
        // lose the first thing the user said in every session.
        guard !segments.isEmpty else {
            preSegmentFinals.append(VoiceNoteResult(text: text,
                                                    start: result.start,
                                                    end: result.end,
                                                    isFinal: true))
            return
        }
        store(text: text, result: result)
    }

    private func store(text: String, result: VoiceNoteResult) {
        guard let entryID = entryID(forMidpoint: result.midpoint) else { return }
        let note = PresetNote.new(source: .voice, text: text, locale: localeID,
                                  sessionID: sessionID,
                                  audioStart: result.start,
                                  audioEnd: result.end,
                                  deviceIdentity: deviceIdentityStamp)
        captured[entryID, default: []].append(note)
        if entryID == currentEntryID {
            finalizedTranscript = finalizedTranscript.isEmpty
                ? text : finalizedTranscript + " " + text
        }
        recomputeHeard()
        persist(note, to: entryID)
    }

    /// Replay whatever was said before the first preset existed.
    private func drainPreSegmentFinals() {
        guard !preSegmentFinals.isEmpty, !segments.isEmpty else { return }
        let held = preSegmentFinals
        preSegmentFinals.removeAll()
        for result in held { store(text: result.text, result: result) }
    }

    // ------------------------------------------------------------ proposals

    private func clearHeard() {
        heardVerdict = nil
        heardVerdictPhrase = nil
        heardCategory = nil
        heardTags = []
        heardCategoryPhrase = nil
        heardTagPhrases = [:]
    }

    /// Aggregate this segment's advisory layer.
    ///
    /// The verdict rule is `NoteExtractor.segmentVerdict`'s, restated here so
    /// the CAPTION can quote the literal words: candidates are the last
    /// utterance's verdict plus any utterance of four tokens or fewer, latest
    /// wins. A bare "keep" said early still counts; a "keep" buried mid
    /// sentence was already rejected by the per-utterance positional rule.
    private func recomputeHeard() {
        clearHeard()
        guard let entryID = currentEntryID,
              let notes = captured[entryID], !notes.isEmpty else { return }
        for (index, note) in notes.enumerated() {
            if let verdict = note.proposals.verdict {
                let isLast = index == notes.count - 1
                let isShort = NoteExtractor.tokenize(note.text).count <= 4
                if isLast || isShort {
                    heardVerdict = verdict
                    heardVerdictPhrase = verdict.span(in: note.text)
                        ?? verdict.value
                }
            }
            if let category = note.proposals.category {
                heardCategory = category
                heardCategoryPhrase = category.span(in: note.text)
            }
            for tag in note.proposals.tags
            where !heardTags.contains(where: { $0.value == tag.value }) {
                heardTags.append(tag)
                heardTagPhrases[tag.value] = tag.span(in: note.text)
            }
        }
    }

    /// `heard "sparkly"` for a ghosted chip, or nil.
    ///
    /// nil when the words heard ARE the chip's own label, which is the common
    /// case and where a caption would be noise. It earns its place exactly
    /// when a synonym fired — the one time the user might disagree with the
    /// chip and cannot tell why it appeared.
    private func caption(_ phrase: String?, unlikeTitle title: String) -> String? {
        guard let phrase, !phrase.isEmpty,
              phrase.compare(title, options: [.caseInsensitive]) != .orderedSame
        else { return nil }
        return "heard \u{201C}\(phrase)\u{201D}"
    }

    func ghostedCategoryCaption(_ category: FreakCore.Category) -> String? {
        caption(heardCategoryPhrase, unlikeTitle: category.displayName)
    }

    func ghostedTagCaption(_ tag: String) -> String? {
        caption(heardTagPhrases[tag], unlikeTitle: tag)
    }

    /// The verdict chip to pre-aim, or nil. Never `.unrated` — that is not a
    /// thing anyone says.
    var heardVerdictValue: Verdict? {
        guard let heardVerdict else { return nil }
        let parsed = Verdict.fromSlug(heardVerdict.value)
        return parsed == .unrated ? nil : parsed
    }

    /// `heard "keep it"` — the caption under the pre-aimed chip.
    var heardVerdictCaption: String? {
        guard let phrase = heardVerdictPhrase else { return nil }
        return "heard \u{201C}\(phrase)\u{201D}"
    }

    /// Ghosted TYPE chip for the preset on screen — nil when nothing was
    /// heard, or when the entry already carries it.
    func ghostedCategory(for entry: LibraryEntry) -> FreakCore.Category? {
        guard let heardCategory else { return nil }
        let parsed = FreakCore.Category.fromSlug(heardCategory.value)
        guard parsed != .uncategorized, parsed != entry.category else { return nil }
        return parsed
    }

    /// Ghosted CHARACTERISTIC chips — those the entry does not already carry.
    func ghostedTags(for entry: LibraryEntry) -> [String] {
        heardTags.map(\.value).filter { value in
            !entry.tags.contains { $0.lowercased() == value.lowercased() }
        }
    }

    // ---------------------------------------------------- accepting a proposal
    //
    // §3 rule 3: an accepted proposal is written to its CANONICAL home through
    // the existing library setters, so every filter, census, Python consumer
    // and .mfpreset export sees it with no knowledge that a microphone was
    // involved. The sidecar then records `accepted: true` and nothing more.
    // Delete notes/ and the library is exactly as correct as before.

    /// Each returns whether the whole operation reached disk. Callers that
    /// report success to the user — the review sheet's Apply — must ask,
    /// because a sheet that says "Applied 3 note suggestions" over three
    /// failed writes is worse than one that says nothing.
    @discardableResult
    func acceptVerdict(_ verdict: Verdict, for entryID: String) async -> Bool {
        guard let app else { return false }
        await app.libraryModel.setVerdict(id: entryID, verdict)
        return await recordAcceptance(entryID: entryID) { proposals in
            guard let current = proposals.verdict,
                  current.value == verdict.slug else { return proposals }
            return NoteProposals(verdict: current.accepting(),
                                 category: proposals.category,
                                 tags: proposals.tags)
        }
    }

    @discardableResult
    func acceptCategory(_ category: FreakCore.Category,
                        for entryID: String) async -> Bool {
        guard let app else { return false }
        await app.libraryModel.setCategory(id: entryID, category)
        return await recordAcceptance(entryID: entryID) { proposals in
            guard let current = proposals.category,
                  current.value == category.slug else { return proposals }
            return NoteProposals(verdict: proposals.verdict,
                                 category: current.accepting(),
                                 tags: proposals.tags)
        }
    }

    @discardableResult
    func acceptTag(_ tag: String, for entryID: String) async -> Bool {
        guard let app else { return false }
        await app.libraryModel.addTag(id: entryID, tag)
        return await recordAcceptance(entryID: entryID) { proposals in
            NoteProposals(
                verdict: proposals.verdict,
                category: proposals.category,
                tags: proposals.tags.map {
                    $0.value == tag ? $0.accepting() : $0
                })
        }
    }

    /// Rewrite this entry's notes with the acceptance recorded. `text` is
    /// never touched — only the `accepted` flag inside `proposals` moves, and
    /// only ever from false to true.
    ///
    /// TWO THINGS ARE LOAD-BEARING HERE.
    ///
    /// `mutateNotes` does the read and the write inside ONE actor-isolated
    /// call. Reading with one `await` and replacing with another let a note
    /// finalized in the gap — the everyday case, because a chip is tapped
    /// while the transcriber is still running — be overwritten by the stale
    /// list this method was still holding. It vanished from the sidecar AND
    /// from `captured`, with no throw, and since §1.5 keeps no audio that
    /// verbatim transcript was the only copy that ever existed.
    ///
    /// And the transform is applied ONLY to this session's notes. `accepted`
    /// records what the user confirmed; stamping it onto a note from an
    /// audition two weeks ago — one whose identical proposal they deliberately
    /// did not tap — makes the sidecar claim a confirmation that never
    /// happened, which is the one thing provenance may not do.
    private func recordAcceptance(
        entryID: String,
        _ transform: @escaping @Sendable (NoteProposals) -> NoteProposals
    ) async -> Bool {
        guard let library else { return false }
        let session = sessionID
        do {
            let updated = try await library.mutateNotes(entryID: entryID) { notes in
                notes.map { note in
                    guard session.isEmpty || note.sessionID == session else {
                        return note
                    }
                    return note.recordingAcceptance(transform(note.proposals))
                }
            }
            if captured[entryID] != nil {
                captured[entryID] = updated.filter { $0.sessionID == session }
            }
            recomputeHeard()
            await app?.libraryModel.refreshNotes(force: true)
            return true
        } catch {
            failure = "Couldn't record that in the note: "
                + error.localizedDescription
            return false
        }
    }

    // ------------------------------------------------------ move / discard

    /// The one-tap repair for a misattribution. `audioStart`/`audioEnd` are
    /// unchanged because they are session-relative, not entry-relative.
    ///
    /// `moveNote` appends to the destination BEFORE it removes from the
    /// source, inside one actor call. Doing it the other way round meant a
    /// destination that could not be written (deleted entry, newer sidecar
    /// schema, any write error) destroyed the note instead of moving it.
    @discardableResult
    func moveToPreviousPreset(note: PresetNote, from entryID: String) async -> Bool {
        guard let library,
              let index = visitOrder.lastIndex(of: entryID), index > 0 else {
            failure = "There's no earlier preset in this session to move it to."
            return false
        }
        let destination = visitOrder[index - 1]
        do {
            guard try await library.moveNote(id: note.id, from: entryID,
                                             to: destination) != nil else {
                failure = "That note isn't in this preset's file any more."
                return false
            }
            captured[entryID] = (captured[entryID] ?? [])
                .filter { $0.id != note.id }
            captured[destination, default: []].append(note)
            recomputeHeard()
            await app?.libraryModel.refreshNotes(force: true)
            return true
        } catch {
            failure = "Couldn't move that note: \(error.localizedDescription)"
            return false
        }
    }

    /// Throw a note away. The verbatim text is the only copy there ever was —
    /// no audio was kept — so this is final, and the sheet says so.
    @discardableResult
    func discard(note: PresetNote, from entryID: String) async -> Bool {
        guard let library else { return false }
        do {
            _ = try await library.removeNote(id: note.id, from: entryID)
            captured[entryID] = (captured[entryID] ?? [])
                .filter { $0.id != note.id }
            recomputeHeard()
            await app?.libraryModel.refreshNotes(force: true)
            return true
        } catch {
            failure = "Couldn't discard that note: \(error.localizedDescription)"
            return false
        }
    }

    /// A typed note — the same sidecar, the same extractor, `source: "typed"`.
    @discardableResult
    func addTypedNote(_ text: String, to entryID: String,
                      app: AppModel) async -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let library = app.libraryModel.library else { return false }
        let note = PresetNote.new(
            source: .typed, text: trimmed,
            locale: Locale.current.identifier(.bcp47),
            sessionID: sessionID.isEmpty
                ? UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
                : sessionID,
            audioStart: 0, audioEnd: nil,
            deviceIdentity: app.deviceIdentity.stamp)
        do {
            _ = try await library.appendNote(note, to: entryID)
            await app.libraryModel.refreshNotes(force: true)
            return true
        } catch {
            failure = "Couldn't save that note: \(error.localizedDescription)"
            return false
        }
    }

    // ------------------------------------------------------------ persistence

    private func persist(_ note: PresetNote, to entryID: String) {
        guard let library else { return }
        let previous = writeChain
        writeChain = Task { [weak self] in
            _ = await previous?.value
            do {
                _ = try await library.appendNote(note, to: entryID)
            } catch {
                self?.failure = "Couldn't save that note: "
                    + error.localizedDescription
            }
            await self?.app?.libraryModel.refreshNotes(force: true)
        }
    }

    /// Await every outstanding sidecar write. Used by `endSession` and by
    /// tests that assert on what actually reached disk.
    func flushWrites() async {
        await writeChain?.value
    }

    // ----------------------------------------------------------- the review

    var hasCapturedNotes: Bool { captured.values.contains { !$0.isEmpty } }

    /// Snapshot everything captured for the end-of-session sheet, in visit
    /// order. Taken BEFORE `endSession()` clears the live state.
    ///
    /// Offered ONCE per session. Both `.exhausted` and Stop ask for it, and a
    /// user who has already read the review and closed it must not have it
    /// pushed back in their face when they finally put the slot back.
    func requestReview() {
        guard !reviewOffered, hasCapturedNotes else { return }
        reviewOffered = true
        let sections = visitOrder.compactMap { entryID -> NoteReviewRequest.Section? in
            guard let notes = captured[entryID], !notes.isEmpty else { return nil }
            return NoteReviewRequest.Section(entryID: entryID, notes: notes)
        }
        guard !sections.isEmpty else { return }
        review = NoteReviewRequest(sessionID: sessionID, sections: sections)
    }

    /// The preset before `entryID` in this session, or nil at the start.
    func previousEntryID(before entryID: String) -> String? {
        guard let index = visitOrder.lastIndex(of: entryID), index > 0 else {
            return nil
        }
        return visitOrder[index - 1]
    }
}
