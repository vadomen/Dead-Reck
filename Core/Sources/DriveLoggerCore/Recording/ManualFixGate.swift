import Foundation

/// Whether the driver may confirm a manual position fix right now, and the
/// `manualFix` row for one (docs/LOG_FORMAT.md, `manualFix`).
///
/// A pin dropped at speed is not ground truth: by the time it is placed the
/// car has moved on. So a fix is allowed only at or below `maxSpeedKmh`, or
/// when the speed is unknown (refusing then would make the feature useless
/// exactly where it matters: no OBD and no GNSS).
///
/// Rule, evaluated at `now` on the session clock:
/// 1. OBD speed whose reply is at most `maxOBDAgeS` old
///    (`now − obdSpeedT`) → it is the gate speed (`obd`). An OBD speed with
///    no reply time does not count.
/// 2. Otherwise the reference fix's speed, only if `speed ≥ 0`,
///    `speedAccuracy ≥ 0`, `horizontalAccuracy ≥ 0`,
///    `horizontalAccuracy ≤ maxReferenceHorizontalAccuracyM`, and the fix is
///    at most `maxFixAgeS` old (`now − (receivedT − ageS)`, `ageS` taken as
///    0 when absent; a fix with no `receivedT` does not count) (`gps`).
/// 3. Otherwise `unknown`, allowed.
///
/// Allowed iff the gate speed is `≤ maxSpeedKmh` or unknown. Ages are
/// compared in integer nanoseconds, so exactly 2.0 s / 5.0 s count. A
/// negative age (the reply or fix stamped after `now`: clock skew between
/// sources, or `ageS < 0`) counts as fresh. It is not clamped and it is not
/// treated as stale: the input is the most recent there is. GNSS stays
/// reference data: it only decides whether a row is written, never a value
/// derived from it.
///
/// A stale input still goes into the row (`obdSpeedKmh`/`obdSpeedT`,
/// `gpsSpeedKmh`); `speedSource`/`gateSpeedKmh` say what the gate actually
/// used.
public enum ManualFixGate {
    /// Highest speed, km/h, at which a fix may be confirmed.
    public static let maxSpeedKmh: Double = 10
    /// Worst reference horizontal accuracy, metres, whose speed is trusted
    /// for the gate.
    public static let maxReferenceHorizontalAccuracyM: Double = 100
    /// Oldest OBD reply, seconds, whose speed gates.
    public static let maxOBDAgeS: Double = 2
    /// Oldest reference fix, seconds (by fix time), whose speed gates.
    public static let maxFixAgeS: Double = 5

    public struct Result: Hashable, Sendable {
        public var speedSource: ManualFixSample.SpeedSource
        /// The gate speed, km/h; nil when `speedSource` is `unknown`.
        public var speedKmh: Double?
        public var isAllowed: Bool

        public init(speedSource: ManualFixSample.SpeedSource, speedKmh: Double?, isAllowed: Bool) {
            self.speedSource = speedSource
            self.speedKmh = speedKmh
            self.isAllowed = isAllowed
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
        if let obdSpeedKmh, let obdSpeedT, isFresh(obdSpeedT, at: now, maxAgeS: maxOBDAgeS) {
            return Result(speedSource: .obd, speedKmh: obdSpeedKmh, isAllowed: obdSpeedKmh <= maxSpeedKmh)
        }
        if let fix = referenceFix,
           fix.speed >= 0, fix.speedAccuracy >= 0,
           fix.horizontalAccuracy >= 0, fix.horizontalAccuracy <= maxReferenceHorizontalAccuracyM,
           let fixTime = fixTime(of: fix), isFresh(fixTime, at: now, maxAgeS: maxFixAgeS) {
            let kmh = fix.speed * 3.6
            return Result(speedSource: .gps, speedKmh: kmh, isAllowed: kmh <= maxSpeedKmh)
        }
        return Result(speedSource: .unknown, speedKmh: nil, isAllowed: true)
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

    /// The `manualFix` payload for a pin confirmed at `now`, or nil when the
    /// gate (evaluated at `now`) refuses it or (`latitude`, `longitude`) is not a finite WGS 84
    /// position. A non-finite or negative `mapSpanM` is dropped (JSON has no
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
        note: String?
    ) -> ManualFixSample? {
        guard latitude.isFinite, longitude.isFinite,
              (-90...90).contains(latitude), (-180...180).contains(longitude) else { return nil }
        let gate = evaluate(now: now, obdSpeedKmh: obdSpeedKmh, obdSpeedT: obdSpeedT, referenceFix: referenceFix)
        guard gate.isAllowed else { return nil }
        return ManualFixSample(
            latitude: latitude,
            longitude: longitude,
            pressedT: pressedT,
            mapSpanM: mapSpanM.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil },
            obdSpeedKmh: obdSpeedKmh,
            obdSpeedT: obdSpeedKmh == nil ? nil : obdSpeedT,
            gpsSpeedKmh: referenceSpeedKmh(of: referenceFix),
            speedSource: gate.speedSource.rawValue,
            gateSpeedKmh: gate.speedKmh,
            note: ManualFixSample.normalizedNote(note)
        )
    }
}
