// AuditionView.swift — play through unrated presets on the synth, one tap
// per verdict. Designed for standing at the MicroFreak with the iPad beside
// it: one preset name in big type, four large verdict targets, nothing else
// to read.

import SwiftUI
import FreakCore

struct AuditionView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if model.audition.isActive {
                sessionScreen
            } else {
                startScreen
            }
        }
        .navigationTitle("Audition")
        .onAppear { model.audition.adoptDefaultSlot(model) }
    }

    // ------------------------------------------------------------ start

    private var startScreen: some View {
        let queue = model.audition.queuePreview(model)
        let expendable = model.audition.expendableSlots(model)
        return Form {
            Section {
                LabeledContent("Unrated presets in view") { Text("\(queue.count)") }
                Text("Narrow the library (category, tags, search) to audition a "
                     + "subset — whatever the library list shows and hasn't "
                     + "been judged yet is the queue.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Audition slot") {
                Picker("Slot to borrow", selection: Bindable(model.audition).slot) {
                    ForEach(expendable.isEmpty ? [Wire.slots - 1] : expendable, id: \.self) { s in
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
            if case .failed(let why) = model.audition.phase {
                Section {
                    Label(why, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            }
            Section {
                Button {
                    model.audition.start(model)
                } label: {
                    Label("Start auditioning", systemImage: "play.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(queue.isEmpty || model.device == nil)
                if model.device == nil {
                    Text("Connect the MicroFreak (or enter practice mode) first.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Text("If the synth's display doesn't change when a preset loads, "
                     + "turn on Utility → MIDI → Program Change Receive on the "
                     + "MicroFreak.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    // ------------------------------------------------------------ session

    private var sessionScreen: some View {
        VStack(spacing: 28) {
            if model.connection.isPractice {
                Label("Practice mode — nothing is playing on a real synth",
                      systemImage: "waveform.slash")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            switch model.audition.phase {
            case .starting:
                ProgressView("Saving slot \(SlotID(model.audition.slot).display)…")
            case .loading:
                ProgressView("Loading next preset…")
            case .playing:
                if let entry = model.audition.current {
                    VStack(spacing: 8) {
                        Text(entry.name)
                            .font(.system(size: 44, weight: .bold, design: .rounded))
                            .multilineTextAlignment(.center)
                        Text(origin(of: entry))
                            .font(.title3).foregroundStyle(.secondary)
                        HStack(spacing: 8) {
                            CategoryBadge(category: entry.category)
                            ForEach(entry.tags, id: \.self) { TagChip(tag: $0) }
                        }
                    }
                    Text("Play it. Then file it.")
                        .font(.callout).foregroundStyle(.secondary)
                    VerdictChips { model.audition.pick($0) }
                        .padding(.horizontal)
                }
            case .exhausted:
                ContentUnavailableView {
                    Label("That's everything", systemImage: "checkmark.seal")
                } description: {
                    Text("\(model.audition.judged) verdicts filed. Stop to put the "
                         + "slot back the way it was.")
                }
            case .failed(let why):
                ContentUnavailableView {
                    Label("Audition stopped", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(why)
                }
            case .idle:
                EmptyView()
            }
            Spacer(minLength: 0)
            HStack {
                Text("\(model.audition.total - model.audition.remaining) of "
                     + "\(model.audition.total)")
                    .monospacedDigit().foregroundStyle(.secondary)
                Spacer()
                Button("Skip") { model.audition.skip() }
                    .disabled(model.audition.phase != .playing)
                    .keyboardShortcut(.space, modifiers: [])
                Button("Stop", role: .destructive) { model.audition.stop() }
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.escape, modifiers: [])
            }
            .padding()
        }
        .padding()
    }

    /// "Voltage Forms · slot 3" — which collection(s) this preset came from.
    private func origin(of entry: LibraryEntry) -> String {
        let names = model.collectionsModel.sorted
            .filter { coll in coll.slots.values.contains { $0.sha256 == entry.sha256 } }
            .map(\.name)
        return names.isEmpty ? "Library" : names.joined(separator: " · ")
    }
}

#Preview("Audition") {
    PreviewHost { _ in
        NavigationStack { AuditionView() }
    }
}
