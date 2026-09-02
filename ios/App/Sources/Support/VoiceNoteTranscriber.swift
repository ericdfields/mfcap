// VoiceNoteTranscriber.swift — the speech-to-text seam.
//
// ONE protocol, TWO implementations, for the same reason the device layer has
// `FreakDeviceProtocol` with a hardware transport and `SimulatedMicroFreak`:
// `SpeechTranscriber` is HARDWARE-GATED and does not run in the iOS Simulator
// at all. Without a scripted stand-in there would be no way to test the
// attribution rules, and no way to render a #Preview of the session screen.
//
//   LiveTranscriber      iPadOS 26+, real audio, real Speech framework.
//   ScriptedTranscriber  tests, #Previews, Simulator. Emits exactly the
//                        results a test hands it, on a timeline the test
//                        controls.
//
// Below iPadOS 26 the feature is ABSENT — one explanatory line in the setup
// popover and nothing else. There is deliberately NO SFSpeechRecognizer
// fallback: it is network-based, throttled, capped at about a minute, and
// explicitly less accurate. Shipping it under the same toggle would make the
// privacy purpose string ("transcribed on this iPad… nothing leaves the
// device") a lie, and a promise that is true on some iPads is not a promise.

import AVFoundation
import CoreMedia
import Foundation

#if canImport(Speech)
import Speech
#endif

// ------------------------------------------------------------------ result

/// One transcription result on the SESSION timeline.
///
/// `start` / `end` are seconds measured from the moment the analyzer began —
/// the same clock, and the same units, that `PresetNote.audioStart` /
/// `audioEnd` are stored in. They are a timeline offset and NOTHING else:
/// there is no audio file they could point into, because none is ever
/// written.
///
/// Seconds rather than `CMTime` on purpose. The conversion happens once, at
/// the `LiveTranscriber` boundary, where the timescale is known; every rule
/// downstream (midpoint assignment, the deferred-boundary cap) is arithmetic
/// that `CMTime`'s epoch and timescale only make easier to get wrong.
struct VoiceNoteResult: Sendable, Equatable {
    let text: String
    let start: Double
    let end: Double
    /// Volatile results are re-emitted as the recognizer changes its mind and
    /// are for display only; only a final result is ever persisted.
    let isFinal: Bool

    init(text: String, start: Double, end: Double, isFinal: Bool) {
        self.text = text
        self.start = start
        self.end = end
        self.isFinal = isFinal
    }

    /// The midpoint of the range — the point §4 attributes a finalized result
    /// by, rather than its start or its end.
    var midpoint: Double { (start + end) / 2 }
}

// ---------------------------------------------------------------- protocol

/// Whether the microphone is actually being read RIGHT NOW.
///
/// The pill and the hardware may never disagree, so a transcriber that has
/// stopped hearing anything has to SAY SO rather than leave the model
/// believing a running session is still capturing. Every cause is a sentence
/// the user can act on, because every one of them has a fix (unplug the
/// interface, end the call, stop and start again).
enum VoiceCaptureStatus: Equatable {
    case live
    /// Armed, but no audio is reaching the analyzer. The string is shown
    /// verbatim under the preset name.
    case suspended(String)
}

@MainActor
protocol VoiceNoteTranscribing: AnyObject {
    /// Volatile and final results, in arrival order. Finishes when `stop()`
    /// has drained the analyzer.
    var results: AsyncStream<VoiceNoteResult> { get }
    /// Where the capture clock is NOW, in session-relative seconds. Read at
    /// the instant the user taps, which is what makes a boundary a real point
    /// on the same timeline as the results.
    var currentTimelineTime: Double { get }
    /// Installed by the model before `start()`. Called on the main actor
    /// whenever capture stops or resumes for a reason that is not the user's
    /// doing.
    var onStatusChange: (@MainActor (VoiceCaptureStatus) -> Void)? { get set }
    func start() async throws
    func stop() async
}

// ----------------------------------------------------------- session clock

