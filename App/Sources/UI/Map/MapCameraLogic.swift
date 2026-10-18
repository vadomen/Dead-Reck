import DriveLoggerCore
import Foundation

/// Pure decisions for the follow camera. No MapKit, so they are unit-testable.
enum CameraHeading {
    /// Heading the camera should have: 0 north-up; heading-up the smoothed
    /// heading, else the bearing. With no bearing it is 0 even if a stale
    /// smoothed value is left over (for example from the previous recording).
    static func choose(headingUp: Bool, bearing: Double?, smoothed: Double?) -> Double {
        guard headingUp, let bearing else { return 0 }
        return smoothed ?? bearing
    }
}

/// Limits how often the heading-up camera is written: only when the heading
/// moved by more than `minDelta` since the last write and at least
/// `minInterval` has passed. The smoother itself may still step faster.
struct HeadingWriteGate: Equatable, Sendable {
    static let minDelta = 2.0
    static let minInterval: Duration = .milliseconds(250)

    private var lastHeading: Double?
    private var lastTime: ContinuousClock.Instant?

    init() {}

    /// True when the caller should write `heading`; records the write.
    mutating func admit(_ heading: Double, at now: ContinuousClock.Instant) -> Bool {
        if let lastHeading, let lastTime {
            guard now - lastTime >= Self.minInterval else { return false }
            // Shortest way round: 359 to 1 is 2 degrees, not 358.
            guard abs(HeadingSmoother.shortestDelta(from: lastHeading, to: heading)) > Self.minDelta else { return false }
        }
        lastHeading = heading
        lastTime = now
        return true
    }

    /// True when at least `minInterval` has passed since the last write
    /// (or there was none): the rate limit every 10 Hz loop write obeys.
    func isDue(at now: ContinuousClock.Instant) -> Bool {
        guard let lastTime else { return true }
        return now - lastTime >= Self.minInterval
    }

    /// Note a write made elsewhere (recentre, mode switch).
    mutating func noteWrite(_ heading: Double, at now: ContinuousClock.Instant) {
        lastHeading = heading
        lastTime = now
    }

    mutating func reset() { self = HeadingWriteGate() }
}

extension CameraHeading {
    /// Heading for the first camera write after heading-up becomes active
    /// (tab return, mode toggle, Following resumes): reseeds the smoother to
    /// the last good bearing and resets the write gate, so the write snaps to
    /// that bearing even while frozen at a stop. 0 with no bearing.
    static func activate(
        smoother: inout HeadingSmoother, gate: inout HeadingWriteGate, bearing: Double?
    ) -> Double {
        smoother.reseed(to: bearing)
        gate.reset()
        return choose(headingUp: true, bearing: bearing, smoothed: smoother.heading)
    }
}

/// The map's auto-resume loop, with the clock and sleep injected so a test can
/// drive it (M10.1-6). Sleeps until the deadline, tries to resume, and goes
/// round again while a deadline remains (a gesture can push it out).
enum FollowResumeLoop {
    /// `deadline` reads the current deadline (nil ends the loop); `resumeIfDue`
    /// returns true when Following resumed, which ends it. A cancelled task
    /// ends it right after the sleep.
    @MainActor
    static func run(
        deadline: () -> ContinuousClock.Instant?,
        now: () -> ContinuousClock.Instant,
        sleep: (ContinuousClock.Instant) async -> Void,
        resumeIfDue: () -> Bool
    ) async {
        while let target = deadline() {
            if now() < target {
                await sleep(target)
                if Task.isCancelled { return }
            }
            if resumeIfDue() { return }
        }
    }
}

/// When the heading smoother and write gate are cleared (M9.1-1/M9.1-2),
/// pure so the rules are testable without the view.
enum HeadingReset {
    /// Whether the run changed to a different one: a new recording or a new
    /// Navigate session. `nil` (after Stop the model keeps the old key, so
    /// nil only before the first run) never resets.
    static func isNewRun(from old: MapRunKey?, to new: MapRunKey?) -> Bool {
        guard let new, new.file != nil || new.run != nil else { return false }
        return new != old
    }

    /// A new run: nothing of the last drive may turn the map.
    static func newRun(
        smoother: inout HeadingSmoother, gate: inout HeadingWriteGate, publishPending: inout Bool
    ) {
        smoother = HeadingSmoother()
        gate.reset()
        publishPending = false
    }

