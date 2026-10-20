import Foundation
import Testing

@testable import DriveLogger

/// C8 (prompt 38): the follow camera shows the whole 95 % ellipse, in
/// heading-up and north-up, against the screen's width and height.
@Suite("Ellipse fit (C8)")
struct EllipseFitTests {
    private let viewport = EllipseFit.Viewport.reference

    /// Half-width of the usable area, points (what the fit divides ex by).
    private var halfWidth: Double {
        min(viewport.width / 2 - viewport.leading, viewport.width / 2 - viewport.trailing)
    }

    /// Metres per point at a visible height.
    private func metresPerPoint(_ spanM: Double) -> Double { spanM / viewport.height }

    @Test("Half-extents: the ellipse rotated by orientation minus camera heading")
    func halfExtents() {
        let across = EllipseFit.halfExtents(semiMajorM: 90, semiMinorM: 20, orientationDeg: 90, cameraHeadingDeg: 0)
        #expect(abs(across.ex - 90) < 1e-9 && abs(across.ey - 20) < 1e-9)
        let along = EllipseFit.halfExtents(semiMajorM: 90, semiMinorM: 20, orientationDeg: 0, cameraHeadingDeg: 0)
        #expect(abs(along.ex - 20) < 1e-9 && abs(along.ey - 90) < 1e-9)
        // The camera turned with the ellipse: it is along the screen's up axis again.
        let turned = EllipseFit.halfExtents(semiMajorM: 90, semiMinorM: 20, orientationDeg: 130, cameraHeadingDeg: 130)
        #expect(abs(turned.ex - 20) < 1e-9 && abs(turned.ey - 90) < 1e-9)
        let diagonal = EllipseFit.halfExtents(semiMajorM: 90, semiMinorM: 20, orientationDeg: 45, cameraHeadingDeg: 0)
        let expected = ((90.0 * 90 + 20 * 20) / 2).squareRoot()
        #expect(abs(diagonal.ex - expected) < 1e-9 && abs(diagonal.ey - expected) < 1e-9)
    }

    @Test("Portrait, across the track (a 90, b 20 at 30 km/h): the width decides, and the ellipse fits")
    func portraitAcrossTrack() {
        let ellipse = FitEllipse(semiMajorM: 90, semiMinorM: 20, orientationDeg: 90)
        let span = EllipseFit.requiredSpanM(
            ellipse: ellipse, cameraHeadingDeg: 0, carFromTop: CarPlacement.carFromTop, viewport: viewport)
        // The 95 % half-width, with margin, lands exactly on the usable half-width.
        #expect(abs(90 * EllipseFit.margin / metresPerPoint(span) - halfWidth) < 1e-6)
        // The speed-based distance at 30 km/h (333 m) is far too close for it; the old
        // fit (2.2 x 90 = 198 m tall) ignored the width and let it run off both edges.
        let auto = AutoZoom.target(kmh: 30)
        let widened = FollowZoom.distance(chosen: auto, headingUp: true, ellipse: ellipse)
        #expect(widened > auto * 2)
        let visibleWidth = widened * CarPlacement.spanPerDistance * viewport.width / viewport.height
        #expect(visibleWidth >= 2 * 90, "the whole width of the ellipse is on screen")
        // The vertical room is not the limit here.
        let (_, ey) = EllipseFit.halfExtents(semiMajorM: 90, semiMinorM: 20, orientationDeg: 90, cameraHeadingDeg: 0)
        #expect(ey * EllipseFit.margin / metresPerPoint(span) < viewport.height * (1 - CarPlacement.carFromTop) - viewport.bottom)
    }

    @Test("Along the track: the room below the car in the lower third decides")
    func alongTrack() {
        let ellipse = FitEllipse(semiMajorM: 90, semiMinorM: 20, orientationDeg: 0)
        let span = EllipseFit.requiredSpanM(
            ellipse: ellipse, cameraHeadingDeg: 0, carFromTop: CarPlacement.carFromTop, viewport: viewport)
        let down = viewport.height * (1 - CarPlacement.carFromTop) - viewport.bottom
        #expect(abs(90 * EllipseFit.margin / metresPerPoint(span) - down) < 1e-6)
        // Far less than the same ellipse across the track.
        let across = EllipseFit.requiredSpanM(
            ellipse: FitEllipse(semiMajorM: 90, semiMinorM: 20, orientationDeg: 90), cameraHeadingDeg: 0,
            carFromTop: CarPlacement.carFromTop, viewport: viewport)
        #expect(span < across)
    }