/// The capture clock: session-relative seconds, advanced on the audio thread
/// and read on the main actor.
///
/// It counts FRAMES THE ANALYZER RECEIVED, converted per buffer by the sample
/// rate it received them at, rather than wall time. Three reasons. Wall time
/// drifts from the audio timeline the transcriber's ranges live on, so a
/// boundary taken from `Date()` would slowly stop lining up with the sentences
/// it is meant to separate. Accumulating seconds per buffer (instead of
/// dividing one running frame count by one sample rate) keeps the timeline
/// continuous across a tap rebuild, where the input format may come back
/// different. And counting only what was actually FED — not what the tap
/// delivered — is what keeps this clock and the transcriber's ranges on one
/// timeline: a dropped buffer must not advance one of them without the other.
final class AudioSessionClock: @unchecked Sendable {
    private let lock = NSLock()
    private var seconds: Double = 0

    var now: Double {
        lock.lock()
        defer { lock.unlock() }
        return seconds
    }

    func advance(frames: AVAudioFrameCount, sampleRate: Double) {
        guard sampleRate > 0, frames > 0 else { return }
        lock.lock()
        seconds += Double(frames) / sampleRate
        lock.unlock()
    }

    func reset() {
        lock.lock()
        seconds = 0
        lock.unlock()
    }
}

// ------------------------------------------------------- scripted stand-in

/// The Simulator / test / #Preview transcriber. Mirrors how
/// `SimulatedMicroFreak` stands in for a synth that is not attached: it is a
/// real implementation of the protocol whose input happens to come from a
/// script instead of a microphone. It opens no audio session, touches no
/// microphone, and needs no permission.
@MainActor
final class ScriptedTranscriber: VoiceNoteTranscribing {
    let results: AsyncStream<VoiceNoteResult>
    private let continuation: AsyncStream<VoiceNoteResult>.Continuation

    private(set) var isRunning = false
    private(set) var startCount = 0
    private(set) var stopCount = 0
    /// Set by a test to make `start()` fail the way a real one can (a route
    /// grabbed mid-activation, another process holding the input), so the
    /// teardown path is exercised without a microphone.
    var startError: (any Error)?

    var onStatusChange: (@MainActor (VoiceCaptureStatus) -> Void)?

    /// Advanced by `emit`, and settable directly so a test can place a tap at
    /// an exact point on the timeline.
    var currentTimelineTime: Double = 0

    init() {
        var escaped: AsyncStream<VoiceNoteResult>.Continuation!
        results = AsyncStream { escaped = $0 }
        continuation = escaped
    }

    func start() async throws {
        startCount += 1
        if let startError {
            // Mirrors LiveTranscriber: a start that throws has already torn
            // itself down, so the model never has to guess whether it owns a
            // half-open session.
            await stop()
            throw startError
        }
        isRunning = true
        onStatusChange?(.live)
    }

    func stop() async {
        isRunning = false
        stopCount += 1
        continuation.finish()
    }

    /// Drive the suspension path from a test without a route change.
    func reportStatus(_ status: VoiceCaptureStatus) { onStatusChange?(status) }

    /// Push one result. The clock advances to the end of the utterance, which
    /// is what a real capture would have done by the time the result arrived.
    func emit(_ result: VoiceNoteResult) {
        currentTimelineTime = max(currentTimelineTime, result.end)
        continuation.yield(result)
    }

    func emit(_ text: String, from start: Double, to end: Double,
              isFinal: Bool = true) {
        emit(VoiceNoteResult(text: text, start: start, end: end,
                             isFinal: isFinal))
    }
}

// --------------------------------------------------------- live transcriber

#if canImport(Speech)

/// The real thing: an `AVAudioEngine` input tap feeding one `SpeechAnalyzer`
/// for the WHOLE audition session.
///
/// One analyzer, never one per preset. A per-preset analyzer risks
/// `insufficientResources` after a few dozen presets, and — worse — loses the
/// first words of every preset during the roughly half-second the analyzer
/// spends starting up. Attribution is therefore done by timeline
/// (`VoiceNoteModel`'s segments), not by restarting the recognizer.
@available(iOS 26, *)
@MainActor
final class LiveTranscriber: VoiceNoteTranscribing {

    let results: AsyncStream<VoiceNoteResult>
    private let resultsContinuation: AsyncStream<VoiceNoteResult>.Continuation

    private let audio: AudioSessionCoordinator
    private let locale: Locale
    private let clock = AudioSessionClock()
    private let engine = AVAudioEngine()

    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var analyzeTask: Task<Void, Never>?
    private var resultsTask: Task<Void, Never>?
    private var analyzerFormat: AVAudioFormat?
    private var tapInstalled = false
    /// What the model was last told. Kept so a repeated route notification
    /// does not spam the same sentence, and so a resume only reports `.live`
    /// when something really changed.
    private var status: VoiceCaptureStatus = .live