    /// The bearing changed to `new`: with none left (and no effective one),
    /// drop a stale smoothed heading.
    static func bearingChanged(
        to new: Double?, effectiveBearing: Double?, smoother: inout HeadingSmoother
    ) {
        if new == nil, effectiveBearing == nil { smoother = HeadingSmoother() }
    }
}

/// One camera write decided by the 10 Hz follow loop.
struct FollowCameraWrite: Equatable, Sendable {
    let heading: Double
    let distance: Double
}

/// The follow loop's per-tick write decision, pure (R26.2-1). Every loop
/// write, whatever wants it (a feed publish, a heading change, the auto zoom
/// moving), waits for `HeadingWriteGate.isDue`, so the camera is written at
/// most 4 times a second in every mode. A publish that arrives while the gate
/// is closed is kept in `publishPending` and lands on the next open tick; the
/// zoom needs no flag, `autoWantsWrite` stays true until it is written. With
/// nothing wanted it writes nothing (R26.1-1). Non-loop writes (recentre,
/// framing, mode toggle) do not go through here and stay immediate; they
/// still `noteWrite`, so the loop waits after them.
enum FollowCameraTick {
    /// Steps the heading smoother and returns the write to make, if any.
    /// `hasCenter` is whether `FollowTarget.center` found a position.
    static func decide(
        smoother: inout HeadingSmoother, gate: inout HeadingWriteGate, zoom: inout FollowZoom,
        publishPending: inout Bool,
        published: Bool, headingUp: Bool, frozen: Bool, target: Double?,
        hasEstimate: Bool, hasCenter: Bool, semiMajorM: Double?, dt: Double,
        now: ContinuousClock.Instant
    ) -> FollowCameraWrite? {
        let due = gate.isDue(at: now)
        var heading = 0.0
        var write = published || publishPending
        let zoomWrite = zoom.autoWantsWrite(headingUp: headingUp, semiMajorM: semiMajorM)
        if headingUp {
            if target == nil {
                smoother = HeadingSmoother()
            } else if let h = smoother.step(target: target, frozen: frozen, dt: dt) {
                heading = h
                if due, gate.admit(h, at: now) { write = true }
            }
        }
        // Without an estimate the GPS onChange recentres north-up;
        // heading-up still turns around the fix.
        guard write || zoomWrite, hasCenter,
              hasEstimate || (headingUp && target != nil) || zoomWrite else {
            publishPending = false
            return nil
        }
        guard due else {
            publishPending = write
            return nil
        }
        publishPending = false
        let distance = zoom.autoFollowDistance(headingUp: headingUp, semiMajorM: semiMajorM)
        gate.noteWrite(heading, at: now)
        return FollowCameraWrite(heading: heading, distance: distance)
    }
}

enum MapChange {
    /// True when `new` differs from `old` by more than `relative` (1% default).
    static func isSignificant(old: Double?, new: Double, relative: Double = 0.01) -> Bool {
        guard let old, old.isFinite, old != 0 else { return true }
        return abs(new - old) / abs(old) > relative
    }
}

/// "Stopped" for heading-up: OBD speed exactly 0 from a fresh reply, judged
/// by the manual-fix gate's own rule (`ManualFixGate.maxOBDAgeS`). A stale 0
/// is unknown, not stopped, so an ELM stall at a stop cannot freeze the
/// heading after drive-off.
enum StationaryRule {
    static func isStopped(kmh: Double?, replyUptime: Double?, now: Double) -> Bool {
        guard let kmh, let replyUptime else { return false }
        let gate = ManualFixGate.evaluate(
            now: MonotonicTimestamp(seconds: now),
            obdSpeedKmh: kmh,
            obdSpeedT: MonotonicTimestamp(seconds: replyUptime),
            referenceFix: nil
        )
        return gate.speedSource == .obd && gate.speedKmh == 0
    }
}

extension MapFraming {
    /// Camera distance for a region `spanMeters` tall. Approximate (MapKit's
    /// field of view is not documented); used only to rebuild a camera when
    /// the framing rule is applied in heading-up.
    static let distancePerSpan = 1.87

    static func cameraDistance(spanMeters: Double) -> Double { spanMeters * distancePerSpan }
}

/// What identifies a run on the map: the recording's file and the session's
/// run generation (one counter for recordings and Navigate sessions; a
/// Navigate session has no file).
struct MapRunKey: Equatable, Sendable {
    var file: URL?
    var run: Int?
}