    @Test("Heading-up: the camera heading turns the ellipse into the screen's axes")
    func headingTurnsEllipse() {
        let ellipse = FitEllipse(semiMajorM: 90, semiMinorM: 20, orientationDeg: 70)
        let lined = EllipseFit.requiredSpanM(
            ellipse: ellipse, cameraHeadingDeg: 70, carFromTop: CarPlacement.carFromTop, viewport: viewport)
        let crossed = EllipseFit.requiredSpanM(
            ellipse: ellipse, cameraHeadingDeg: 160, carFromTop: CarPlacement.carFromTop, viewport: viewport)
        #expect(lined < crossed)
        // North-up ignores the heading argument (the camera never turns).
        let north = FollowZoom.distance(chosen: 100, headingUp: false, ellipse: ellipse, cameraHeading: 70)
        let north2 = FollowZoom.distance(chosen: 100, headingUp: false, ellipse: ellipse, cameraHeading: 160)
        #expect(north == north2)
    }

    @Test("A 2 km start ellipse is shown whole: its width on the usable width")
    func twoKilometres() {
        let ellipse = FitEllipse(semiMajorM: 2_000, semiMinorM: 1_500, orientationDeg: 30)
        let span = EllipseFit.requiredSpanM(
            ellipse: ellipse, cameraHeadingDeg: 0, carFromTop: CarPlacement.carFromTop, viewport: viewport)
        let (ex, ey) = EllipseFit.halfExtents(semiMajorM: 2_000, semiMinorM: 1_500, orientationDeg: 30, cameraHeadingDeg: 0)
        let mpp = metresPerPoint(span)
        #expect(ex * EllipseFit.margin / mpp <= halfWidth + 1e-6)
        #expect(ey * EllipseFit.margin / mpp <= viewport.height * (1 - CarPlacement.carFromTop) - viewport.bottom + 1e-6)
        #expect(span > 2 * 2_000, "far wider than the old 1000 m cap")
        #expect(span < EllipseFit.maxSpanM)
    }

