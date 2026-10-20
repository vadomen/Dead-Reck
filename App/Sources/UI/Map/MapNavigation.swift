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
    /// Share of particles on a road (N3.2); nil without roads.
    var onRoadShare: Double?

    init(_ stats: NavigationSnapshot.Stats) {
        msPerStep = stats.msPerStep
        maxMsPerStep = stats.maxMsPerStep
        effectiveSampleSize = stats.effectiveSampleSize
        headingStdDeg = stats.headingStdDeg
        speedScale = stats.speedScale
        droppedInputs = stats.droppedInputs
        onRoadShare = stats.onRoadShare
    }

    init(
        msPerStep: Double, maxMsPerStep: Double, effectiveSampleSize: Double?,
        headingStdDeg: Double?, speedScale: Double?, droppedInputs: Int, onRoadShare: Double? = nil
    ) {
        self.msPerStep = msPerStep
        self.maxMsPerStep = maxMsPerStep
        self.effectiveSampleSize = effectiveSampleSize
        self.headingStdDeg = headingStdDeg
        self.speedScale = speedScale
        self.droppedInputs = droppedInputs
        self.onRoadShare = onRoadShare
    }

    /// One compact line.
    var line: String { parts.joined(separator: " · ") }

    /// The line's pieces (the debug strip splits them over two lines).
    var parts: [String] {
        var parts = [String(format: "%.2f ms/step (max %.1f)", msPerStep, maxMsPerStep)]
        parts.append("ESS " + (effectiveSampleSize.map { String(Int($0.rounded())) } ?? "–"))
        parts.append("hdg σ " + (headingStdDeg.map { String(format: "%.1f°", $0) } ?? "–"))
        parts.append("scale " + (speedScale.map { String(format: "%.3f", $0) } ?? "–"))
        parts.append("dropped \(droppedInputs)")
        return parts
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
/// is the distance of our latest camera write. The written distance is widened
/// to fit the ellipse (`EllipseFit`, heading-up and north-up), always from the
/// driver's or the automatic distance and never narrower than it, so a
/// widening is never read back as the driver's choice and the distance
/// returns to that base when the ellipse shrinks (after `EllipseFitHold`'s dwell).
struct FollowZoom: Equatable, Sendable {
    /// A report within this fraction of `writtenDistance` is our own write.
    static let ownWriteTolerance = 0.03
    static let initialDistance = 1500.0

    private(set) var chosen = Self.initialDistance
    private(set) var writtenDistance = 0.0
    /// UX-6: true after a driver zoom, until the next re-centre. While true,
    /// `autoFollowDistance` uses `chosen`; otherwise the speed-based `auto`.
    private(set) var driverOverride = false
    /// Where the car sits (`CarPlacement.carFromTop(headingUp:offerShown:)`)
    /// when heading-up: the ellipse fit keeps the ellipse inside the room
    /// above and below it. North-up the car is centred.
    var carFromTop = CarPlacement.carFromTop
    /// The map's size and what covers it (the view sets it); the ellipse fit
    /// divides by the room that is left.
    var viewport = EllipseFit.Viewport.reference
    /// The widest recent fit, held for a dwell before the camera comes back.
    private(set) var fitHold = EllipseFitHold()
    /// Speed-dependent distance, advanced by `step`.
    private(set) var auto = AutoZoom()
    /// The last few distances we wrote: with a moving automatic distance a
    /// camera report can lag behind the newest write.
    private var recentWrites: [Double] = []
    private static let recentWriteCount = 8
    /// A region was framed: the next report is that frame, not the driver.
    private var regionFramePending = false

    init() {}

    /// The framing rule moved the camera. `distance` is the camera distance
    /// it wrote, nil when it wrote a region (the next report then is the
    /// framed distance and becomes `chosen`).
    mutating func frame(distance: Double?) {
        driverOverride = false
        regionFramePending = distance == nil
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
        let isRegionFrame = regionFramePending
        let isOwn = writtenDistance > 0 && ([writtenDistance] + recentWrites).contains {
            abs(distance - $0) / $0 <= Self.ownWriteTolerance
        }
        if !isOwn {
            chosen = distance
            // The frame we asked for is not a driver zoom.
            if !isRegionFrame { driverOverride = true }
        }
        regionFramePending = false
    }

    /// True when the distance we would write now (the automatic one, widened
    /// by the ellipse like `autoFollowDistance`) has drifted
    /// enough from our last write to be worth a camera write; false while
    /// the driver's zoom holds. Compares like with like: `writtenDistance`
    /// is the widened distance, so a constant ellipse is not a drift (R26.1-1).
    func autoWantsWrite(headingUp: Bool, ellipse: FitEllipse?, cameraHeading: Double = 0) -> Bool {
        guard !driverOverride, writtenDistance > 0 else { return false }
        let wanted = widened(
            base: auto.distance, headingUp: headingUp, ellipse: ellipse, cameraHeading: cameraHeading)
        return abs(log(wanted / writtenDistance)) > Self.autoWriteThreshold
    }
    private static let autoWriteThreshold = 0.02

    /// Re-centre (Follow tap, auto-resume): back to the automatic distance.
    mutating func recentre() { driverOverride = false }

    /// Advances the automatic distance and the fit hold; call each tick with
    /// the time since the last one. `ellipse` nil (no estimate) drops the hold.
    mutating func step(
        speedKmh: Double?, dt: Double, ellipse: FitEllipse? = nil, headingUp: Bool = false, cameraHeading: Double = 0
    ) {
        auto.step(speedKmh: speedKmh, dt: dt)
        fitHold.step(
            requiredSpanM: requiredSpanM(ellipse: ellipse, headingUp: headingUp, cameraHeading: cameraHeading), dt: dt)
    }

    /// The distance for a follow write with speed-dependent zoom: the
    /// driver's zoom while it holds, else `auto`; widened to fit the ellipse.
    /// Records it as written.
    mutating func autoFollowDistance(headingUp: Bool, ellipse: FitEllipse?, cameraHeading: Double = 0) -> Double {
        let base = driverOverride ? chosen : auto.distance
        let distance = widened(base: base, headingUp: headingUp, ellipse: ellipse, cameraHeading: cameraHeading)
        writtenDistance = distance
        recentWrites.append(distance)
        if recentWrites.count > Self.recentWriteCount { recentWrites.removeFirst() }
        return distance
    }

    /// The visible height (m) the ellipse needs now; 0 without one.
    func requiredSpanM(ellipse: FitEllipse?, headingUp: Bool, cameraHeading: Double) -> Double {
        guard let ellipse else { return 0 }
        return EllipseFit.requiredSpanM(
            ellipse: ellipse, cameraHeadingDeg: headingUp ? cameraHeading : 0,
            carFromTop: headingUp ? carFromTop : 0.5, viewport: viewport)
    }

    private func widened(base: Double, headingUp: Bool, ellipse: FitEllipse?, cameraHeading: Double) -> Double {
        guard ellipse != nil else { return base }
        let span = max(requiredSpanM(ellipse: ellipse, headingUp: headingUp, cameraHeading: cameraHeading), fitHold.spanM)
        return Self.distance(chosen: base, fitSpanM: span)
    }

    /// `chosen` widened to show a view `fitSpanM` tall (EllipseFit); never
    /// narrower than `chosen`: the fit does not zoom in past the driver's
    /// zoom or the speed-based one. Non-finite or 0: `chosen`.
    static func distance(chosen: Double, fitSpanM: Double) -> Double {
        guard fitSpanM.isFinite, fitSpanM > 0 else { return chosen }
        return max(chosen, EllipseFit.distance(forSpanM: fitSpanM))
    }

    /// The fit for one ellipse with no hold: pure, for tests and previews.
    static func distance(
        chosen: Double, headingUp: Bool, ellipse: FitEllipse?, cameraHeading: Double = 0,
        carFromTop: Double = CarPlacement.carFromTop, viewport: EllipseFit.Viewport = .reference
    ) -> Double {
        guard let ellipse else { return chosen }
        let span = EllipseFit.requiredSpanM(
            ellipse: ellipse, cameraHeadingDeg: headingUp ? cameraHeading : 0,
            carFromTop: headingUp ? carFromTop : 0.5, viewport: viewport)
        return distance(chosen: chosen, fitSpanM: span)
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
