import Foundation

/// Makes the demo's navigation feed independent of live scheduling
/// (REL-DEMO, screenshots must reproduce): the engine's output depends on
/// the order inputs arrive in, not only on their timestamps (an OBD reply
/// or a fix steps the 10 Hz grid to its own time, so a motion sample
/// delivered after it loses its yaw from that step), and live delivery
/// interleaves the motion queue, the location queue and the adapter's
/// replies differently on every run. The adapter's poll times are real
/// scheduling too.
///
/// So the demo's feed is rebuilt from the motion samples, which are a pure
/// function of their index: each motion sample at `t` releases, in one
/// canonical order, every OBD poll of the model's grid
/// (`DemoSensorModel.obdInput(poll:)`) and every model fix
/// (`locationInput(second:)`) that arrives at or before `t`, sorted by
/// arrival, a motion sample first on a tie, then OBD, then location. The
/// adapter's own `obd` inputs and the location source's own fixes are
/// dropped (the same values, at live times); a manual fix (the driver's
/// tap) passes at once. Same motion samples in, same inputs out, however
/// the live inputs were interleaved or batched.
public struct DemoFeedSequencer: Sendable {
    public let model: DemoSensorModel
    /// The next OBD poll and the next second whose fix is due.
    private var nextPoll = 0
    private var nextSecond = 0

    public init(model: DemoSensorModel) {
        self.model = model
    }

    /// The inputs to ingest now for one live input, in order.
    public mutating func accept(_ input: NavigationInput) -> [NavigationInput] {
        switch input {
        case .motion(_, let t):
            var due: [(ns: Int64, rank: Int, input: NavigationInput)] = [(t.nanoseconds, 0, input)]
            while Int64(nextPoll) * DemoSensorModel.obdPollIntervalNs + DemoSensorModel.obdReplyLatencyNs <= t.nanoseconds {
                let obd = model.obdInput(poll: nextPoll)
                due.append((obd.arrival.nanoseconds, 1, obd))
                nextPoll += 1
            }
            while Int64(nextSecond) * 1_000_000_000 <= t.nanoseconds {
                if let fix = model.locationInput(second: nextSecond) { due.append((fix.arrival.nanoseconds, 2, fix)) }
                nextSecond += 1
            }
            return due.sorted { ($0.ns, $0.rank) < ($1.ns, $1.rank) }.map(\.input)
        case .obd, .location:
            return []
        case .manualFix:
            return [input]
        }
    }
}

extension NavigationInput {
    /// The log event this input was read from (`NavigationInput.init?(_:)`
    /// inverted), for handing a rebuilt input to a `NavigationTap`.
    public var event: LogEvent {
        switch self {
        case .motion(let sample, let t): LogEvent(timestamp: t, payload: .motion(sample))
        case .obd(let sample, let t): LogEvent(timestamp: t, payload: .obd(sample))
        case .location(let sample, let t): LogEvent(timestamp: t, payload: .location(sample))
        case .manualFix(let sample, let t): LogEvent(timestamp: t, payload: .manualFix(sample))
        }
    }
}