    @Test("Cap: a larger ellipse is fitted as 4 km; degenerate values are safe")
    func cap() {
        let capped = EllipseFit.requiredSpanM(
            ellipse: FitEllipse(semiMajorM: 4_000, semiMinorM: 4_000), cameraHeadingDeg: 0, carFromTop: 0.5, viewport: viewport)
        let huge = EllipseFit.requiredSpanM(
            ellipse: FitEllipse(semiMajorM: 90_000, semiMinorM: 90_000), cameraHeadingDeg: 0, carFromTop: 0.5, viewport: viewport)
        #expect(capped > 0 && huge == capped)
        // A minor axis longer than the major one, or negative, cannot widen the fit.
        let odd = FitEllipse(semiMajorM: 100, semiMinorM: 9_000, orientationDeg: 0)
        let circle = FitEllipse(semiMajorM: 100, semiMinorM: 100, orientationDeg: 0)
        #expect(EllipseFit.requiredSpanM(ellipse: odd, cameraHeadingDeg: 0, carFromTop: 0.5, viewport: viewport)
                == EllipseFit.requiredSpanM(ellipse: circle, cameraHeadingDeg: 0, carFromTop: 0.5, viewport: viewport))
        for bad in [Double.nan, .infinity, -.infinity] {
            #expect(EllipseFit.requiredSpanM(
                ellipse: FitEllipse(semiMajorM: bad), cameraHeadingDeg: 0, carFromTop: 0.5, viewport: viewport) == 0)
            #expect(EllipseFit.requiredSpanM(
                ellipse: FitEllipse(semiMajorM: 100), cameraHeadingDeg: bad, carFromTop: 0.5, viewport: viewport) == 0)
        }
        #expect(EllipseFit.requiredSpanM(
            ellipse: FitEllipse(semiMajorM: -5), cameraHeadingDeg: 0, carFromTop: 0.5, viewport: viewport) == 0)
        // A broken viewport does not blow the zoom up beyond the hard ceiling, or divide by zero.
        let tiny = EllipseFit.Viewport(width: 100, height: 100, top: 90, bottom: 90, leading: 60, trailing: 60)
        let guarded = EllipseFit.requiredSpanM(
            ellipse: FitEllipse(semiMajorM: 4_000), cameraHeadingDeg: 0, carFromTop: 0.5, viewport: tiny)
        #expect(guarded > 0 && guarded <= EllipseFit.maxSpanM)
        let none = EllipseFit.Viewport(width: 0, height: 0, top: 0, bottom: 0, leading: 0, trailing: 0)
        #expect(EllipseFit.requiredSpanM(
            ellipse: FitEllipse(semiMajorM: 100), cameraHeadingDeg: 0, carFromTop: 0.5, viewport: none) == 0)
    }

    @Test("North-up: the car is centred, the room is the smaller of above and below")
    func northUp() {
        let along = FitEllipse(semiMajorM: 300, semiMinorM: 10, orientationDeg: 0)
        let span = EllipseFit.requiredSpanM(ellipse: along, cameraHeadingDeg: 0, carFromTop: 0.5, viewport: viewport)
        let up = viewport.height * 0.5 - viewport.top
        let down = viewport.height * 0.5 - viewport.bottom
        #expect(abs(300 * EllipseFit.margin / metresPerPoint(span) - min(up, down)) < 1e-6)
        // And the follow zoom widens north-up too (it did not before).
        let widened = FollowZoom.distance(chosen: 100, headingUp: false, ellipse: along)
        #expect(widened > 100)
        #expect(abs(widened - EllipseFit.distance(forSpanM: span)) < 1e-9)
    }

    @Test("The offer card (car centred, card over the lower part) asks for a wider view than a free screen")
    func offerCard() {
        let free = EllipseFit.Viewport.make(size: CGSize(width: 393, height: 852), safeBottom: 34, offerShown: false)
        let card = EllipseFit.Viewport.make(size: CGSize(width: 393, height: 852), safeBottom: 34, offerShown: true)
        #expect(card.bottom == free.bottom + MapLayout.offerCardReserved)
        let along = FitEllipse(semiMajorM: 120, semiMinorM: 10, orientationDeg: 0)
        let freeSpan = EllipseFit.requiredSpanM(ellipse: along, cameraHeadingDeg: 0, carFromTop: 0.5, viewport: free)
        let cardSpan = EllipseFit.requiredSpanM(ellipse: along, cameraHeadingDeg: 0, carFromTop: 0.5, viewport: card)
        #expect(cardSpan > freeSpan)
        #expect(!EllipseFit.Viewport.make(size: .zero, safeBottom: 0, offerShown: false).isUsable)
    }

    @Test("Never zooms in past the driver's choice or the speed-based distance")
    func neverZoomsIn() {
        let small = FitEllipse(semiMajorM: 5)
        #expect(FollowZoom.distance(chosen: 900, headingUp: true, ellipse: small) == 900)
        #expect(FollowZoom.distance(chosen: 900, headingUp: false, ellipse: small) == 900)
        #expect(FollowZoom.distance(chosen: 900, headingUp: true, ellipse: nil) == 900)
        #expect(FollowZoom.distance(chosen: 900, fitSpanM: .nan) == 900)
        #expect(FollowZoom.distance(chosen: 900, fitSpanM: 0) == 900)
    }
}

@Suite("Ellipse fit hold: widen at once, come back by itself")
struct EllipseFitHoldTests {
    private func settled(at kmh: Double) -> FollowZoom {
        var zoom = FollowZoom()
        zoom.frame(distance: nil)
        zoom.cameraReported(distance: 1000)
        for _ in 0..<400 { zoom.step(speedKmh: kmh, dt: 0.1) }
        return zoom
    }

