import Foundation

// The demo drive's sensor sources (REL-DEMO): `DemoSensorModel` delivered
// like Core's simulated sources, from a private queue, never the main actor.
// Sample `n` is stamped exactly `n × period` on the session clock (demo time
// = session time), so a stream is a pure function of its index. Each source
// marks the session clock as the demo's origin (`DemoTimeline`), which the
// simulated adapter reads to answer with the speed of the same instant.

/// Device motion, raw accelerometer and gyroscope of the demo car at
/// `rateHz` (`DemoSensorModel.motionPayloads`). The three events of one
/// instant share a timestamp, recorded `motion`, `accel`, `gyro`. Samples
/// already due when it starts (the few ms since the clock was made) come in
/// the first tick; none is ever stamped in the future. `start` while
/// running restarts on the new clock.
@MainActor
public final class DemoMotionSource: SensorSource {
    public let name = "demoMotion"
    public let availability = SensorAvailability.available
    public let rateHz: Double
    public let model: DemoSensorModel
    private let timeline: DemoTimeline
    private var ticker: SimulatedTicker?

    public init(model: DemoSensorModel, timeline: DemoTimeline, rateHz: Double = 100) {
        self.model = model
        self.timeline = timeline
        self.rateHz = rateHz
    }

    public func start(clock: SessionClock, sink: LogSink) throws {
        stop()
        timeline.begin(clock: clock)
        let rateHz = rateHz, model = model
        let ticker = SimulatedTicker(
            label: name, clock: clock, sink: sink,
            period: .nanoseconds(Int64((1_000_000_000 / rateHz).rounded())), start: .zero
        ) { index, t in
            model.motionPayloads(index: index, rateHz: rateHz).map { LogEvent(timestamp: t, payload: $0) }
        }
        self.ticker = ticker
        ticker.begin()
    }

    /// Idempotent. No event reaches the sink after it returns.
    public func stop() {
        ticker?.stop()
        ticker = nil
    }
}

/// The demo car's location fixes (`DemoSensorModel.locationFix(second:)`):
/// GNSS every second for the first minute, then network fixes only, every
/// one with `simulated: true`. Fix `n` (of second `n`) is stamped `n` s on
/// the session clock; `receivedT` equals `t`, `ageS` is 0 and `fixTime` is
/// that instant on the header's wall clock (`SessionClock.wallClock(for:)`,
/// no `Date()` per sample), as `SimulatedLocationSource`.
///
/// `latestReferenceFix` / `onReferenceFix` are the same display hooks as
/// `SimulatedLocationSource`'s (the map's GPS dot and chip): a copy of a
/// fix already handed to the sink, never written anywhere else.
@MainActor
public final class DemoLocationSource: SensorSource {
    public let name = "demoLocation"
    public let availability = SensorAvailability.available
    public let model: DemoSensorModel
    /// The most recent fix delivered, for display only; nil before the first
    /// and after `stop()`.
    public private(set) var latestReferenceFix: LocationSample?
    /// Called on the main actor with each fix as `latestReferenceFix` takes
    /// it. Never for a fix of an earlier run, nor after `stop()`.
    public var onReferenceFix: (@MainActor (LocationSample) -> Void)?
    private let timeline: DemoTimeline
    private var ticker: SimulatedTicker?
    /// Bumped by every `start` and `stop`, so a display update queued by an
    /// earlier run never lands after `stop()` cleared the fix.
    private var displayRun = 0

    public init(model: DemoSensorModel, timeline: DemoTimeline) {
        self.model = model
        self.timeline = timeline
    }

    public func start(clock: SessionClock, sink: LogSink) throws {
        stop()
        timeline.begin(clock: clock)
        displayRun += 1
        let run = displayRun, model = model
        let ticker = SimulatedTicker(label: name, clock: clock, sink: sink, period: .seconds(1), start: .zero) { [weak self] index, t in
            guard var fix = model.locationFix(second: index) else { return [] }
            fix.receivedT = t
            fix.ageS = 0
            fix.fixTime = clock.wallClock(for: t).formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
            fix.simulated = true
            let shown = fix
            Task { @MainActor in self?.show(shown, run: run) }
            return [.location(fix, at: t)]
        }
        self.ticker = ticker
        ticker.begin()
    }

    /// Idempotent. No event reaches the sink after it returns, and
    /// `latestReferenceFix` is nil until the next `start`.
    public func stop() {
        ticker?.stop()
        ticker = nil
        displayRun += 1
        latestReferenceFix = nil
    }

    private func show(_ fix: LocationSample, run: Int) {
        guard run == displayRun else { return }
        latestReferenceFix = fix
        onReferenceFix?(fix)
    }
}
