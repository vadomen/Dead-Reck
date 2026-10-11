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

/// A double tap records a manual fix only on a zoomed-in map, so the point
/// under the finger is precise.
enum PinPrecision {
    static let maxSpanM = 300.0
    static let hint = "Zoom in to place the pin precisely"

    /// An unknown span (no camera report yet) is not precise. The span is the
    /// one before the double tap's own zoom.
    static func isPreciseEnough(visibleSpanM: Double?) -> Bool {
        guard let visibleSpanM, visibleSpanM.isFinite else { return false }
        return visibleSpanM <= maxSpanM
    }
}

/// The follow camera's distance decision (R14.2-1), pure.
///
/// `chosen` is the zoom the driver wants: set only by a driver gesture (a
/// camera report that is not our own write) and by `frame()`. `writtenDistance`
/// is the distance of our latest camera write. Heading-up widens the written
/// distance to fit the ellipse (`FollowSpan`), always from `chosen`, so a
/// widening is never read back as the driver's choice and the distance
/// returns to `chosen` when the ellipse shrinks.
struct FollowZoom: Equatable, Sendable {
    /// A report within this fraction of `writtenDistance` is our own write.
    static let ownWriteTolerance = 0.03
    static let initialDistance = 1500.0

    private(set) var chosen = Self.initialDistance
    private(set) var writtenDistance = 0.0

    init() {}

    /// The framing rule moved the camera. `distance` is the camera distance
    /// it wrote, nil when it wrote a region (the next report then is the
    /// framed distance and becomes `chosen`).
    mutating func frame(distance: Double?) {
        if let distance {
            chosen = distance
            writtenDistance = distance
        } else {
            writtenDistance = 0
        }
    }

    /// A camera report (end of a camera change). Not our own write: the driver zoomed.
    mutating func cameraReported(distance: Double) {
        guard distance.isFinite, distance > 0 else { return }
        if writtenDistance <= 0 || abs(distance - writtenDistance) / writtenDistance > Self.ownWriteTolerance {
            chosen = distance
        }
    }

    /// The distance for a follow write: `chosen`, in heading-up with an
    /// estimate widened to fit its ellipse. Records it as `writtenDistance`.
    mutating func followDistance(headingUp: Bool, semiMajorM: Double?) -> Double {
        let distance = Self.distance(chosen: chosen, headingUp: headingUp, semiMajorM: semiMajorM)
        writtenDistance = distance
        return distance
    }

    static func distance(chosen: Double, headingUp: Bool, semiMajorM: Double?) -> Double {
        guard headingUp, let semiMajorM else { return chosen }
        let span = FollowSpan.span(minimum: chosen / MapFraming.distancePerSpan, semiMajorM: semiMajorM)
        return MapFraming.cameraDistance(spanMeters: span)
    }
}

/// What a double tap on the map needs from the recorder. Closures, so the
/// view stays plain and previews and tests can fake them.
struct ManualFixMarking {
    /// The recording's clock now; nil when not recording (the tap is ignored).
    var tapTime: @MainActor () -> MonotonicTimestamp?
    /// Stages the fix (`RecordingSession.stageManualFix`); nil when refused.
    var stage: @MainActor (_ latitude: Double, _ longitude: Double, _ tapT: MonotonicTimestamp, _ spanM: Double?) -> Int?
    /// Cancels a staged fix (Undo). False when it is already written or
    /// dropped: nothing was undone.
    var undo: @MainActor (_ id: Int) -> Bool
    /// How long Undo is offered; the recorder writes the row after this.
    var undoWindow: Duration = .seconds(3)

    static let unavailable = ManualFixMarking(tapTime: { nil }, stage: { _, _, _, _ in nil }, undo: { _ in false })
}

/// Undo and its toast, decided on the recorder's pending list only (R14.3-2).
enum ManualFixUndo {
    enum Result: Equatable {
        case removed
        /// The row is already written (or dropped): the flag stays, say so.
        case tooLate
    }

    /// Undo is offered only while the fix is still pending. A toast outliving
    /// its view task (tab switch) must not offer it again.
    static func offersUndo(id: Int, pendingIDs: Set<Int>) -> Bool {
        pendingIDs.contains(id)
    }

    /// Removes the marker only when the recorder really cancelled the write.
    @MainActor
    static func perform(id: Int, cancel: (Int) -> Bool, removeMarker: (Int) -> Void) -> Result {
        guard cancel(id) else { return .tooLate }
        removeMarker(id)
        return .removed
    }
}

/// A double tap on the map: the decision, taken on what was true at the tap.
/// The map zooms in on a double tap, so the coordinate, the span and the time
/// are captured before the zoom starts and handed in here.
enum ManualFixTap {
    enum Outcome: Equatable {
        /// Not recording, or the recorder refused the position: nothing happens.
        case ignored
        /// The span was over 300 m or unknown: nothing recorded, say why.
        case tooFarOut
        /// Staged with this id at `latitude`/`longitude`.
        case staged(id: Int, latitude: Double, longitude: Double)
    }

    @MainActor
    static func perform(
        latitude: Double, longitude: Double, visibleSpanM: Double?, marking: ManualFixMarking
    ) -> Outcome {
        guard let tapT = marking.tapTime() else { return .ignored }
        guard PinPrecision.isPreciseEnough(visibleSpanM: visibleSpanM) else { return .tooFarOut }
        guard let id = marking.stage(latitude, longitude, tapT, visibleSpanM) else { return .ignored }
        return .staged(id: id, latitude: latitude, longitude: longitude)
    }
}