    var onStatusChange: (@MainActor (VoiceCaptureStatus) -> Void)?

    var currentTimelineTime: Double { clock.now }

    /// The two sentences a suspended session can show. Both name the fix.
    static let wrongRouteReason =
        "Voice notes are paused: the iPad is listening through an audio "
        + "interface, not its own microphone, and iPadOS only gives an app one "
        + "input at a time. Unplug the interface to take notes again — the "
        + "audition itself is unaffected."
    static let deadTapReason =
        "Voice notes stopped: the microphone input went away and couldn't be "
        + "reopened. Stop and start the audition to try again — the notes "
        + "taken so far are saved."
    static let interruptedReason =
        "Voice notes are paused while something else is using the microphone."

    init(audio: AudioSessionCoordinator, locale: Locale) {
        self.audio = audio
        self.locale = locale
        var escaped: AsyncStream<VoiceNoteResult>.Continuation!
        results = AsyncStream { escaped = $0 }
        resultsContinuation = escaped
    }

    /// Whether the framework can transcribe on this device at all — separate
    /// from "is the model downloaded", and reported separately in the setup
    /// popover, because the two have different answers ("never" vs "not yet").
    static var isFrameworkAvailable: Bool { SpeechTranscriber.isAvailable }

    // ---------------------------------------------------------------- start

