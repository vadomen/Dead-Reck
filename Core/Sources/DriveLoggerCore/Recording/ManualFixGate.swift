import Foundation

/// The speed conditions at a manual position fix, and the `manualFix` row for
/// one (docs/LOG_FORMAT.md, `manualFix`).
///
/// There is no speed limit: a fix is recorded at any speed, with the speed
/// conditions beside it so an analysis can judge it. (Recordings made before
/// the double-tap flow were gated at 10 km/h; their rows are the same shape.)
///
/// Which speed describes the fix, evaluated at `now` on the session clock:
/// 1. A finite OBD speed whose reply is at most `maxOBDAgeS` old
///    (`now − obdSpeedT`) → it is the speed (`obd`). An OBD speed with
///    no reply time does not count.
/// 2. Otherwise the reference fix's speed, only if `speed ≥ 0`,
///    `speedAccuracy ≥ 0`, `horizontalAccuracy ≥ 0`,
///    `horizontalAccuracy ≤ maxReferenceHorizontalAccuracyM`, and the fix is
///    at most `maxFixAgeS` old (`now − (receivedT − ageS)`, `ageS` taken as
///    0 when absent; a fix with no `receivedT` does not count) (`gps`).
/// 3. Otherwise `unknown`.
///
/// Ages are compared in integer nanoseconds, so exactly 2.0 s / 5.0 s count.
/// A negative age (the reply or fix stamped after `now`: clock skew between
/// sources, or `ageS < 0`) counts as fresh. It is not clamped and it is not
/// treated as stale: the input is the most recent there is. GNSS stays
/// reference data: it only picks which speed is described, never a value
/// derived from it.
///
/// A stale input still goes into the row (`obdSpeedKmh`/`obdSpeedT`,
/// `gpsSpeedKmh`); `speedSource`/`gateSpeedKmh` say which speed was used.
public enum ManualFixGate {
    /// Worst reference horizontal accuracy, metres, whose speed is trusted.
    public static let maxReferenceHorizontalAccuracyM: Double = 100
    /// Oldest OBD reply, seconds, whose speed counts.
    public static let maxOBDAgeS: Double = 2
    /// Oldest reference fix, seconds (by fix time), whose speed counts.
    public static let maxFixAgeS: Double = 5

    public struct Result: Hashable, Sendable {
        public var speedSource: ManualFixSample.SpeedSource
        /// The speed, km/h; nil when `speedSource` is `unknown`.
        public var speedKmh: Double?

        public init(speedSource: ManualFixSample.SpeedSource, speedKmh: Double?) {
            self.speedSource = speedSource
            self.speedKmh = speedKmh
        }
    }

    /// - Parameters:
    ///   - now: the moment of evaluation, on the same clock as `obdSpeedT`
    ///     and the fix's `receivedT`.
    ///   - obdSpeedKmh: last primary-ECU vehicle speed, nil when unknown.
    ///   - obdSpeedT: when that reply arrived.
    ///   - referenceFix: latest reference GNSS fix, nil when none.
    public static func evaluate(
        now: MonotonicTimestamp,
        obdSpeedKmh: Double?,
        obdSpeedT: MonotonicTimestamp?,
        referenceFix: LocationSample?
    ) -> Result {
        if let obdSpeedKmh, obdSpeedKmh.isFinite, let obdSpeedT, isFresh(obdSpeedT, at: now, maxAgeS: maxOBDAgeS) {
            return Result(speedSource: .obd, speedKmh: obdSpeedKmh)
        }
        if let fix = referenceFix,
           fix.speed >= 0, fix.speed.isFinite, fix.speedAccuracy >= 0,
           fix.horizontalAccuracy >= 0, fix.horizontalAccuracy <= maxReferenceHorizontalAccuracyM,
           let fixTime = fixTime(of: fix), isFresh(fixTime, at: now, maxAgeS: maxFixAgeS) {
            let kmh = fix.speed * 3.6
            return Result(speedSource: .gps, speedKmh: kmh)
        }
        return Result(speedSource: .unknown, speedKmh: nil)
    }

    /// The fix time on the session clock, `receivedT − ageS` (the `t` of its
    /// `location` row); nil without `receivedT` or with a non-finite `ageS`.
    static func fixTime(of fix: LocationSample) -> MonotonicTimestamp? {
        guard let receivedT = fix.receivedT else { return nil }
        let ageS = fix.ageS ?? 0
        guard ageS.isFinite else { return nil }
        return MonotonicTimestamp(nanoseconds: receivedT.nanoseconds - Int64((ageS * 1e9).rounded()))
    }

    /// `now − t ≤ maxAgeS`, in integer nanoseconds. Negative ages are fresh.
    private static func isFresh(_ t: MonotonicTimestamp, at now: MonotonicTimestamp, maxAgeS: Double) -> Bool {
        now.nanoseconds - t.nanoseconds <= Int64((maxAgeS * 1e9).rounded())
    }

    /// Speed of `fix` in km/h when it reports one (`speed ≥ 0`), for the
    /// row's reference-only `gpsSpeedKmh`.
    public static func referenceSpeedKmh(of fix: LocationSample?) -> Double? {
        guard let fix, fix.speed >= 0, fix.speed.isFinite else { return nil }
        return fix.speed * 3.6
    }

    /// The `manualFix` payload for a fix taken at `now` (the tap), or nil when
    /// (`latitude`, `longitude`) is not a finite WGS 84 position. A non-finite or negative `mapSpanM` is dropped (JSON has no
    /// NaN); `obdSpeedT` is kept only with an OBD speed; `note` goes
    /// through `ManualFixSample.normalizedNote`.
    public static func sample(
        now: MonotonicTimestamp,
        latitude: Double,
        longitude: Double,
        pressedT: MonotonicTimestamp,
        mapSpanM: Double?,
        obdSpeedKmh: Double?,
        obdSpeedT: MonotonicTimestamp?,
        referenceFix: LocationSample?,
        note: String? = nil
    ) -> ManualFixSample? {
        guard latitude.isFinite, longitude.isFinite,
              (-90...90).contains(latitude), (-180...180).contains(longitude) else { return nil }
        let gate = evaluate(now: now, obdSpeedKmh: obdSpeedKmh, obdSpeedT: obdSpeedT, referenceFix: referenceFix)
        return ManualFixSample(
            latitude: latitude,
            longitude: longitude,
            pressedT: pressedT,
            mapSpanM: mapSpanM.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil },
            obdSpeedKmh: obdSpeedKmh.flatMap { $0.isFinite ? $0 : nil },
            obdSpeedT: obdSpeedKmh.flatMap { $0.isFinite ? $0 : nil } == nil ? nil : obdSpeedT,
            gpsSpeedKmh: referenceSpeedKmh(of: referenceFix),
            speedSource: gate.speedSource.rawValue,
            gateSpeedKmh: gate.speedKmh,
            note: ManualFixSample.normalizedNote(note)
        )
    }
}
