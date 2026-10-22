import Foundation

/// `navPrior` (format v5): the live navigator's estimate a recording's
/// navigation run started from (prompt 40, the Navigate → Record
/// hand-over). Written at most once per recording, right after the `start`
/// row and before every other row (the start-up init replay included), so
/// before the first `motion`, `location` or `obd` row: a replay reads it
/// before any engine input and starts from the same prior the live run did.
/// A recording started with no initialised Navigate estimate has no row
/// and is otherwise exactly what it would have been without this kind.
///
/// The event's `t` is when the recording took the estimate over (Record
/// start, `clock.now()` on the recording's clock). `estimateT` is the time
/// the estimate describes, on the **same** clock: the estimate's uptime
/// minus the recording's `referenceUptimeSeconds`. It is normally negative
/// (the estimate predates the recording) and is never clamped. No wall
/// clock: the header's `startedAt` stays the only one in the file.
///
/// The navigator's output, not a measurement: none of these fields is a
/// sensor reading or a reference fix. The row only says what the live run
/// assumed at its start, so the drive replays bit-exactly.
///
/// An on-disk type: every stored property name is a JSON key and part of
/// the format. `restoreClass` and `source` are stored as `String`s (like
/// the other vocabularies) so a value added by a later build still decodes
/// and is kept verbatim; `invalidField` and `navigationPrior` refuse a
/// value this build does not know. The row decodes as written, like every
/// other sample (JSON cannot carry NaN or infinity, so a non-finite value
/// makes the line malformed and the reader skips it); range checks live in
/// `invalidField`.
public struct NavPriorSample: Hashable, Sendable, Codable {
    /// Degrees, WGS 84, of the estimate's mean.
    public var latitude: Double
    /// Degrees, WGS 84, of the estimate's mean.
    public var longitude: Double
    /// Position covariance, east/north, m².
    public var covEE: Double
    public var covEN: Double
    public var covNN: Double
    /// Heading of travel, degrees clockwise from north, [0, 360).
    public var headingDeg: Double
    /// Circular std of the heading, degrees.
    public var headingStdDeg: Double
    /// The estimate's `converged`.
    public var converged: Bool
    /// The estimate's speed, m/s (the growth over the gap uses it).
    public var speedMps: Double
    /// The last OBD vehicle speed the estimating run had, raw km/h; absent
    /// without a reply. Information: the prior's growth does not use it.
    public var obdSpeedKmh: Double?
    /// How the car was left: `NavigationRestoreClass` raw values
    /// (`moving`, `standingStop`, `parked`).
    public var restoreClass: String
    /// Where the estimate came from (`Source` raw values; an open set).
    public var source: String
    /// The time the estimate describes, on the recording's session clock,
    /// integer nanoseconds. Normally negative; never clamped.
    public var estimateT: MonotonicTimestamp

    public init(
        latitude: Double, longitude: Double, covEE: Double, covEN: Double, covNN: Double,
        headingDeg: Double, headingStdDeg: Double, converged: Bool, speedMps: Double,
        obdSpeedKmh: Double? = nil, restoreClass: String, source: String, estimateT: MonotonicTimestamp
    ) {
        self.latitude = latitude
        self.longitude = longitude
        self.covEE = covEE
        self.covEN = covEN
        self.covNN = covNN
        self.headingDeg = headingDeg
        self.headingStdDeg = headingStdDeg
        self.converged = converged
        self.speedMps = speedMps
        self.obdSpeedKmh = obdSpeedKmh
        self.restoreClass = restoreClass
        self.source = source
        self.estimateT = estimateT
    }

    /// `source` vocabulary. Raw values are on-disk strings: never rename
    /// them. Open set: a later build may add a value without a version bump;
    /// readers keep unknown values verbatim.
    public enum Source: String, Hashable, Sendable, CaseIterable {
        /// The running Navigate session's estimate, taken over at Record
        /// start.
        case navigate
    }

