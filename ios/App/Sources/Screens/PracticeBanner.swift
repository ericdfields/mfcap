// PracticeBanner.swift — the never-mistakable practice banner (UX §11).
//
// Persistent, non-dismissable, spanning the top of the content column
// whenever the session is simulated. Violet tint reserved for practice
// only, diagonal-striped leading edge so it survives grayscale; the status
// capsule echoes it with the same tint.

import SwiftUI

struct PracticeBanner: View {
    @Environment(AppModel.self) private var model

    private var profileTitle: String {
        model.connection.practiceProfile?.title ?? "Simulated"
    }

    var body: some View {
        HStack(spacing: 12) {
            DiagonalStripes()
                .frame(width: 18)
            Text(text)
                .font(.footnote.weight(.semibold))
                .lineLimit(2)
            Spacer()
        }
        .frame(minHeight: 34)
        .foregroundStyle(Color.purple)
        .background(Color.purple.opacity(0.14))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Practice mode. Simulated MicroFreak, "
            + "\(profileTitle). Nothing here touches hardware.")
    }

    private var text: String {
        var out = "PRACTICE MODE — simulated MicroFreak (\(profileTitle)). "
            + "Nothing here touches hardware."
        if model.fastPracticeTiming { out += " (fast)" }
        return out
    }
}

/// The grayscale-surviving leading edge (UX §11, §19).
struct DiagonalStripes: View {
    var body: some View {
        Canvas { context, size in
            let stripe: CGFloat = 5
            var x: CGFloat = -size.height
            while x < size.width + size.height {
                var path = Path()
                path.move(to: CGPoint(x: x, y: size.height))
                path.addLine(to: CGPoint(x: x + size.height, y: 0))
                context.stroke(path, with: .color(.purple.opacity(0.8)),
                               lineWidth: stripe / 2)
                x += stripe * 2
            }
        }
        .clipped()
    }
}

#Preview("Practice banner") {
    PreviewHost { _ in
        PracticeBanner()
    }
}
