import Foundation

/// One measurement for `NavigationEngine`, with its session-clock time.
///
/// `timestamp` is when the measurement applies; `arrival` is when it became
/// available. They differ only for a location fix, whose `t` is the fix time
/// (v2/v3) and which arrives at `receivedT`. A causal consumer feeds inputs
/// in arrival order.
///
/// `gpsSwitch` (log v4, UX-9 a) is not a measurement: it is the driver's
/// instruction whether the engine may use GNSS fixes from its `t` on
/// (`NavigationEngine`, "GPS off switch"). It arrives at its `t`.
public enum NavigationInput: Hashable, Sendable {
    case motion(MotionSample, at: MonotonicTimestamp)
    case obd(OBDSample, at: MonotonicTimestamp)
    case location(LocationSample, at: MonotonicTimestamp)
    case manualFix(ManualFixSample, at: MonotonicTimestamp)
    case gpsSwitch(GPSSwitchSample, at: MonotonicTimestamp)

    /// The event's `t`.
    public var timestamp: MonotonicTimestamp {
        switch self {
        case .motion(_, let t), .obd(_, let t), .location(_, let t), .manualFix(_, let t), .gpsSwitch(_, let t): t
        }
    }

    /// When the input became available: `receivedT` for a location fix that
    /// has one (never before its own `t`), `t` otherwise.
    public var arrival: MonotonicTimestamp {
        switch self {
        case .location(let sample, let t):
            guard let received = sample.receivedT else { return t }
            return max(received, t)
        case .motion(_, let t), .obd(_, let t), .manualFix(_, let t), .gpsSwitch(_, let t):
            return t
        }
    }

    /// The navigation input in a log event, or nil for every other kind.
    public init?(_ event: LogEvent) {
        switch event.payload {
        case .motion(let sample): self = .motion(sample, at: event.timestamp)
        case .obd(let sample): self = .obd(sample, at: event.timestamp)
        case .location(let sample): self = .location(sample, at: event.timestamp)
        case .manualFix(let sample): self = .manualFix(sample, at: event.timestamp)
        case .gpsSwitch(let sample): self = .gpsSwitch(sample, at: event.timestamp)
        default: return nil
        }
    }

    /// Whether this is the driver's GPS switch: an instruction, not a
    /// measurement. It never moves a clock or a grid (`NavigationEngine`,
    /// `LiveNavigationRun`, the replay).
    public var isGPSSwitch: Bool {
        if case .gpsSwitch = self { true } else { false }
    }
}
