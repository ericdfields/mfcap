// Components.swift — the shared visual vocabulary (UX §10, §17).
//
// Judgment is a semantic role rendered identically everywhere: dot SHAPE +
// chip text carry the state (color is never the sole carrier; everything
// survives grayscale and VoiceOver reads the judgment).

import SwiftUI
import FreakCore

/// §10 judgment dot: filled = real, outline+dim = expendable, hollow dashed
/// = unjudged, hollow + "!" = unknown (name read failed).
struct JudgmentDot: View {
    let judgment: SlotJudgment

    var body: some View {
        switch judgment {
        case .real:
            Circle().fill(Color.primary.opacity(0.8))
                .frame(width: 10, height: 10)
                .accessibilityLabel("preset")
        case .expendable:
            Circle().stroke(Color.secondary, lineWidth: 1.5)
                .frame(width: 10, height: 10)
                .accessibilityLabel("empty")
        case .unjudged:
            Circle()
                .stroke(style: StrokeStyle(lineWidth: 1.2, dash: [2, 2]))
                .foregroundStyle(.secondary)
                .frame(width: 10, height: 10)
                .accessibilityLabel("content not read yet")
        case .unknown:
            ZStack {
                Circle().stroke(Color.secondary, lineWidth: 1.2)
                    .frame(width: 10, height: 10)
                Text("!").font(.system(size: 7, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .accessibilityLabel("name read failed")
        }
    }
}

/// "empty" micro-chip next to dimmed expendable names (UX §10).
struct EmptyChip: View {
    var body: some View {
        Text("empty")
            .font(.caption2)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Color.secondary.opacity(0.15), in: Capsule())
            .foregroundStyle(.secondary)
    }
}

/// Sync status badge (only rendered while a current diff exists).
struct SyncBadge: View {
    let status: SlotStatus

    var body: some View {
        Text(label)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
            .accessibilityLabel("sync: \(label)")
    }

    private var label: String {
        switch status {
        case .inSync: return "in sync"
        case .deviceOnly: return "added"
        case .libraryOnly: return "missing"
        case .differs: return "changed"
        case .empty: return "empty"
        }
    }

    private var color: Color {
        switch status {
        case .inSync: return .green
        case .deviceOnly: return .blue
        case .libraryOnly: return .orange
        case .differs: return .purple
        case .empty: return .secondary
        }
    }
}

/// Persistent per-slot warning badges: "torn" / "verify failed" (UX §14).
struct SlotFlagBadge: View {
    enum Flag { case torn, verifyFailed }
    let flag: Flag

    var body: some View {
        Label(flag == .torn ? "torn" : "verify failed",
              systemImage: flag == .torn
                  ? "bolt.trianglebadge.exclamationmark"
                  : "exclamationmark.triangle")
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.red.opacity(0.15), in: Capsule())
            .foregroundStyle(.red)
    }
}

/// Tag chip for library rows.
struct TagChip: View {
    let tag: String

    var body: some View {
        Text(tag)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.accentColor.opacity(0.12), in: Capsule())
    }
}

/// The monospaced 3-digit slot number column (fixed width, UX §19).
struct SlotNumberLabel: View {
    let slot: SlotID

    var body: some View {
        Text(slot.label)
            .font(.body.monospacedDigit())
            .foregroundStyle(.secondary)
            .frame(width: 44, alignment: .trailing)
    }
}

/// In-place rename editor (UX §8.3): printable ASCII only, counter from
/// 18/23, hard stop at 23, Esc cancels, Return commits.
struct RenameField: View {
    let original: String
    let commit: (String) -> Void
    let cancel: () -> Void

    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            TextField("Name", text: $text)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .focused($focused)
                .onChange(of: text) { _, value in
                    let cleaned = NameRules.sanitizedWhileTyping(value)
                    if cleaned != value { text = cleaned }
                }
                .onSubmit {
                    let trimmed = text.trimmingCharacters(in: .whitespaces)
                    if NameRules.isValid(trimmed) {
                        commit(trimmed)
                    } else {
                        cancel()
                    }
                }
                .onKeyPress(.escape) {
                    cancel()
                    return .handled
                }
            if text.count >= NameRules.counterThreshold {
                Text("\(text.count)/\(NameRules.maxLength)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(text.count >= NameRules.maxLength
                                     ? .orange : .secondary)
            }
        }
        .onAppear {
            text = original
            focused = true
        }
    }
}
