import DriveLoggerCore
import Foundation

// Pure rules for the dead-reckoning layer of the map (N4 C). No MapKit and no
// SwiftUI, so every decision is unit-testable. Positions are always the
// engine's latitude/longitude, never its plane-relative east/north.

/// A bare WGS-84 position.
struct GeoPoint: Hashable, Sendable {
    var latitude: Double
    var longitude: Double
}

/// What the map draws of the live estimate. A value type so it can be
/// compared and gated; built from a `NavigationSnapshot`.
struct NavDisplay: Hashable, Sendable {
    var position: GeoPoint
    /// 95 % ellipse: semi-axes in metres, major-axis bearing clockwise from north.
    var semiMajorM: Double
    var semiMinorM: Double
    var orientationDeg: Double
    /// Heading of travel, degrees clockwise from north.
    var headingDeg: Double?
    var headingStdDeg: Double?
    /// False while the heading is still being calibrated.
    var converged: Bool

    /// nil without a recording, before initialisation, or for a non-finite estimate.
    init?(_ snapshot: NavigationSnapshot) {
        guard snapshot.sessionID != nil, let lat = snapshot.latitude, let lon = snapshot.longitude,
              let ellipse = snapshot.ellipse,
              lat.isFinite, lon.isFinite, abs(lat) <= 90, abs(lon) <= 180,
              ellipse.semiMajorM.isFinite, ellipse.semiMinorM.isFinite, ellipse.orientationDeg.isFinite
        else { return nil }
        position = GeoPoint(latitude: lat, longitude: lon)
        semiMajorM = ellipse.semiMajorM
        semiMinorM = ellipse.semiMinorM
        orientationDeg = ellipse.orientationDeg
        headingDeg = snapshot.headingDeg.flatMap { $0.isFinite ? $0 : nil }
        headingStdDeg = snapshot.headingStdDeg
        converged = snapshot.converged
    }

    init(
        position: GeoPoint, semiMajorM: Double, semiMinorM: Double, orientationDeg: Double,
        headingDeg: Double? = nil, headingStdDeg: Double? = nil, converged: Bool
    ) {
        self.position = position
        self.semiMajorM = semiMajorM
        self.semiMinorM = semiMinorM
        self.orientationDeg = orientationDeg
        self.headingDeg = headingDeg
        self.headingStdDeg = headingStdDeg
        self.converged = converged
    }
}

/// The debug overlay's numbers (`debug.navStats`). Never logged.
struct NavStatsDisplay: Hashable, Sendable {
    var msPerStep: Double
    var maxMsPerStep: Double
    var effectiveSampleSize: Double?
    var headingStdDeg: Double?
    var speedScale: Double?
    var droppedInputs: Int

    init(_ stats: NavigationSnapshot.Stats) {
        msPerStep = stats.msPerStep
        maxMsPerStep = stats.maxMsPerStep
        effectiveSampleSize = stats.effectiveSampleSize
        headingStdDeg = stats.headingStdDeg
        speedScale = stats.speedScale
        droppedInputs = stats.droppedInputs
    }

    init(
        msPerStep: Double, maxMsPerStep: Double, effectiveSampleSize: Double?,
        headingStdDeg: Double?, speedScale: Double?, droppedInputs: Int
    ) {
        self.msPerStep = msPerStep
        self.maxMsPerStep = maxMsPerStep
        self.effectiveSampleSize = effectiveSampleSize
        self.headingStdDeg = headingStdDeg
        self.speedScale = speedScale
        self.droppedInputs = droppedInputs
    }

    /// One compact line.
    var line: String {
        var parts = [String(format: "%.2f ms/step (max %.1f)", msPerStep, maxMsPerStep)]
        parts.append("ESS " + (effectiveSampleSize.map { String(Int($0.rounded())) } ?? "–"))
        parts.append("hdg σ " + (headingStdDeg.map { String(format: "%.1f°", $0) } ?? "–"))
        parts.append("scale " + (speedScale.map { String(format: "%.3f", $0) } ?? "–"))
        parts.append("dropped \(droppedInputs)")
        return parts.joined(separator: " · ")
    }
}

