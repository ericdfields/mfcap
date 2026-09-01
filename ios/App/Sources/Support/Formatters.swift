// Formatters.swift — durations, ETA, relative ages, sha prefixes, the
// category-byte label table, and the input-side name rules (UX §7, §8.3).

import Foundation

enum Format {
    /// "2:10" / "1:02:10" — for ETAs and elapsed times (UX §16.1 m:ss rule).
    static func clock(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded()))
        if s >= 3600 {
            return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
        }
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    /// "~3.5 minutes" / "~45 seconds" — pre-flight estimates.
    static func estimate(_ seconds: TimeInterval) -> String {
        if seconds < 90 { return "~\(Int(seconds.rounded())) seconds" }
        return String(format: "~%.1f minutes", seconds / 60)
    }

    /// "398 ms/slot"
    static func throughput(perSlotSeconds: Double) -> String {
        String(format: "%.0f ms/slot", perSlotSeconds * 1000)
    }

    /// "14:32"
    static func timeOfDay(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm"
        return fmt.string(from: date)
    }

    /// "just now" / "12 min ago" / "3 days ago"
    static func relativeAge(_ date: Date, now: Date = Date()) -> String {
        let s = now.timeIntervalSince(date)
        if s < 60 { return "just now" }
        if s < 3600 { return "\(Int(s / 60)) min ago" }
        if s < 86_400 { return "\(Int(s / 3600)) h ago" }
        let days = Int(s / 86_400)
        return days == 1 ? "1 day ago" : "\(days) days ago"
    }

    /// "9f3a01b2c4d6" — abbreviated sha; the full hash lives behind a tap.
    static func shaPrefix(_ sha: String?, length: Int = 12) -> String {
        guard let sha, !sha.isEmpty else { return "—" }
        return String(sha.prefix(length))
    }

    /// "4,672 bytes"
    static func byteCount(_ n: Int) -> String {
        let fmt = NumberFormatter()
        fmt.numberStyle = .decimal
        return "\(fmt.string(from: NSNumber(value: n)) ?? "\(n)") bytes"
    }

    /// "1.2 MB"
    static func fileSize(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }

    /// Parse the core's local timestamp ("yyyy-MM-dd'T'HH:mm:ss").
    static func parseCoreTimestamp(_ s: String) -> Date? {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return fmt.date(from: s)
    }

    /// "0x0B"
    static func hexByte(_ byte: UInt8) -> String {
        String(format: "0x%02X", byte)
    }

    /// "18 00 00 00 00 7d 01 00 33" — meta shown in the Advanced disclosure.
    static func metaHex(_ meta: Data?) -> String {
        guard let meta else { return "—" }
        return meta.map { String(format: "%02x", $0) }.joined(separator: " ")
    }
}

// ------------------------------------------------------------ category byte

/// The preset's meta byte 7 (long-0x52 payload[10]), display only (UX §7.4).
/// The friendly-label table ships EMPTY until the mapping is verified against
/// hardware — raw hex is the honest default. v1 never edits the category byte.
enum CategoryByte {
    /// Hardware-verified labels only. Deliberately empty for now (UX §20.3).
    static let verifiedLabels: [UInt8: String] = [:]

    static func label(for byte: UInt8) -> String? { verifiedLabels[byte] }

    static let infoCopy =
        "Category as stored by the synth. Labels appear once the mapping is "
        + "confirmed against hardware."
}

// ------------------------------------------------------------- name rules

/// Input-side validation for preset names (UX §8.3): up to 23 printable
/// ASCII characters, no leading/trailing whitespace. Mirrors the core's
/// validateName; the core remains the authority at the API boundary.
enum NameRules {
    static let maxLength = SlotID.Layout.nameMax
    /// Character counter appears at this length (UX §7.1).
    static let counterThreshold = 18

    static func isAllowedScalar(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value >= 0x20 && scalar.value <= 0x7E
    }

    /// Strip illegal characters and hard-stop at 23 — used while typing.
    static func sanitizedWhileTyping(_ text: String) -> String {
        String(String.UnicodeScalarView(
            text.unicodeScalars.filter(isAllowedScalar).prefix(maxLength)))
    }

    /// Would the core accept this name as-is?
    static func isValid(_ name: String) -> Bool {
        guard name.count <= maxLength else { return false }
        guard name.unicodeScalars.allSatisfy(isAllowedScalar) else { return false }
        return name == name.trimmingCharacters(in: .whitespaces)
    }

    /// The rule, stated for the fallback toast (UX §14 InvalidNameError).
    static let ruleCopy = "Names: up to 23 plain ASCII characters, "
        + "no leading or trailing spaces."
}
