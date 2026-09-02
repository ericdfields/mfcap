// AuditionSetupPopover.swift — audition as an ACTION on the list you are
// looking at (UX addendum §30).
//
// The toolbar button snapshots the visible set ONCE, when the popover opens,
// and this view splits it into rated/unrated ONCE, in its init — so a
// 966-entry library is filtered twice on open and never again per body pass.
// The popover states the queue, where it came from, the unrated-only choice,
// and which slot gets borrowed — the four facts the old Audition panel
// buried. Start hands AuditionModel an explicit queue; the running session
// takes over the screen from RootView.

import SwiftUI
import FreakCore

/// The affordance. `build` is called once, when the popover opens.
struct AuditionButton: View {
    @Environment(AppModel.self) private var model
    var titleKey = "Audition…"
    let build: () -> AuditionRequest

    @State private var request: AuditionRequest?

    var body: some View {
        Button {
            request = build()
        } label: {
            Label(titleKey, systemImage: "play.circle")
        }
        .disabled(model.auditionStartBlockReason() != nil)
        .help(model.auditionStartBlockReason()
              ?? "Play these presets on the synth, one verdict each.")
        .popover(item: $request) { request in
            AuditionSetupPopover(request: request)
        }
    }
}

struct AuditionSetupPopover: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let request: AuditionRequest
    /// Filtered once, in init — `queue` and `unratedCount` are read four
    /// times per body pass between them.
    private let unratedCandidates: [LibraryEntry]

    @State private var unratedOnly = true
    /// Remembered between sessions; sequential stays the default because
    /// working through a pack in order is the methodical case.
    @AppStorage("MFAuditionRandomOrder") private var randomOrder = false

    init(request: AuditionRequest) {
        self.request = request
        self.unratedCandidates = request.unratedCandidates
    }

    /// The candidates in display order. Shuffling happens ONCE, in
    /// `AuditionModel.start`, not here — a body-evaluated shuffle would
    /// re-roll on every render and the count would dance under the user.
    private var queue: [LibraryEntry] {
        unratedOnly ? unratedCandidates : request.candidates
    }

    var body: some View {
        @Bindable var audition = model.audition
        let expendable = model.audition.expendableSlots(model)
        return Form {
            Section {
                LabeledContent("Auditioning") {
                    Text("\(queue.count) preset\(queue.count == 1 ? "" : "s")")
                        .monospacedDigit()
                }
                Text(request.sourceLabel)
                    .font(.footnote).foregroundStyle(.secondary)
                if request.unresolvedCount > 0 {
                    Text("\(request.unresolvedCount) preset"
                         + "\(request.unresolvedCount == 1 ? "" : "s") here "
                         + "aren't in the library — they can't be judged and "
                         + "are skipped.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            Section {
                Picker("Queue", selection: $unratedOnly) {
                    Text("Unrated (\(unratedCandidates.count))").tag(true)
                    Text("All (\(request.candidates.count))").tag(false)
                }
                .pickerStyle(.segmented)
                if unratedOnly && unratedCandidates.isEmpty {
                    Text("Everything here has been judged. Switch to All to "
                         + "hear them again — verdicts are overwritten as you "
                         + "go.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Toggle("Random order", isOn: $randomOrder)
                Text(randomOrder
                     ? "Shuffled once when you start, so the count stays "
                       + "honest and nothing repeats."
                     : "Played in list order.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Audition slot") {
                Picker("Slot to borrow", selection: $audition.slot) {
                    ForEach(expendable.isEmpty ? [SlotID.Layout.slots - 1]
                                                : expendable,
                            id: \.self) { s in
                        Text("Slot \(SlotID(s).display)").tag(s)
                    }
                }
                Text(expendable.isEmpty
                     ? "No slot has been judged empty yet — read the device first, "
                       + "or accept the highest slot: it is saved and put back either way."
                     : "Judged empty on the device. Its current contents are saved "
                       + "first and restored when you stop.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            voiceNotesSection
            Section {
                Button {
                    model.audition.start(model, queue: queue,
                                         sourceLabel: request.sourceLabel,
                                         randomOrder: randomOrder)
                    dismiss()
                } label: {
                    Label("Start auditioning", systemImage: "play.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(startDisabled)
                if let reason = startReason {
                    Text(reason)
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Text("If the synth's display doesn't change when a preset loads, "
                     + "turn on Utility → MIDI → Program Change Receive on the "
                     + "MicroFreak.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .frame(idealWidth: 380, idealHeight: 560)
        .onAppear {
            model.audition.adoptDefaultSlot(model)
            // Read the live input route so the one-input-at-a-time fact is on
            // screen BEFORE the user starts, where it can be read. It is only
            // ever a HINT here: iPadOS resolves an input route when a
            // recording session goes active, so before one has existed this
            // reports "no input" and the readiness row says so instead of
            // inventing a verdict.
            model.voiceNotes.audio.refreshRoute()
        }
        // THIS is where the microphone prompt and the model download are
        // triggered — arm time, not launch. And it must be here rather than in
        // `enabled`'s didSet alone: Swift does not run didSet for the value
        // init reads out of UserDefaults, so a user whose toggle was already
        // on from a previous run never prepared anything, and the whole
        // feature was silently dead for them with two readiness rows claiming
        // work that was not happening.
        .task { await model.voiceNotes.prepareIfNeeded() }
    }

    // -------------------------------------------------------- voice notes
    //
    // Honest readiness, one row per thing that can be false, in the order the
    // user can act on them. No row claims a state it has not checked.

    @ViewBuilder
    private var voiceNotesSection: some View {
        @Bindable var voice = model.voiceNotes
        Section("Voice notes") {
            switch model.voiceNotes.support {
            case .unsupportedOS:
                // Below iPadOS 26 the feature is simply absent. One line
                // saying why, and no toggle to tease with.
                Text(VoiceNoteModel.unsupportedLine)
                    .font(.footnote).foregroundStyle(.secondary)
            case .transcriberUnavailable:
                Label("This iPad's speech transcriber isn't available, so "
                      + "voice notes can't run here.",
                      systemImage: "exclamationmark.triangle")
                    .font(.footnote).foregroundStyle(.secondary)
            case .available:
                Toggle("Take notes while I talk", isOn: $voice.enabled)
                // The privacy line, in the same words as the purpose string
                // the system will show. Nothing here is a hedge — and the
                // claim is SCOPED to what the code actually guarantees. No
                // audio is written anywhere, ever, and no speech is ever sent
                // away to be recognized. The transcript itself is saved into
                // the library like any other preset data, which means it
                // travels with the library: an iCloud backup, a copy out of
                // the Files app. Saying "nothing leaves the device" full stop
                // would have been a promise about the library that this
                // feature is in no position to make.
                Text("While a preset is playing, the iPad writes down what you "
                     + "say and attaches it to that preset. Your words are "
                     + "transcribed on this iPad — no audio is recorded or "
                     + "saved, and your speech is never sent anywhere to be "
                     + "recognized. The written notes are stored in your "
                     + "library, so they travel with it in a backup or a copy.")
                    .font(.footnote).foregroundStyle(.secondary)
                if model.voiceNotes.enabled {
                    readinessRows
                }
            }
        }
    }

    @ViewBuilder
    private var readinessRows: some View {
        let voice = model.voiceNotes
        if voice.isScripted {
            // The Simulator / #Preview stand-in. Every row below would
            // otherwise read as a clean bill of health over a microphone that
            // is never opened.
            ReadinessRow(ok: nil, text: "This build transcribes from a script, "
                + "not from the microphone — the speech transcriber is "
                + "hardware-only. Voice notes are here so the screens can be "
                + "seen and tested; nothing is heard.")
        }
        switch voice.permission {
        case .granted:
            ReadinessRow(ok: true, text: "Microphone access granted.")
        case .denied:
            ReadinessRow(ok: false, text: "Microphone access is off for Freak "
                + "Librarian. Turn it on in Settings → Freak Librarian → "
                + "Microphone.")
        case .notDetermined:
            ReadinessRow(ok: nil, text: "Freak Librarian will ask for the "
                + "microphone when you start.")
        }
        switch voice.assets {
        case .installed:
            ReadinessRow(ok: true, text: "On-device speech model installed. "
                + "Transcription works offline.")
        case .installing(let fraction):
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: fraction) {
                    Text("Downloading the speech model")
                        .font(.footnote)
                }
                Text("A one-time download. Transcription itself never uses "
                     + "the network.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        case .checking, .unknown:
            ReadinessRow(ok: nil, text: "Checking for the on-device speech "
                + "model…")
        case .unsupportedLocale(let id):
            ReadinessRow(ok: false,
                         text: "There's no on-device speech model for \(id) yet.")
        case .failed(let why):
            ReadinessRow(ok: false,
                         text: "The speech model couldn't be downloaded: \(why)")
        }
        // The MiniFuse line. iPadOS gives one input route per process, so an
        // attached audio interface and the built-in mic are mutually
        // exclusive — and the app must never quietly transcribe whatever the
        // interface is passing through.
        //
        // Three states, not two. Before any recording session has existed
        // there IS no input route to read, and the old code took that empty
        // route as proof of an interface and told a user with nothing plugged
        // in to unplug it. The row now says what it actually knows, and the
        // enforcement that matters happens in the session, where the route is
        // real: capture suspends itself and explains, rather than starting on
        // the wrong input.
        if !voice.isScripted {
            let route = voice.audio.readinessRow
            ReadinessRow(ok: route.ok, text: route.text)
        }
    }

    private var startDisabled: Bool {
        queue.isEmpty || model.device == nil
            || model.auditionStartBlockReason() != nil
            || model.operations.exclusiveLongOp != nil
    }

    private var startReason: String? {
        if model.device == nil {
            return "Connect the MicroFreak (or enter practice mode) first."
        }
        if let reason = model.auditionStartBlockReason() { return reason }
        if let op = model.operations.exclusiveLongOp { return op.busyLine }
        if queue.isEmpty {
            return "Nothing to play — the queue is empty."
        }
        return nil
    }
}

#Preview("Audition setup") {
    PreviewHost { model in
        AuditionSetupPopover(
            request: AuditionRequest(sourceLabel: "All Presets",
                                     candidates: model.libraryModel.entries))
    }
}