    @Test("A km-wide ellipse widens the camera at once, and when it shrinks the distance returns to the speed-based zoom")
    func shrinkBack() {
        var zoom = settled(at: 30)
        let normal = zoom.auto.distance
        let big = FitEllipse(semiMajorM: 2_000, semiMinorM: 1_500, orientationDeg: 20)
        zoom.step(speedKmh: 30, dt: 0.1, ellipse: big, headingUp: true, cameraHeading: 0)
        let wide = zoom.autoFollowDistance(headingUp: true, ellipse: big)
        #expect(wide > normal * 20)

        // Converged: a=15 m. For the dwell the camera stays wide; then it glides back.
        let small = FitEllipse(semiMajorM: 15, semiMinorM: 6, orientationDeg: 20)
        for _ in 0..<40 { zoom.step(speedKmh: 30, dt: 0.1, ellipse: small, headingUp: true, cameraHeading: 0) }
        #expect(zoom.autoFollowDistance(headingUp: true, ellipse: small) > wide * 0.99, "held during the 6 s dwell")
        for _ in 0..<300 { zoom.step(speedKmh: 30, dt: 0.1, ellipse: small, headingUp: true, cameraHeading: 0) }
        let back = zoom.autoFollowDistance(headingUp: true, ellipse: small)
        #expect(abs(back - zoom.auto.distance) < 1e-9, "the speed-based zoom again")
        #expect(abs(back - normal) / normal < 0.01)
        #expect(!zoom.driverOverride && zoom.chosen == 1000, "the widening was never the driver's choice")
    }

    @Test("A flickering ellipse does not pump the camera: the distance never narrows during the dwell")
    func noPumping() {
        var zoom = settled(at: 30)
        let big = FitEllipse(semiMajorM: 600, semiMinorM: 300, orientationDeg: 20)
        let a = FitEllipse(semiMajorM: 540, semiMinorM: 270, orientationDeg: 20)    // 10 % smaller
        var last = 0.0
        for i in 0..<50 {                                                             // 5 s
            let e = i % 2 == 0 ? big : a
            zoom.step(speedKmh: 30, dt: 0.1, ellipse: e, headingUp: true, cameraHeading: 0)
            let d = zoom.autoFollowDistance(headingUp: true, ellipse: e)
            #expect(d >= last - 1e-9, "step \(i): \(d) < \(last)")
            last = d
        }
    }

    @Test("No estimate drops the hold at once")
    func noEstimate() {
        var zoom = settled(at: 30)
        let big = FitEllipse(semiMajorM: 800)
        zoom.step(speedKmh: 30, dt: 0.1, ellipse: big, headingUp: true, cameraHeading: 0)
        #expect(zoom.fitHold.spanM > 0)
        zoom.step(speedKmh: 30, dt: 0.1, ellipse: nil)
        #expect(zoom.fitHold.spanM == 0)
        #expect(abs(zoom.autoFollowDistance(headingUp: true, ellipse: nil) - zoom.auto.distance) < 1e-9)
    }

    @Test("Hold: out at once, in after the dwell, then a glide; a growing ellipse resets the dwell")
    func holdShape() {
        var hold = EllipseFitHold()
        hold.step(requiredSpanM: 1_000, dt: 0.1)
        #expect(hold.spanM == 1_000)
        hold.step(requiredSpanM: 2_000, dt: 0.1)
        #expect(hold.spanM == 2_000)
        for _ in 0..<59 { hold.step(requiredSpanM: 500, dt: 0.1) }                    // 5.9 s
        #expect(hold.spanM == 2_000)
        hold.step(requiredSpanM: 500, dt: 0.2)                                         // past 6 s
        #expect(hold.spanM <= 2_000)
        for _ in 0..<400 { hold.step(requiredSpanM: 500, dt: 0.1) }
        #expect(abs(hold.spanM - 500) < 1)
        // Inside the dead band: no change, no dwell.
        var steady = EllipseFitHold()
        steady.step(requiredSpanM: 1_000, dt: 0.1)
        for _ in 0..<200 { steady.step(requiredSpanM: 980, dt: 0.1) }
        #expect(steady.spanM == 1_000)
        // Non-finite or zero: dropped.
        steady.step(requiredSpanM: .nan, dt: 0.1)
        #expect(steady.spanM == 0)
    }
}
