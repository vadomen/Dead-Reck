/// Offset from a recording's single time reference, in nanoseconds.
///
/// Every sample in a recording — OBD over Bluetooth, CoreMotion, CoreLocation —
/// is stamped with one of these, measured against one `SessionClock`. That makes
/// samples from different streams directly comparable without any wall-clock
/// arithmetic, which matters because wall clocks jump (NTP, time zones, the user
/// changing the date) and dead reckoning integrates over time.
public struct MonotonicTimestamp: Hashable, Sendable, Comparable, Codable {
    /// Nanoseconds since the owning session's reference instant. Negative only
    /// for samples that a sensor had already buffered before the session began.
    public let nanoseconds: Int64

    public init(nanoseconds: Int64) {
        self.nanoseconds = nanoseconds
    }

    public init(seconds: Double) {
        self.nanoseconds = Int64((seconds * 1_000_000_000).rounded())
    }

    public var seconds: Double {
        Double(nanoseconds) / 1_000_000_000
    }

    public static let zero = MonotonicTimestamp(nanoseconds: 0)

    public static func < (lhs: MonotonicTimestamp, rhs: MonotonicTimestamp) -> Bool {
        lhs.nanoseconds < rhs.nanoseconds
    }
}

extension MonotonicTimestamp {
    /// Interval to a later timestamp, in seconds.
    public func interval(to other: MonotonicTimestamp) -> Double {
        Double(other.nanoseconds - nanoseconds) / 1_000_000_000
    }
}

extension MonotonicTimestamp {
    // Encoded as a bare integer rather than an object so a log line stays
    // compact and greppable: {"t":1234567,...}.
    public init(from decoder: any Decoder) throws {
        nanoseconds = try decoder.singleValueContainer().decode(Int64.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(nanoseconds)
    }
}