    /// Arm the analyzer, then open the microphone. In that order: an analyzer
    /// that is not ready yet would drop the first words while it writes its
    /// working state, and those are usually the ones worth keeping.
    func start() async throws {
        guard analyzer == nil else { return }
        clock.reset()

        let transcriber = SpeechTranscriber(
            locale: locale, preset: .timeIndexedProgressiveTranscription)
        let detector = SpeechDetector(
            detectionOptions: .init(sensitivityLevel: .medium),
            reportResults: false)
        let modules: [any SpeechModule] = [detector, transcriber]
        let analyzer = SpeechAnalyzer(modules: modules)

        self.transcriber = transcriber
        self.analyzer = analyzer

        let format = await SpeechAnalyzer
            .bestAvailableAudioFormat(compatibleWith: modules)
        analyzerFormat = format
        // Does the ~0.5 s of set-up work NOW, while nothing is being said.
        try await analyzer.prepareToAnalyze(in: format)

        // The results loop is a TOP-LEVEL task, deliberately not a child of
        // anything cancellable. On shutdown the analyze task is cancelled and
        // this one must keep reading, or the last sentence of the last preset
        // — the one the user just said about the preset they are judging — is
        // finalized into a stream nobody is listening to.
        // `Task {}` created here inherits this method's MainActor isolation,
        // so the continuation is touched on the actor that owns it.
        resultsTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    guard let self else { return }
                    let start = result.range.start.seconds
                    let end = result.range.end.seconds
                    self.resultsContinuation.yield(VoiceNoteResult(
                        text: String(result.text.characters),
                        start: start.isFinite ? start : 0,
                        end: end.isFinite ? end : 0,
                        isFinal: result.isFinal))
                }
            } catch {
                // A failed recognizer ends the stream; the model reports it
                // as "voice notes stopped" and the audition carries on.
            }
        }

        // Audio last. Session first, then the engine, then the tap.
        //
        // From here on the process OWNS an active .playAndRecord session, so
        // every failure has to give it back. A throw that left the session
        // active held the system microphone indicator on for the rest of the
        // app's life while the app's own indicator — which App Review 2.5.14
        // requires — was hidden, because the model had already cleared
        // `isListening`. `stop()` is the one teardown, and it is idempotent.
        do {
            try audio.activate(engine: engine)
            audio.onEvent = { [weak self] event in self?.handle(event) }

            // Bounded on purpose. The default policy is `.unbounded`: if the
            // analyzer ever falls behind (thermal throttling, an
            // insufficientResources hiccup), converted PCM for the WHOLE stall
            // piles up live in the heap. Nothing writes it anywhere — the
            // §1.5 no-audio promise is about disk and is kept — but audio
            // lifetime should be capped everywhere it can be, and 32 buffers
            // of 4096 frames is under three seconds at 48 kHz.
            let (stream, continuation) = AsyncStream<AnalyzerInput>
                .makeStream(bufferingPolicy: .bufferingNewest(32))
            inputContinuation = continuation
            analyzeTask = Task { [analyzer] in
                _ = try? await analyzer.analyzeSequence(stream)
            }

            // THE ROUTE GATE. iPadOS gives one input per process, so with an
            // interface attached the pin does not take and the tap would read
            // the interface — which is carrying the SYNTH. Arm suspended and
            // say so instead; the session is live and recovers by itself the
            // moment the interface goes away.
            if audio.isBuiltInMicLive {
                try installTapAndStartEngine()
                report(.live)
            } else {
                report(.suspended(Self.wrongRouteReason))
            }
        } catch {
            await stop()
            throw error
        }
    }

    // -------------------------------------------------------------- status

    private func report(_ next: VoiceCaptureStatus) {
        guard next != status else { return }
        status = next
        onStatusChange?(next)
    }

    // ----------------------------------------------------------------- tap

    /// Install the input tap and start the engine. Split out because it is
    /// also the whole of the configuration-change recovery path.
    private func installTapAndStartEngine() throws {
        let input = engine.inputNode
        // Re-read every time: after a configuration change the input format
        // is routinely different, and a tap installed with the old format
        // either throws or silently delivers nothing.
        let tapFormat = input.inputFormat(forBus: 0)
        guard tapFormat.sampleRate > 0, tapFormat.channelCount > 0 else {
            throw NSError(domain: "FreakLibrarian.VoiceNotes", code: 1,
                          userInfo: [NSLocalizedDescriptionKey:
                            "The microphone reported no usable input format."])
        }
        guard let continuation = inputContinuation else { return }
        let context = TapContext(
            source: tapFormat,
            analyzerFormat: analyzerFormat,
            clock: clock,
            sink: continuation)

        if tapInstalled { input.removeTap(onBus: 0) }
        input.installTap(onBus: 0, bufferSize: 4096, format: tapFormat) { buffer, _ in
            context.feed(buffer)
        }
        tapInstalled = true
        engine.prepare()
        try engine.start()
    }

    /// Pull the tap and stop the engine without touching the analyzer, the
    /// input stream or the clock — so a suspension is reversible and the
    /// session timeline stays continuous across it.
    private func suspendCapture() {
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        engine.stop()
    }

    /// Called on the MAIN ACTOR for every event the coordinator raises — never
    /// from inside a notification handler, which deadlocks.
    ///
    /// After an AVAudioEngineConfigurationChange the engine has already
    /// stopped and uninitialized ITSELF and the tap is dead with nothing
    /// thrown. The analyzer, the input stream and the clock all survive: only
    /// the tap is rebuilt, so the notes taken before the MiniFuse was plugged
    /// in keep their attribution.
    private func handle(_ event: AudioSessionCoordinator.Event) {
        guard analyzer != nil else { return }
        switch event {
        case .interruptionBegan:
            // iPadOS has already stopped the engine. No buffers are arriving
            // and the capture clock has stopped with them, so the pill must
            // stop claiming otherwise.
            suspendCapture()
            report(.suspended(Self.interruptedReason))
        case .interruptionEnded(let shouldResume):
            guard shouldResume else {
                report(.suspended(Self.interruptedReason))
                return
            }
            try? audio.reactivate()
            resumeCapture(rebuilding: true)
        case .configurationChanged:
            // The engine has already uninitialized itself: the tap MUST be
            // rebuilt, whatever it looks like from here.
            resumeCapture(rebuilding: true)
        case .routeChanged:
            // A route change that leaves a healthy tap on the built-in mic is
            // nothing to do — headphones going in and out post one of these
            // constantly, and tearing the tap down each time would drop words.
            resumeCapture(rebuilding: false)
        }
    }

    /// The one decision point: capture runs if — and only if — the built-in
    /// mic is the live input and the tap can be rebuilt on it.
    private func resumeCapture(rebuilding: Bool) {
        guard audio.isBuiltInMicLive else {
            // The MiniFuse case. Rebuilding here would tap the interface,
            // which is carrying the synth's own output, and transcribe it into
            // the user's notes as if they had said it.
            suspendCapture()
            report(.suspended(Self.wrongRouteReason))
            return
        }
        guard rebuilding || !tapInstalled || !engine.isRunning else {
            report(.live)
            return
        }
        do {
            try installTapAndStartEngine()
            report(.live)
        } catch {
            // Nothing left to record with. Say so — the previous version left
            // the pill pulsing "Listening" over a dead microphone for the rest
            // of the audition.
            suspendCapture()
            report(.suspended(Self.deadTapReason))
        }
    }

    // ----------------------------------------------------------------- stop

    /// Apple's shutdown order, and the reason for each step:
    ///
    ///   1. stop the engine and pull the tap — no more buffers.
    ///   2. finish the input stream — the analyzer sees a clean end of input.
    ///   3. CANCEL the analyze task.
    ///   4. THEN `finalizeAndFinish(through:)` — this is what turns the last
    ///      in-flight volatile utterance into a final result. Skipping it (or
    ///      doing it before the cancel) loses the last sentence.
    ///   5. await the results task, which was never cancellable, so that last
    ///      final result is actually delivered before the stream closes.
    ///
    /// Also the teardown for a FAILED start: `start()` calls it before
    /// rethrowing, which is what guarantees the audio session is never left
    /// active behind a hidden listening indicator. Everything below tolerates
    /// a half-built session, so calling it twice — or before the tap ever went
    /// in — is a no-op rather than a crash.
    func stop() async {
        guard analyzer != nil || audio.isActive else { return }
        suspendCapture()
        audio.onEvent = nil

        inputContinuation?.finish()
        inputContinuation = nil

        analyzeTask?.cancel()
        analyzeTask = nil

        if let analyzer {
            let through = CMTime(seconds: clock.now, preferredTimescale: 48_000)
            try? await analyzer.finalizeAndFinish(through: through)
        }

        await resultsTask?.value
        resultsTask = nil

        self.analyzer = nil
        transcriber = nil
        resultsContinuation.finish()
        audio.deactivate()
    }
}

