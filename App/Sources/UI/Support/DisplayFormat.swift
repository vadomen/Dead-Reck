import Foundation

/// Pure text formatting for the screens. Whole-number speeds and `m:ss` clocks
/// are the same in every language (read at a glance in a car). Decimals, sizes
/// and units go through `FormatStyle` with an explicit `locale` (default: the
/// current one), so the tests pin the text for a fixed locale.
enum DisplayFormat {
    /// Whole km/h, or `--` when there is no reading.
    static func speed(_ kmh: Double?) -> String {
        guard let kmh, kmh.isFinite else { return "--" }
        return String(Int(max(0, kmh).rounded()))
    }

    static func hz(_ value: Double, locale: Locale = .current) -> String {
        guard value.isFinite else { return "--" }
        return max(0, value).formatted(.number.precision(.fractionLength(1)).grouping(.never).locale(locale))
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

    /// Decimal units (1 KB = 1000 B), like the Files app, in the locale's unit names.
    static func bytes(_ count: Int64, locale: Locale = .current) -> String {
        Int64(max(0, count)).formatted(ByteCountFormatStyle(
            style: .decimal, allowedUnits: [.bytes, .kb, .mb, .gb], spellsOutZero: false,
            includesActualByteCount: false, locale: locale))
    }

    static func bytes(_ count: Int, locale: Locale = .current) -> String { bytes(Int64(count), locale: locale) }

    /// Map sizes (always MB): one decimal in the locale's separator. The unit
    /// comes from the catalog ("MB" -> "МБ").
    static func megabytes(_ bytes: Int64, locale: Locale = .current) -> String {
        let mb = Double(max(0, bytes)) / 1_000_000
        return String(localized: "\(mb.formatted(.number.precision(.fractionLength(1)).grouping(.never).locale(locale))) MB")
    }

    /// "12.4 V" ("12,4 В" in Ukrainian).
    static func voltage(_ volts: Double?, locale: Locale = .current) -> String? {
        guard let volts, volts.isFinite else { return nil }
        let number = volts.formatted(.number.precision(.fractionLength(1)).grouping(.never).locale(locale))
        return String(localized: "\(number) V")
    }

    /// Whole seconds left in a countdown, rounded up so it never shows 0
    /// while still counting.
    static func secondsLeft(total: Int, elapsed: TimeInterval) -> Int {
        let left = Double(total) - max(0, elapsed)
        return max(0, Int(left.rounded(.up)))
    }
}
