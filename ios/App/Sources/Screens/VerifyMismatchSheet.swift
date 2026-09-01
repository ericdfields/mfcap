// VerifyMismatchSheet.swift — THE designed error moment (UX §14).
//
// The one error meaning the synth now holds something other than what we
// sent. Scary enough to stop, calm enough to act on: states the blast radius
// ("nothing else was written") and the source's safety; renders only the
// fields that actually differ; a read-back that failed entirely renders
// "Read back — no response", never fake values. NO auto-retry — retrying a
// write is a deliberate act. On Close the slot keeps its persistent
// "verify failed" badge until a clean verified write lands.

import SwiftUI
import FreakCore

struct VerifyMismatchSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let presentation: VerifyMismatchPresentation

    private var mismatch: VerifyMismatch { presentation.mismatch }
    private var slot: SlotID { presentation.slot }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if model.connection.isPractice {
                PracticeBanner()
            }
            Label("Slot \(slot.display) didn't verify",
                  systemImage: "exclamationmark.triangle.fill")
                .font(.title2.weight(.bold))
                .foregroundStyle(.orange)

            Text("The preset was sent, but reading the slot back returned "
                 + "different data. What is on the MicroFreak in slot "
                 + "\(slot.display) right now is NOT "
                 + "\"\(mismatch.expectedName)\".")
                .font(.callout)

            comparison

            Text(safetyLine)
                .font(.callout)

            if let context = presentation.batchContext {
                Label(context, systemImage: "list.number")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            // §13.1/2: actions at the bottom.
            VStack(spacing: 10) {
                Button {
                    dismiss()
                    presentation.writeAgain()
                } label: {
                    Text("Write Again")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                if let retryLabel = presentation.retryFromLabel,
                   let retryFrom = presentation.retryFrom {
                    Button {
                        dismiss()
                        retryFrom()
                    } label: {
                        Text(retryLabel)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
                Button {
                    dismiss()
                    _ = model.readSlot(slot)
                } label: {
                    Text("Read Slot \(slot.display)")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                Button("Close") { dismiss() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(24)
        .presentationDetents([.large, .medium])
        .interactiveDismissDisabled(false)
    }

    // ---------------------------------------------------------- comparison

    /// Sent vs. read-back: only the fields that actually differ render
    /// values; a fully failed read-back says so.
    @ViewBuilder
    private var comparison: some View {
        VStack(alignment: .leading, spacing: 6) {
            comparisonRow(
                label: "Sent",
                name: mismatch.expectedName,
                sha: mismatch.expectedSha256,
                bytes: mismatch.expectedLength)
            if mismatch.actualName == nil && mismatch.actualSha256 == nil {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("Read back")
                        .font(.caption.weight(.semibold))
                        .frame(width: 70, alignment: .leading)
                    Text("no response")
                        .font(.callout)
                        .foregroundStyle(.red)
                }
            } else {
                comparisonRow(
                    label: "Read back",
                    name: mismatch.actualName ?? mismatch.expectedName,
                    sha: mismatch.actualSha256,
                    bytes: mismatch.actualLength)
            }
            if let firstDifference = mismatch.firstDifference {
                Text("First difference at byte "
                     + "\(firstDifference.formatted(.number.grouping(.automatic)))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 80)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.4),
                    in: RoundedRectangle(cornerRadius: 10))
    }

    private func comparisonRow(label: String, name: String, sha: String?,
                               bytes: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .font(.caption.weight(.semibold))
                .frame(width: 70, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.callout)
                HStack(spacing: 8) {
                    if let sha, !sha.isEmpty {
                        Text("sha \(Format.shaPrefix(sha))")
                            .font(.caption.monospaced())
                    }
                    if bytes > 0 {
                        Text(Format.byteCount(bytes))
                            .font(.caption)
                    }
                }
                .foregroundStyle(.secondary)
            }
        }
    }

    private var safetyLine: String {
        let source = model.libraryModel.entries
            .first { $0.sha256 == mismatch.expectedSha256 }
        if let source {
            return "Your library copy of \"\(source.name)\" is safe. "
                + "Nothing else was written."
        }
        return "The source preset is unchanged. Nothing else was written."
    }
}

#Preview("Verify mismatch") {
    PreviewHost { model in
        Color.clear.sheet(isPresented: .constant(true)) {
            VerifyMismatchSheet(presentation: VerifyMismatchPresentation(
                mismatch: VerifyMismatch(
                    slot: 412,
                    expectedSha256: "9f3a01b2c4d6aa00bb11cc22dd33ee44"
                        + "9f3a01b2c4d6aa00bb11cc22dd33ee44",
                    actualSha256: "77e01ac9d00100aa22bb33cc44dd55ee"
                        + "77e01ac9d00100aa22bb33cc44dd55ee",
                    expectedName: "Fat Bass v2",
                    actualName: "Fat Bass v2",
                    firstDifference: 1024,
                    expectedLength: 4672,
                    actualLength: 4672),
                slot: SlotID(412),
                writeAgain: {}))
                .environment(model)
        }
    }
}
