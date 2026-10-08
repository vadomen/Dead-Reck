import Foundation

/// Pure text formatting for the screens. Locale-independent on purpose: the
/// numbers are read at a glance in a car, and the tests pin the exact text.
enum DisplayFormat {
    /// Whole km/h, or `--` when there is no reading.
    static func speed(_ kmh: Double?) -> String {
        guard let kmh, kmh.isFinite else { return "--" }
        return String(Int(max(0, kmh).rounded()))
    }

    static func hz(_ value: Double) -> String {
        guard value.isFinite else { return "--" }
        return String(format: "%.1f", max(0, value))
    }

    /// `m:ss`, or `h:mm:ss` from one hour.
    static func elapsed(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.isFinite ? seconds : 0))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }

    /// Duration for the sessions list; `--` when the file could not be read.
    static func duration(_ seconds: TimeInterval?) -> String {
        guard let seconds else { return "--" }
        return elapsed(seconds)
    }

    /// Decimal units (1 KB = 1000 B), like the Files app.
    static func bytes(_ count: Int64) -> String {
        let n = Double(max(0, count))
        switch n {
        case ..<1_000: return "\(Int(n)) B"
        case ..<1_000_000: return String(format: "%.0f KB", n / 1_000)
        case ..<1_000_000_000: return String(format: "%.1f MB", n / 1_000_000)
        default: return String(format: "%.2f GB", n / 1_000_000_000)
        }
    }

    static func bytes(_ count: Int) -> String { bytes(Int64(count)) }

    static func voltage(_ volts: Double?) -> String? {
        guard let volts, volts.isFinite else { return nil }
        return String(format: "%.1f V", volts)
    }

    /// Whole seconds left in a countdown, rounded up so it never shows 0
    /// while still counting.
    static func secondsLeft(total: Int, elapsed: TimeInterval) -> Int {
        let left = Double(total) - max(0, elapsed)
        return max(0, Int(left.rounded(.up)))
    }
}
