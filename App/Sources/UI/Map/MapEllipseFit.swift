import CoreGraphics
import Foundation

/// The 95 % ellipse as the camera fit needs it (semi-axes in metres, the
/// major axis' bearing clockwise from north). Plain values: no MapKit.
struct FitEllipse: Equatable, Sendable {
    var semiMajorM: Double
    var semiMinorM: Double
    var orientationDeg: Double

    /// `semiMinorM` nil: a circle of the major radius (orientation is then moot).
    init(semiMajorM: Double, semiMinorM: Double? = nil, orientationDeg: Double = 0) {
        self.semiMajorM = semiMajorM
        self.semiMinorM = semiMinorM ?? semiMajorM
        self.orientationDeg = orientationDeg
    }

    init(_ nav: NavDisplay) {
        self.init(semiMajorM: nav.semiMajorM, semiMinorM: nav.semiMinorM, orientationDeg: nav.orientationDeg)
    }
}

/// The follow camera's ellipse fit (C8, prompt 38): the camera distance at
/// which the whole 95 % ellipse is on screen. Pure.
///
/// The old fit looked at the vertical span only (`min(1000, 2.2 * a)`), so on
/// a portrait phone an ellipse lying across the track ran off both edges, and
/// a 2 km start ellipse was never shown whole. Here the ellipse is rotated
/// into screen axes (its bearing minus the camera heading), its half-extents
/// are fitted against the usable half-width and the usable room above and
/// below the car (the viewport minus the HUD, the rail and the offer card),
/// and the larger of the two scales wins.
enum EllipseFit {
    /// Breathing room around the ellipse.
    static let margin = 1.1
    /// The semi-major axis is fitted up to here (decided with the user,
    /// 2026-10-20); a larger or degenerate ellipse is fitted as this one.
    static let maxSemiMajorM = 4_000.0
    /// The camera stops here: no fit asks for more than this visible height
    /// (vertical span), metres (decided with the user, 2026-10-21). A larger
    /// start ellipse is cut off at the sides; the "Finding your position"
    /// line and the visible ellipse edges carry the uncertainty. Below it the
    /// whole ellipse fits. A circle of about 1.3 km semi-major reaches it on
    /// the reference phone.
    static let maxSpanM = 8_000.0
    /// Smallest room (points) the fit divides by.
    static let minRoom = 40.0

    /// The map view and what covers it, points.
    struct Viewport: Equatable, Sendable {
        var width: Double
        var height: Double
        /// Covered at the top (the HUD card).
        var top: Double
        /// Covered at the bottom (attribution band, safe area, the offer card).
        var bottom: Double
        var leading: Double
        /// Covered at the right (the rail).
        var trailing: Double

        /// A 6.1" phone before the map reports its size.
        static let reference = Viewport(
            width: 393, height: 852, top: MapLayout.hudReserved, bottom: MapLayout.bottomInset() + 34,
            leading: MapLayout.edgeInset, trailing: MapLayout.railReserved)

        var isUsable: Bool {
            [width, height, top, bottom, leading, trailing].allSatisfy(\.isFinite) && width > 0 && height > 0
        }

        /// The viewport for a map of `size` (points) under `safeBottom`, with
        /// the offer card (or the in-car card) up or not.
        static func make(size: CGSize, safeBottom: Double, offerShown: Bool, offerHeight: Double? = nil) -> Viewport {
            Viewport(
                width: size.width, height: size.height, top: MapLayout.hudReserved,
                bottom: MapLayout.bottomInset() + safeBottom + (offerShown ? MapLayout.offerReserved(cardHeight: offerHeight) : 0),
                leading: MapLayout.edgeInset, trailing: MapLayout.railReserved)
        }
    }