/// Everything the audio thread is allowed to touch, and nothing else.
///
/// `@unchecked Sendable` is the honest label: an `AVAudioConverter` is not
/// Sendable, and this box does not make it thread-safe. What makes it safe is
/// that exactly one thread ever calls `feed` — the render thread the tap
/// block runs on — and the box is created fresh for each tap installation, so
/// a rebuilt tap never shares a converter with the old one.
@available(iOS 26, *)
private final class TapContext: @unchecked Sendable {
    private let converter: AVAudioConverter?
    private let analyzerFormat: AVAudioFormat?
    private let clock: AudioSessionClock
    private let sink: AsyncStream<AnalyzerInput>.Continuation

    init(source: AVAudioFormat, analyzerFormat: AVAudioFormat?,
         clock: AudioSessionClock,
         sink: AsyncStream<AnalyzerInput>.Continuation) {
        self.analyzerFormat = analyzerFormat
        self.clock = clock
        self.sink = sink
        if let analyzerFormat, analyzerFormat != source {
            converter = AVAudioConverter(from: source, to: analyzerFormat)
        } else {
            converter = nil
        }
    }

    /// Runs on the render thread. No allocation-free purity claims here — the
    /// output buffer is allocated per call, which is what every Apple sample
    /// does — but absolutely no actor hops, no locks beyond the clock's, and
    /// no throwing.
    ///
    /// THE CLOCK ADVANCES ONLY FOR AUDIO THE ANALYZER ACTUALLY RECEIVES, by
    /// the frame count and sample rate the analyzer receives it at. It has to:
    /// the transcriber's own `CMTimeRange`s advance on exactly that audio, and
    /// the clock is read at every boundary tap to place it on the SAME
    /// timeline. Advancing for a buffer that was dropped (a failed allocation,
    /// a converter error) added a permanent forward offset to every later
    /// boundary — misattribution that never self-corrects and gets worse the
    /// longer the session runs.
    func feed(_ buffer: AVAudioPCMBuffer) {
        guard let converter, let analyzerFormat else {
            clock.advance(frames: buffer.frameLength,
                          sampleRate: buffer.format.sampleRate)
            sink.yield(AnalyzerInput(buffer: buffer))
            return
        }
        let ratio = analyzerFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(
            (Double(buffer.frameLength) * ratio).rounded(.up)) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: analyzerFormat,
                                            frameCapacity: capacity) else {
            return
        }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, outStatus in
            if supplied {
                outStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, output.frameLength > 0 else { return }
        clock.advance(frames: output.frameLength,
                      sampleRate: analyzerFormat.sampleRate)
        sink.yield(AnalyzerInput(buffer: output))
    }
}

#endif
