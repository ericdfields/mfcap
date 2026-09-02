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
            // A closed set of five short words: pinning them makes the chip a
            // RIGID participant, so an HStack shrinks the preset name column
            // instead of squeezing (and hyphenating) the capsule.
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
            .accessibilityLabel("sync: \(label)")
    }

    private var label: String {
        switch status {
        case .inSync: return "in sync"
        case .unlisted: return "unlisted"
        case .baselineOnly: return "missing"
        case .differs: return "changed"
        case .empty: return "empty"
        }
    }

    private var color: Color {
        switch status {
        case .inSync: return .green
        // Informational, not a task: the collection simply says nothing here.
        case .unlisted: return .secondary
        case .baselineOnly: return .orange
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

// ============================================ category / favorite / tags
//
// `Category` is qualified `FreakCore.Category` everywhere in the app: the
// Objective-C runtime (via Foundation) also declares a `Category` typedef,
// so the bare name is ambiguous outside FreakCore itself.

extension FreakCore.Category {
    /// Chip / picker display order (UX addendum §21.2): the documented set,
    /// with Uncategorized always last (the auto-fill fallback).
    static var displayOrder: [FreakCore.Category] {
        allCases.filter { $0 != .uncategorized } + [.uncategorized]
    }
}

/// One category chip — `displayName · count`, selectable, never color-only
/// (fill + `.isSelected` trait). A zero-count chip is dimmed + non-tappable
/// (present, so the taxonomy reads consistently), never hidden (§22.1).
struct CategoryChip: View {
    let title: String
    let count: Int
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(title).font(.subheadline)
                Text("\(count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(selected ? .white.opacity(0.9) : .secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(selected ? Color.accentColor
                                 : Color.secondary.opacity(0.12),
                        in: Capsule())
            .foregroundStyle(selected ? .white : .primary)
        }
        .buttonStyle(.plain)
        .disabled(count == 0 && !selected)
        .opacity(count == 0 && !selected ? 0.4 : 1)
        .accessibilityLabel("\(title), \(count) presets")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The wrapping chip grid pinned above the library / favorites lists (§22.1).
/// Reads and drives `LibraryModel.categoryFilter`; counts are faceted (§22.2).
struct CategoryFilterBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let counts = model.libraryModel.displayCategoryCounts
        let total = counts.values.reduce(0, +)
        let selected = model.libraryModel.categoryFilter
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                CategoryChip(title: "All", count: total,
                             selected: selected == nil) {
                    model.libraryModel.categoryFilter = nil
                }
                ForEach(FreakCore.Category.displayOrder, id: \.self) { category in
                    CategoryChip(title: category.displayName,
                                 count: counts[category] ?? 0,
                                 selected: selected == category) {
                        model.libraryModel.categoryFilter =
                            (selected == category) ? nil : category
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .background(.thinMaterial)
    }
}

/// A small category label chip on a library row (§22.3). Uncategorized is
/// silent — no badge — so the row stays quiet until the user tags it.
struct CategoryBadge: View {
    let category: FreakCore.Category

    var body: some View {
        if category != .uncategorized {
            Text(category.displayName)
                .font(.caption2.weight(.medium))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.secondary.opacity(0.15), in: Capsule())
                .foregroundStyle(.secondary)
        }
    }
}

/// The editable category row in a preset detail (§22.3) — a Menu over the
/// taxonomy, committing instantly and locally. This is where a wrong device-
/// byte auto-fill is corrected.
struct CategoryPickerRow: View {
    let category: FreakCore.Category
    let onChange: (FreakCore.Category) -> Void

    var body: some View {
        LabeledContent("Category") {
            Menu {
                ForEach(FreakCore.Category.displayOrder, id: \.self) { option in
                    Button {
                        onChange(option)
                    } label: {
                        if option == category {
                            Label(option.displayName, systemImage: "checkmark")
                        } else {
                            Text(option.displayName)
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(category.displayName)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// The one heart toggle used on rows and in detail (§24.1). 44 pt target;
/// favorite state is a trait, never color-only. `disabledReason` (device
/// rows without a hash) shows honestly and blocks the tap (§24.2).
/// The four-state audition verdict as a menu row (detail view).
struct VerdictPickerRow: View {
    let verdict: Verdict
    let onChange: (Verdict) -> Void

    var body: some View {
        LabeledContent("Verdict") {
            Menu {
                ForEach([Verdict.unrated] + Verdict.promptOrder, id: \.self) { option in
                    Button {
                        onChange(option)
                    } label: {
                        if option == verdict {
                            Label(option.displayName, systemImage: "checkmark")
                        } else {
                            Label(option.displayName, systemImage: option.systemImage)
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: verdict.systemImage)
                    Text(verdict.displayName)
                    Image(systemName: "chevron.up.chevron.down").font(.caption2)
                }
            }
        }
    }
}

/// Compact verdict marker for list rows; nothing is drawn while unrated.
struct VerdictBadge: View {
    let verdict: Verdict

    var body: some View {
        if verdict != .unrated {
            Label(verdict.displayName, systemImage: verdict.systemImage)
                .font(.caption2)
                .labelStyle(.iconOnly)
                .foregroundStyle(verdict == .keep ? .green
                                 : verdict == .never ? .red : .secondary)
                .accessibilityLabel("Verdict: \(verdict.displayName)")
        }
    }
}

/// The audition prompt: one big tap per verdict (UX: standing at the synth).
///
/// `heard` PRE-AIMS a chip from a spoken note (docs/voice-notes.md §3 rule 2):
/// the matching chip is outlined and captioned with the literal words that
/// were heard, and the user still taps. Nothing is filed by speech alone, so a
/// mishearing costs one glance and no data — which is the only reason it is
/// safe to point at a chip on the strength of a transcript at all.
struct VerdictChips: View {
    var heard: Verdict? = nil
    /// `heard "keep it"` — the literal span, not the canonical value, so a
    /// lucky guess is distinguishable from a real hit.
    var heardCaption: String? = nil
    let onPick: (Verdict) -> Void

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                ForEach(Verdict.promptOrder, id: \.self) { v in
                    Button {
                        onPick(v)
                    } label: {
                        VStack(spacing: 6) {
                            Image(systemName: v.systemImage).font(.title)
                            Text(v.displayName).font(.callout.weight(.semibold))
                        }
                        .frame(maxWidth: .infinity, minHeight: 88)
                    }
                    .buttonStyle(.bordered)
                    .tint(v == .keep ? .green : v == .never ? .red : .accentColor)
                    // Shape, not colour alone: the pre-aimed chip gets a ring
                    // as well as a tint, so it survives grayscale.
                    .overlay {
                        if heard == v {
                            RoundedRectangle(cornerRadius: 10)
                                .strokeBorder(Color.accentColor, lineWidth: 2.5)
                        }
                    }
                    .accessibilityHint(heard == v
                                       ? (heardCaption ?? "suggested by a note")
                                       : "")
                    .keyboardShortcut(KeyEquivalent(Character("\(Verdict.promptOrder.firstIndex(of: v)! + 1)")),
                                      modifiers: [])
                }
            }
            if let heardCaption, heard != nil {
                Label(heardCaption, systemImage: "waveform")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Suggested from a note: \(heardCaption)")
            }
        }
    }
}

struct FavoriteToggle: View {
    let isFavorite: Bool
    var disabledReason: String? = nil
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            Image(systemName: isFavorite ? "heart.fill" : "heart")
                .foregroundStyle(isFavorite ? .pink : .secondary)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabledReason != nil)
        .help(disabledReason ?? "")
        .accessibilityLabel(isFavorite ? "favorite" : "not a favorite")
        .accessibilityAddTraits(isFavorite ? .isSelected : [])
        .accessibilityHint(disabledReason ?? "")
    }
}

/// Add/remove tag editor (§23.1) — removable chips + a single-line add field
/// committing on Return; trims, rejects empty, case-insensitive de-dupe
/// (handled by the model). Replaces the base comma-string alert.
struct TagEditor: View {
    let tags: [String]
    let add: (String) -> Void
    let remove: (String) -> Void

    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !tags.isEmpty {
                WrapHStack(tags) { tag in
                    HStack(spacing: 4) {
                        Text(tag).font(.caption2)
                        Button {
                            remove(tag)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.caption2)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("remove tag \(tag)")
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.12), in: Capsule())
                }
            }
            HStack(spacing: 6) {
                TextField("Add a tag", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .onSubmit(commit)
                Button("Add", action: commit)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func commit() {
        let trimmed = draft.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        add(trimmed)
        draft = ""
    }
}

/// A minimal wrapping HStack for tag chips (no third-party FlowLayout).
struct WrapHStack<Item: Hashable, Content: View>: View {
    let items: [Item]
    let content: (Item) -> Content

    init(_ items: [Item], @ViewBuilder content: @escaping (Item) -> Content) {
        self.items = items
        self.content = content
    }

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(items, id: \.self) { content($0) }
        }
    }
}

/// A tiny flow layout (iOS 16+ Layout) so chips wrap instead of clipping.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize,
                      subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0; y += rowHeight + spacing; rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth == .infinity ? x : maxWidth,
                      height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX; y += rowHeight + spacing; rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

// ==================================================== collections vocabulary

/// One-line provenance for a collection (UX addendum §26.1).
struct ProvenanceLabel: View {
    let provenance: Provenance

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private var text: String {
        switch provenance.kind {
        case .importedBank:
            return "from bank \"\(provenance.source)\""
        case .deviceSnapshot:
            let who = provenance.source.hasPrefix("practice")
                ? "a practice device" : "this MicroFreak"
            return "from \(who)"
        case .manual:
            return "assembled by hand"
        }
    }
}

/// A collection list row (UX addendum §26.1): name · provenance · count, with
/// a Practice chip when the provenance identity is practice.
struct CollectionRowView: View {
    let collection: PresetCollection
    /// True when the detail column is showing this collection — the "which
    /// one is open" cue the sidebar's duplicate rows used to carry.
    var isOpen = false

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(collection.name).font(.body)
                HStack(spacing: 6) {
                    ProvenanceLabel(provenance: collection.provenance)
                    Text("· \(collection.slots.count) presets")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if collection.provenance.kind == .deviceSnapshot,
               collection.provenance.source.hasPrefix("practice") {
                Text("Practice")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.purple.opacity(0.15), in: Capsule())
                    .foregroundStyle(.purple)
            }
            if isOpen {
                Image(systemName: "checkmark")
                    .font(.caption).foregroundStyle(.tint)
                    .accessibilityLabel("open")
            }
        }
        .frame(minHeight: 52)
        .contentShape(Rectangle())
        .accessibilityAddTraits(isOpen ? .isSelected : [])
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
