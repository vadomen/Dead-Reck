import DriveLoggerCore
import Foundation

/// Where the map's one speed number comes from, and how good it is.
/// Pure values: no clocks, no sensors, so the rule is unit-testable and UX-6
/// (speed-dependent zoom) can reuse it.
enum MapSpeedSource: Hashable, Sendable {
    case obd, gps, none
}

/// GPS quality for the chip colour, so jamming stays visible on the map.
enum MapSpeedQuality: Hashable, Sendable {
    /// Horizontal accuracy 15 m or better.
    case good
    /// Up to 100 m.
    case fair
    /// Network fix (no valid speed), worse than 100 m, stale or no fix.
    case unknown
}

struct MapSpeedReadout: Hashable, Sendable {
    var source: MapSpeedSource
    /// Whole km/h; nil when `source` is `.none`.
    var kmh: Int?
    var quality: MapSpeedQuality

    static let none = MapSpeedReadout(source: .none, kmh: nil, quality: .unknown)

    /// The large number: `54`, or `—`.
    var valueText: String { kmh.map(String.init) ?? "—" }

    /// The chip: `OBD`, `GPS`, or nil when there is no speed.
    var sourceText: String? {
        switch source {
        case .obd: "OBD"
        case .gps: "GPS"
        case .none: nil
        }
    }

    /// One line, for accessibility and logs of the rule: `54 km/h · OBD`, `— km/h`.
    var summary: String {
        guard let chip = sourceText else { return "\(valueText) km/h" }
        return "\(valueText) km/h · \(chip)"
    }
}

enum MapSpeedRule {
    /// Oldest OBD reply, seconds, that still counts (the same freshness as
    /// `ManualFixGate.maxOBDAgeS` and the engine).
    static let maxOBDAgeS: Double = 2
    /// Oldest GPS fix, seconds, whose speed counts and whose accuracy colours
    /// the chip: 2 s, the same as OBD (the UX-5 decision). The map gets each
    /// fix on arrival (`RecordingSession.latestFix`, R24.1-1): on a 1 Hz
    /// stream a fix is about 1.0–1.2 s old when the next one replaces it.
    /// Measured on the fix timing of five recorded drives with valid-speed
    /// fixes (~105 min): 3 stale moments of at most 0.01 s at 2 s, apart
    /// from real gaps in the stream. It was 3 s while the map took fixes
    /// from the 1 s live tick.
    static let maxGPSAgeS: Double = 2

    /// OBD if its vehicle-speed reply is at most `maxOBDAgeS` old, else GPS if
    /// the fix has a speed (`speed >= 0`) and is at most `maxGPSAgeS` old, else
    /// none.
    ///
    /// - Parameters:
    ///   - obdKmh: the latest primary-ECU (7E8, or unattributed) vehicle
    ///     speed, km/h, as received. Other ECUs are filtered upstream
    ///     (`RecordingSession` takes only `isFromPrimaryECU` readings).
    ///   - obdAgeS: seconds since that reply; nil when unknown.
    ///   - fix: the latest reference fix.
    ///   - fixAgeS: seconds since the fix (fix time, not ingest time); nil when unknown.
    ///
    /// Ages are compared in integer nanoseconds, so exactly 2.0 s counts as
    /// fresh. A negative age (clock skew) counts as fresh, like `ManualFixGate`.
    static func resolve(
        obdKmh: Double?, obdAgeS: Double?, fix: LocationSample?, fixAgeS: Double?
    ) -> MapSpeedReadout {
        let fixFresh = isFresh(fixAgeS, max: maxGPSAgeS)
        let quality = fixFresh ? Self.quality(of: fix) : .unknown
        if let obdKmh, obdKmh.isFinite, isFresh(obdAgeS, max: maxOBDAgeS) {
            return MapSpeedReadout(source: .obd, kmh: wholeKmh(obdKmh), quality: quality)
        }
        if fixFresh, let fix, fix.speed >= 0, fix.speed.isFinite {
            return MapSpeedReadout(source: .gps, kmh: wholeKmh(fix.speed * 3.6), quality: quality)
        }
        return .none
    }

    /// Chip colour band of a fix. Network fixes (no valid speed or speed
    /// accuracy) and invalid accuracy are `.unknown` whatever accuracy they report.
    static func quality(of fix: LocationSample?) -> MapSpeedQuality {
        guard let fix, fix.speed >= 0, fix.speedAccuracy >= 0,
              fix.horizontalAccuracy.isFinite, fix.horizontalAccuracy >= 0 else { return .unknown }
        switch fix.horizontalAccuracy {
        case ...15: return .good
        case ...100: return .fair
        default: return .unknown
        }
    }

    static func isFresh(_ ageS: Double?, max maxAgeS: Double) -> Bool {
        guard let ageS, ageS.isFinite else { return false }
        return Int64((ageS * 1e9).rounded()) <= Int64(maxAgeS * 1e9)
    }

    /// Nearest whole km/h, never negative.
    private static func wholeKmh(_ value: Double) -> Int {
        Int(max(0, value).rounded())
    }
}