    /// The first field out of range, not finite or not in this build's
    /// vocabulary; nil when the row can seed a run. `source` is an open set
    /// and never invalid; `estimateT` has no range (negative is normal).
    public var invalidField: String? {
        if !latitude.isFinite || abs(latitude) > 90 { return "latitude" }
        if !longitude.isFinite || abs(longitude) > 180 { return "longitude" }
        if !covEE.isFinite || covEE < 0 { return "covEE" }
        if !covNN.isFinite || covNN < 0 { return "covNN" }
        if !covEN.isFinite || covEE * covNN - covEN * covEN < -1e-9 * max(1, covEE * covNN) { return "covEN" }
        if !headingDeg.isFinite || headingDeg < 0 || headingDeg >= 360 { return "headingDeg" }
        if !headingStdDeg.isFinite || headingStdDeg < 0 { return "headingStdDeg" }
        if !speedMps.isFinite || speedMps < 0 { return "speedMps" }
        if let v = obdSpeedKmh, !v.isFinite || v < 0 { return "obdSpeedKmh" }
        if NavigationRestoreClass(rawValue: restoreClass) == nil { return "restoreClass" }
        return nil
    }
}

// MARK: - Conversions (the navigation side calls these)

extension NavPriorSample {
    /// A row for `prior` (its `savedT` becomes `estimateT`, `lastSpeedMps`
    /// `speedMps`). `prior.handOver` is not stored: every `navPrior` row is
    /// a hand-over (`navigationPrior`).
    public init(_ prior: NavigationPrior, obdSpeedKmh: Double?, source: Source = .navigate) {
        self.init(
            latitude: prior.latitude, longitude: prior.longitude,
            covEE: prior.covEE, covEN: prior.covEN, covNN: prior.covNN,
            headingDeg: prior.headingDeg, headingStdDeg: prior.headingStdDeg,
            converged: prior.converged, speedMps: prior.lastSpeedMps, obdSpeedKmh: obdSpeedKmh,
            restoreClass: prior.restoreClass.rawValue, source: source.rawValue, estimateT: prior.savedT)
    }

    /// The row for a running Navigate session's `capture` (`state`, stamped
    /// with its uptime), on the recording's `clock`: `estimateT` =
    /// `clock.timestamp(uptimeSeconds: state.uptimeSeconds)`, the
    /// estimate's uptime minus the recording's reference uptime, negative
    /// when it predates the recording and never clamped. Uptime only: the
    /// state's wall-clock `savedAt` is not used (a hand-over happens in one
    /// process, on one boot). nil when the state is invalid
    /// (`NavigationRestoreState.invalidField`) or its uptime is too far
    /// from the clock's for a timestamp.
    public init?(handOver state: NavigationRestoreState, clock: SessionClock, source: Source = .navigate) {
        guard state.invalidField == nil else { return nil }
        let offset = state.uptimeSeconds - clock.referenceUptimeSeconds
        // `MonotonicTimestamp(seconds:)` traps beyond Int64 nanoseconds
        // (± 292 years); an uptime pair this far apart is not one boot.
        guard offset.isFinite, abs(offset) < 9e9 else { return nil }
        let sample = NavPriorSample(
            latitude: state.latitude, longitude: state.longitude,
            covEE: state.covEE, covEN: state.covEN, covNN: state.covNN,
            headingDeg: state.headingDeg, headingStdDeg: state.headingStdDeg,
            converged: state.converged, speedMps: state.speedMps, obdSpeedKmh: state.lastOBDSpeedKmh,
            restoreClass: state.restoreClass.rawValue, source: source.rawValue,
            estimateT: clock.timestamp(uptimeSeconds: state.uptimeSeconds))
        guard sample.invalidField == nil else { return nil }
        self = sample
    }

    /// The engine's prior for the recording's run: field for field, with
    /// `savedT` = `estimateT` and `handOver` = true (39's hand-over rule:
    /// converged and a gap up to `NavigationRestoreModel.handOverConfirmMaxGapS`
    /// confirms at once). nil when `invalidField` is not nil: the run then
    /// starts fresh, live and in a replay alike. Any `source` converts.
    public var navigationPrior: NavigationPrior? {
        guard invalidField == nil, let restoreClass = NavigationRestoreClass(rawValue: restoreClass) else { return nil }
        let prior = NavigationPrior(
            latitude: latitude, longitude: longitude, covEE: covEE, covEN: covEN, covNN: covNN,
            headingDeg: headingDeg, headingStdDeg: headingStdDeg, savedT: estimateT,
            lastSpeedMps: speedMps, restoreClass: restoreClass, converged: converged, handOver: true)
        return prior.isValid ? prior : nil
    }
}