/// Decides when a new estimate is written to the observed display state, in
/// the style of `HeadingWriteGate` (M9.1-5): when the position moved by more
/// than `minMoveM` or the heading by more than `minHeadingDeg`, and at least
/// `minInterval` after the last write. Appearing and disappearing (a
/// recording starting or ending) and the heading converging are written at
/// once. Pure value type; time is passed in.
struct NavWriteGate: Equatable, Sendable {
    static let minMoveM = 1.0
    static let minHeadingDeg = 2.0
    static let minInterval: Duration = .milliseconds(250)

    private var last: NavDisplay?
    private var lastTime: ContinuousClock.Instant?

    init() {}

    /// True when the caller should publish `value`; records the write.
    mutating func admit(_ value: NavDisplay?, at now: ContinuousClock.Instant) -> Bool {
        guard let value else {
            let changed = last != nil
            self = NavWriteGate()
            return changed
        }
        guard decide(value, at: now) else { return false }
        last = value
        lastTime = now
        return true
    }

    private func decide(_ value: NavDisplay, at now: ContinuousClock.Instant) -> Bool {
        guard let last, let lastTime else { return true }
        if value.converged != last.converged { return true }
        guard now - lastTime >= Self.minInterval else { return false }
        if NavGeometry.distanceM(from: last.position, to: value.position) > Self.minMoveM { return true }
        switch (last.headingDeg, value.headingDeg) {
        case let (a?, b?):
            if abs(HeadingSmoother.shortestDelta(from: a, to: b)) > Self.minHeadingDeg { return true }
        case (nil, nil):
            break
        default:
            return true
        }
        return abs(value.semiMajorM - last.semiMajorM) > max(1, 0.1 * last.semiMajorM)
    }

    mutating func reset() { self = NavWriteGate() }
}

enum NavGeometry {
    static let metersPerDegree = 111_320.0

    /// Equirectangular distance, fine at the scale of a map screen.
    static func distanceM(from a: GeoPoint, to b: GeoPoint) -> Double {
        let dy = (b.latitude - a.latitude) * metersPerDegree
        let dx = (b.longitude - a.longitude) * metersPerDegree * cos((a.latitude + b.latitude) / 2 * .pi / 180)
        return (dx * dx + dy * dy).squareRoot()
    }
}

/// The 95 % ellipse as a polygon ring.
enum EllipsePolygon {
    static let defaultPoints = 48
    /// Drawing floor, metres; a collapsed axis would give a degenerate polygon.
    static let minAxisM = 0.5

    /// `semiMajorM` runs along the bearing `orientationDeg` (clockwise from
    /// north, `ErrorEllipse`'s convention), `semiMinorM` perpendicular to it.
    /// The ring is open (the last point is not a repeat of the first).
    static func ring(
        center: GeoPoint, semiMajorM: Double, semiMinorM: Double, orientationDeg: Double,
        points: Int = defaultPoints
    ) -> [GeoPoint] {
        guard points >= 3, semiMajorM.isFinite, semiMinorM.isFinite, orientationDeg.isFinite else { return [] }
        let a = max(semiMajorM, minAxisM)
        let b = max(min(semiMinorM, semiMajorM), minAxisM)
        let theta = orientationDeg * .pi / 180
        let (sinT, cosT) = (sin(theta), cos(theta))
        let metersPerLon = NavGeometry.metersPerDegree * max(cos(center.latitude * .pi / 180), 1e-6)
        return (0..<points).map { i in
            let u = 2 * Double.pi * Double(i) / Double(points)
            let along = a * cos(u)
            let across = b * sin(u)
            // Major axis unit vector (east, north) = (sinθ, cosθ); minor = (cosθ, -sinθ).
            let east = along * sinT + across * cosT
            let north = along * cosT - across * sinT
            return GeoPoint(
                latitude: center.latitude + north / NavGeometry.metersPerDegree,
                longitude: center.longitude + east / metersPerLon
            )
        }
    }