    /// Half-extents (metres) of the ellipse on the screen's axes: x across,
    /// y up the screen. `theta` is the major axis' angle from screen-up.
    static func halfExtents(
        semiMajorM a: Double, semiMinorM b: Double, orientationDeg: Double, cameraHeadingDeg: Double
    ) -> (ex: Double, ey: Double) {
        let theta = (orientationDeg - cameraHeadingDeg) * .pi / 180
        let s = sin(theta), c = cos(theta)
        return ((a * a * s * s + b * b * c * c).squareRoot(), (a * a * c * c + b * b * s * s).squareRoot())
    }

    /// The visible height in metres that shows the whole ellipse, at most
    /// `maxSpanM` (applied after the width, height, car placement and offer
    /// card terms), or 0 when there is nothing to fit (non-finite input,
    /// unusable viewport). Callers take the wider of this and the speed or
    /// driver zoom, so the ceiling never zooms in past those.
    /// - Parameters:
    ///   - carFromTop: where the car sits, fraction of the map height from
    ///     the top (`CarPlacement.carFromTop(headingUp:offerShown:)`; 0.5
    ///     north-up).
    static func requiredSpanM(
        ellipse: FitEllipse, cameraHeadingDeg: Double, carFromTop: Double, viewport: Viewport
    ) -> Double {
        guard ellipse.semiMajorM.isFinite, ellipse.orientationDeg.isFinite, cameraHeadingDeg.isFinite,
              carFromTop.isFinite, viewport.isUsable else { return 0 }
        let a = min(max(ellipse.semiMajorM, 0), maxSemiMajorM)
        let rawMinor = ellipse.semiMinorM.isFinite ? ellipse.semiMinorM : a
        let b = min(max(rawMinor, 0), a)
        let (ex, ey) = halfExtents(
            semiMajorM: a, semiMinorM: b, orientationDeg: ellipse.orientationDeg, cameraHeadingDeg: cameraHeadingDeg)
        let halfWidth = max(min(viewport.width / 2 - viewport.leading, viewport.width / 2 - viewport.trailing), minRoom)
        let up = max(viewport.height * carFromTop - viewport.top, minRoom)
        let down = max(viewport.height * (1 - carFromTop) - viewport.bottom, minRoom)
        let halfHeight = min(up, down)
        let metresPerPoint = max(ex / halfWidth, ey / halfHeight) * margin
        return min(metresPerPoint * viewport.height, maxSpanM)
    }

    /// The camera distance for that visible height.
    static func distance(forSpanM span: Double) -> Double {
        span / CarPlacement.spanPerDistance
    }
}

/// How long the fit holds the widest recent view before the camera comes
/// back, so a flickering ellipse does not pump the zoom. Widening is at
/// once; narrowing waits for `dwellS` of a continuously smaller ellipse and
/// then glides (the same shape as `AutoZoom`: out at once, in after a dwell).
struct EllipseFitHold: Equatable, Sendable {
    static let dwellS = 6.0
    static let timeConstantS = 3.0
    /// A required span within this fraction of the held one is no change.
    static let deadband = 0.05

    /// The visible height (m) the camera is asked to keep; 0: no fit.
    private(set) var spanM = 0.0
    private var latched = 0.0
    private var lowerFor = 0.0

    init() {}

    /// Advances by `dt` with the span the ellipse needs now (0: none). No
    /// ellipse at all drops the hold at once (nothing to keep in view).
    mutating func step(requiredSpanM raw: Double, dt: Double) {
        guard raw.isFinite, raw > 0 else { self = EllipseFitHold(); return }
        guard dt.isFinite, dt > 0 else { return }
        if raw > latched {
            latched = raw
            lowerFor = 0
        } else if raw < latched * (1 - Self.deadband) {
            lowerFor += dt
            if lowerFor >= Self.dwellS {
                latched = raw
                lowerFor = 0
            }
        } else {
            lowerFor = 0
        }
        if spanM < latched {
            spanM = latched
        } else if spanM > latched {
            let alpha = 1 - exp(-dt / Self.timeConstantS)
            spanM = exp(log(spanM) + (log(latched) - log(spanM)) * alpha)
        }
    }
}
