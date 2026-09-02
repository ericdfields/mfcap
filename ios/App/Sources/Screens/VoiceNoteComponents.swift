// VoiceNoteComponents.swift — the shared visual vocabulary for spoken notes.
//
// Three ideas, each of which exists to keep a promise made in
// docs/voice-notes.md:
//
//   ListeningPill  — the app's OWN indication that the microphone is live,
//                    which App Review guideline 2.5.14 requires (the system
//                    indicator is not enough), doubling as the mute control.
//                    Tapping it really mutes the input, so what the pill says
//                    and what the hardware is doing can never disagree.
//   GhostChip      — a proposal, drawn as something that is NOT yet true: a
//                    dashed outline and a plus. One tap promotes it through
//                    the existing setter (§3 rule 3); until then the entry is
//                    untouched.
//   MarkedTranscript — the verbatim text with the matched spans underlined,
//                    so the user can see exactly which words produced a
//                    proposal rather than trusting a chip that appeared from
//                    nowhere.

import SwiftUI
import FreakCore

/// One readiness fact. `ok == nil` means "not yet known", which is a third
/// state and is drawn as one — a readiness list that only has ticks and
/// crosses lies about what it has checked.
struct ReadinessRow: View {
    let ok: Bool?
    let text: String

    var body: some View {
        Label {
            Text(text).font(.footnote)
        } icon: {
            Image(systemName: symbol)
                .foregroundStyle(tint)
        }
        .accessibilityLabel("\(prefix): \(text)")
    }

    private var symbol: String {
        switch ok {
        case .some(true): return "checkmark.circle.fill"
        case .some(false): return "exclamationmark.triangle.fill"
        case nil: return "circle.dotted"
        }
    }

    private var tint: Color {
        switch ok {
        case .some(true): return .green
        case .some(false): return .orange
        case nil: return .secondary
        }
    }

    private var prefix: String {
        switch ok {
        case .some(true): return "Ready"
        case .some(false): return "Needs attention"
        case nil: return "Not checked yet"
        }
    }
}

/// The live-microphone indicator AND the mute control, in one target.
struct ListeningPill: View {
    let isListening: Bool
    let isMuted: Bool
    let toggleMute: () -> Void

    var body: some View {
        Button(action: toggleMute) {
            HStack(spacing: 6) {
                Image(systemName: isMuted ? "mic.slash.fill" : "mic.fill")
                    .font(.footnote.weight(.semibold))
                    // The dot is not decoration: it is the state that must be
                    // visible at a glance from a metre away, standing up.
                    .symbolEffect(.pulse, isActive: isListening && !isMuted)
                Text(label).font(.caption.weight(.semibold))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(background, in: Capsule())
            .foregroundStyle(isMuted ? Color.secondary : Color.red)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isMuted ? "Microphone muted"
                                    : "Microphone listening")
        .accessibilityHint(isMuted ? "Unmute to take voice notes"
                                   : "Mute the microphone")
    }

    private var label: String {
        isMuted ? "Muted" : "Listening"
    }

    private var background: Color {
        isMuted ? Color.secondary.opacity(0.15) : Color.red.opacity(0.15)
    }
}

/// A proposal the user has not accepted: dashed, prefixed with a plus, and
/// obviously not the same object as a real chip. One tap promotes it.
struct GhostChip: View {
    let title: String
    /// `heard \u{201C}sparkly\u{201D}` — the literal words that produced it,
    /// DRAWN, not merely announced.
    ///
    /// Passed only when those words differ from `title`, which is the whole
    /// point: `Bright` offered because the user said "bright" needs no
    /// explanation, while `Bright` offered because they said "sparkly" is a
    /// guess the user should be able to check at a glance. A chip that appears
    /// from nowhere is the thing the trust rules are trying to avoid.
    var caption: String? = nil
    let promote: () -> Void

    var body: some View {
        Button(action: promote) {
            HStack(spacing: 4) {
                Image(systemName: "plus").font(.caption2.weight(.bold))
                Text(title).font(.caption2)
                if let caption {
                    Text(caption)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .overlay {
                Capsule().strokeBorder(
                    style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
            }
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Add \(title)")
        .accessibilityHint(caption ?? "Suggested by a note. Tap to apply.")
    }
}

/// The verbatim transcript with every matched span underlined.
///
/// The text itself is never altered — not re-cased, not punctuated, not
/// trimmed (docs/voice-notes.md §3 rule 1). Marking is presentation only, and
/// the spans come straight from the stored proposals' code-point offsets.
struct MarkedTranscript: View {
    let note: PresetNote

    var body: some View {
        Text(marked)
            .font(.callout)
            .textSelection(.enabled)
    }

    private var marked: AttributedString {
        var attributed = AttributedString(note.text)
        let scalars = Array(note.text.unicodeScalars)
        var spans: [(Int, Int)] = []
        if let verdict = note.proposals.verdict {
            spans.append((verdict.spanStart, verdict.spanEnd))
        }
        if let category = note.proposals.category {
            spans.append((category.spanStart, category.spanEnd))
        }
        spans.append(contentsOf: note.proposals.tags.map {
            ($0.spanStart, $0.spanEnd)
        })
        for (start, end) in spans {
            guard start >= 0, end <= scalars.count, start < end else { continue }
            // Proposal spans are UNICODE SCALAR offsets into the verbatim
            // text; AttributedString indexes by character. Convert through the
            // scalar view rather than assuming the two agree — they do not for
            // anything with a combining mark or an emoji in it.
            let scalarView = attributed.unicodeScalars
            guard let lower = scalarView.index(scalarView.startIndex,
                                               offsetBy: start,
                                               limitedBy: scalarView.endIndex),
                  let upper = scalarView.index(scalarView.startIndex,
                                               offsetBy: end,
                                               limitedBy: scalarView.endIndex)
            else { continue }
            guard lower < upper else { continue }
            attributed[lower..<upper].underlineStyle = Text.LineStyle.single
            attributed[lower..<upper].foregroundColor = Color.accentColor
        }
        return attributed
    }
}

/// One note, as it appears in a detail list or the review sheet: the verbatim
/// line with its matched spans, the correction if there is one, and the
/// timestamp/source provenance.
struct NoteRowView: View {
    let note: PresetNote

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            MarkedTranscript(note: note)
            if let corrected = note.textCorrected {
                Label(corrected, systemImage: "pencil")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Corrected to: \(corrected)")
            }
            HStack(spacing: 6) {
                Image(systemName: note.source == .voice
                      ? "waveform" : "keyboard")
                    .font(.caption2)
                Text(Format.parseCoreTimestamp(note.recordedAt)
                    .map { Format.relativeAge($0) } ?? note.recordedAt)
                    .font(.caption2)
            }
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

/// The row-level "this preset has notes" glyph. Silent at zero: a library
/// where most rows have nothing to say should not be a wall of empty badges.
struct NoteCountBadge: View {
    let count: Int

    var body: some View {
        if count > 0 {
            Label("\(count)", systemImage: "text.bubble")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .accessibilityLabel("\(count) note\(count == 1 ? "" : "s")")
        }
    }
}