    static func ring(_ nav: NavDisplay, points: Int = defaultPoints) -> [GeoPoint] {
        ring(
            center: nav.position, semiMajorM: nav.semiMajorM, semiMinorM: nav.semiMinorM,
            orientationDeg: nav.orientationDeg, points: points
        )
    }
}

/// What to draw for the estimate.
enum NavLayers {
    /// Below this the ellipse is smaller than the dot and is not worth drawing, once converged.
    static let hideEllipseBelowM = 3.0

    static func showDot(_ nav: NavDisplay?) -> Bool { nav != nil }

    /// While the heading is not converged the ellipse is always drawn, never
    /// the dot alone; once converged a tiny one is left out.
    static func showEllipse(_ nav: NavDisplay?) -> Bool {
        guard let nav else { return false }
        return !nav.converged || nav.semiMajorM >= hideEllipseBelowM
    }

    /// "Calibrating heading" is only a label.
    static func calibrating(_ nav: NavDisplay?) -> Bool { nav.map { !$0.converged } ?? false }
}

extension CameraHeading {
    /// The bearing heading-up turns to: the dead-reckoning heading once it
    /// has `converged`, otherwise the GPS-course rule (M4.3,
    /// `GPSCourseBearingSource`). Before convergence the DR heading is not
    /// trusted even if present.
    static func targetBearing(drHeading: Double?, converged: Bool, gpsBearing: Double?) -> Double? {
        if converged, let drHeading, drHeading.isFinite { return drHeading }
        return gpsBearing
    }
}

/// Where Following centres.
enum FollowTarget {
    /// The dead-reckoning estimate once initialised, otherwise the GPS fix.
    static func center(dr: GeoPoint?, gps: GeoPoint?) -> GeoPoint? { dr ?? gps }
}

enum FollowSpan {
    static let maxFitM = 1000.0
    static let ellipseFactor = 2.2

    /// Heading-up span that fits the ellipse:
    /// `min(1000, max(minimum, 2.2 × semi-major))`. A `minimum` already above
    /// 1000 m (the driver zoomed out) is kept: the fit never zooms *in* past
    /// what the driver chose.
    static func span(minimum: Double, semiMajorM: Double) -> Double {
        let fit = semiMajorM.isFinite ? ellipseFactor * max(semiMajorM, 0) : 0
        return max(minimum, min(maxFitM, fit))
    }
}

/// Where a dropped "I'm here" pin starts. The driver only nudges it.
enum PinStart {
    static func position(dr: GeoPoint?, gps: GeoPoint?, finger: GeoPoint?) -> GeoPoint? {
        dr ?? gps ?? finger
    }
}

/// "I'm here" needs a zoomed-in map so the nudged pin is placed precisely.
enum PinPrecision {
    static let maxSpanM = 300.0
    static let hint = "Zoom in to place the pin precisely"

    /// An unknown span (no camera report yet) is not precise.
    static func isPreciseEnough(visibleSpanM: Double?) -> Bool {
        guard let visibleSpanM, visibleSpanM.isFinite else { return false }
        return visibleSpanM <= maxSpanM
    }
}

extension ManualFixText {
    /// Why Confirm is disabled, nil when it is enabled: the recorder's reason
    /// first, then the zoom rule.
    static func confirmBlockedReason(_ availability: ManualFixAvailability, visibleSpanM: Double?) -> String? {
        if let reason = disabledReason(availability) { return reason }
        return PinPrecision.isPreciseEnough(visibleSpanM: visibleSpanM) ? nil : PinPrecision.hint
    }
}
