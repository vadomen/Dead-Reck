import CoreGraphics
import DriveLoggerCore
import Foundation
import MapKit
import Testing
import UIKit

@testable import DriveLogger

/// Layout E with the destination bar (prompt 52): the road ahead, the bar and
/// the rail, the GPS indicator's tap target, the camera rule, the gestures and
/// the formatting of the route texts.
@Suite("Route layout")
struct RouteLayoutTests {
    /// iPhone SE (3rd generation), points; `scripts`-free measurement: a screenshot of
    /// the synthetic basemap with `-uiFakeHUD ok,navEllipse` (prompt 52, 2026-11-15).
    static let screen = CGSize(width: 375, height: 667)
    /// The HUD card's bottom edge, measured: speed card alone, and with the recording row.
    static let hudBottom = 104.5
    static let hudBottomWithRecording = 140.5

    private var carY: Double { Double(Self.screen.height) * CarPlacement.carFromTop }

    @Test("Road ahead on the iPhone SE, heading-up, stays at least 320 pt with and without the recording row")
    func roadAhead() {
        let withoutRow = carY - Self.hudBottom
        let withRow = carY - Self.hudBottomWithRecording
        #expect(withoutRow >= 320, "measured 340 pt before and after the destination bar")
        #expect(withRow >= 300, "measured 304 pt before and after")
        #expect(abs(withoutRow - 339) <= 2 && abs(withRow - 305) <= 2, "UX-32's numbers: 339 and 305")
    }

    @Test("The destination bar sits at the very bottom above the credit band; the car stays in the lower third of the area above it")
    func carAboveBar() {
        let creditTop = Double(Self.screen.height) - MapLayout.attributionBand
        let barBottom = creditTop - MapLayout.aboveCreditGap
        let barTop = barBottom - RouteBarLayout.fieldHeight
        #expect(MapLayout.bottomSlotHeight == RouteBarLayout.fieldHeight + MapLayout.aboveCreditGap)
        #expect(Double(Self.screen.height) - MapLayout.bottomInset() == barTop - MapLayout.aboveCreditGap, "the rail and the stack start above the bar")
        #expect(carY < barTop)
        #expect(carY >= barTop * 2 / 3, "inside the lower third of the area above the bar")
        // The taller guidance bar (about 110 pt) still leaves the car clear.
        #expect(carY < barBottom - 110 - 20)
    }

    @Test("The rail moves up above the bar and keeps the credit band free")
    func railAboveBar() {
        let frames = MapBottomLayout.frames(
            container: Self.screen, items: [], railSize: CGSize(width: 56, height: MapLayout.railHeight), creditWidth: 190)
        let barTop = Double(Self.screen.height) - MapLayout.attributionBand - MapLayout.aboveCreditGap - RouteBarLayout.fieldHeight
        #expect(Double(frames.rail.maxY) <= barTop - MapLayout.aboveCreditGap + 0.001)
        #expect(frames.credit.map { $0.minY >= frames.rail.maxY } == true)
    }

    @Test("The bar and its buttons are real tap targets")
    func tapTargets() {
        #expect(RouteBarLayout.fieldHeight >= MapLayout.minTapTarget)
        #expect(RouteBarLayout.minTapTarget >= 44)
    }

    @Test("The GPS indicator's tap area is at least 44 pt high (R88.1-4)")
    func gpsTapTarget() {
        let line = UIFont.systemFont(ofSize: 12, weight: .heavy).lineHeight
        #expect(line + 2 * MapLayout.gpsTapPadding >= 44)
    }

    @Test("The camera frames the route when the alternatives appear and returns to follow when they go")
    func cameraRule() {
        typealias Phase = RouteFlowModel.Phase
        #expect(RouteCameraRule.action(from: .requesting, to: .alternatives) == .frameRoute)
        #expect(RouteCameraRule.action(from: .alternatives, to: .guiding) == .resumeFollow)
        #expect(RouteCameraRule.action(from: .alternatives, to: .idle) == .resumeFollow)
        #expect(RouteCameraRule.action(from: .alternatives, to: .guiding) == .resumeFollow)
        for (old, new) in [(Phase.idle, Phase.search), (.search, .placeCard), (.guiding, .arrived), (.alternatives, .requesting), (.guiding, .guiding)] {
            #expect(RouteCameraRule.action(from: old, to: new) == .none)
        }
    }

    @Test("Framing: the whole route is inside the visible top part, the panel part is left free")
    func framing() throws {
        let route = RouteFixtures.route(lengthM: 4_000)
        let points = route.polyline.map { ($0.latitude, $0.longitude) }
        let region = try #require(RouteFraming.region(points: points, coveredFraction: 0.4))
        let top = region.center.latitude + region.span.latitudeDelta / 2
        let visibleBottom = top - region.span.latitudeDelta * 0.6
        for p in points {
            #expect(p.0 <= top && p.0 >= visibleBottom - 1e-9)
            #expect(abs(p.1 - region.center.longitude) <= region.span.longitudeDelta / 2)
        }
        // With the HUD above: the route also stays below the top part.
        let both = try #require(RouteFraming.region(points: points, coveredFraction: 0.4, coveredTop: 0.18, usableWidth: 0.8))
        let bothTop = both.center.latitude + both.span.latitudeDelta / 2
        let hudBottom = bothTop - both.span.latitudeDelta * 0.18
        let panelTop = bothTop - both.span.latitudeDelta * 0.6
        for p in points { #expect(p.0 <= hudBottom + 1e-9 && p.0 >= panelTop - 1e-9) }
        #expect(RouteFraming.region(points: [], coveredFraction: 0.4) == nil)
        let tiny = try #require(RouteFraming.region(points: [(0, 0), (0, 0)], coveredFraction: 0.4))
        #expect(tiny.span.latitudeDelta >= RouteFraming.minSpan)
    }

    @Test("Long press: 0.5 s, cancelled by a drag of 10 pt")
    func gesture() {
        #expect(RouteGesture.longPressSeconds == 0.5)
        #expect(RouteGesture.cancelDistance == 10)
    }

    @Test("After the press, a pan drops no pin; a finger that stayed put does")
    func panAfterPress() {
        #expect(RouteGesture.dropsPin(translation: .zero))
        #expect(RouteGesture.dropsPin(translation: CGSize(width: 6, height: 6)))
        #expect(!RouteGesture.dropsPin(translation: CGSize(width: 10, height: 0)))
        #expect(!RouteGesture.dropsPin(translation: CGSize(width: 0, height: -200)))
    }

    @Test("The route line is distinct from the roads line and the estimate, and differs per scheme")
    func colours() {
        for dark in [false, true] {
            let line = RouteColors.line(dark: dark, chosen: true)
            let roads = MatchedRoadLine.rgb(dark: dark)
            #expect(abs(line.r - roads.r) + abs(line.g - roads.g) + abs(line.b - roads.b) > 120)
            #expect(line.b > line.g + 60, "violet, not the estimate's blue or the roads' teal")
            #expect(RouteColors.line(dark: dark, chosen: false) != line)
        }
        #expect(RouteColors.line(dark: false, chosen: true) != RouteColors.line(dark: true, chosen: true))
        #expect(RouteColors.chosenWidth > RouteColors.otherWidth)
    }
}

@Suite("Route texts")
struct RouteFormatTests {
    private let en = Locale(identifier: "en_US")

    @Test("Distances round to what is glanceable")
    func distances() {
        #expect(RouteFormat.distance(0, locale: en).hasPrefix("0"))
        #expect(RouteFormat.distance(347, locale: en).hasPrefix("350"))
        #expect(RouteFormat.distance(83, locale: en).hasPrefix("80"))
        #expect(RouteFormat.distance(12_449, locale: en).hasPrefix("12"))
        #expect(RouteFormat.distance(2_449, locale: en).hasPrefix("2.4"))
        #expect(RouteFormat.distance(.nan) == "—")
    }

    @Test("Durations are whole minutes, at least one")
    func durations() {
        #expect(RouteFormat.duration(10).hasPrefix("1"))
        #expect(RouteFormat.duration(14 * 60).hasPrefix("14"))
        #expect(RouteFormat.duration(65 * 60).hasPrefix("1"))
        #expect(RouteFormat.duration(.infinity) == "—")
    }

    @Test("Every maneuver has a glyph and a name; the provider's text wins when there is one")
    func maneuvers() {
        let all: [RouteManeuver] = [.depart, .straight, .slightLeft, .left, .sharpLeft, .slightRight, .right, .sharpRight, .uTurn,
                                    .roundaboutExit(exit: 2), .merge, .exitRamp, .arrive, .unknown("x")]
        for maneuver in all {
            #expect(!RouteFormat.symbol(maneuver).isEmpty && !RouteFormat.name(maneuver).isEmpty)
        }
        #expect(RouteFormat.symbol(.left) != RouteFormat.symbol(.right))
        let withText = RouteStep(instruction: "Turn left onto X", distanceM: 1, polylineRange: 0...1, maneuver: .left)
        let without = RouteStep(instruction: "", distanceM: 1, polylineRange: 0...1, maneuver: .left)
        #expect(RouteFormat.instruction(withText) == "Turn left onto X")
        #expect(RouteFormat.instruction(without) == RouteFormat.name(.left))
    }

    @Test("A failure's message is its own: busy is not `nothing found`")
    func messages() {
        let all: [RouteFlowModel.Failure] = [.offline, .nothingFound, .busy, .failed]
        #expect(Set(all.map(RouteFormat.message)).count == 4)
    }
}

@Suite("Route inputs from the map")
struct RouteInputsTests {
    private func fix(accuracy: Double) -> LocationSample {
        LocationSample(
            latitude: 0.001, longitude: 0.002, altitude: 0, horizontalAccuracy: accuracy, verticalAccuracy: 5,
            speed: 5, speedAccuracy: 1, course: 0, courseAccuracy: 5)
    }

    @Test("The estimate counts only with a run and a shown estimate (Navigate without OBD shows none)")
    func estimateNeedsRunAndDisplay() {
        let nav = RouteFixtures.nav()
        #expect(RouteInputs.build(runActive: true, showsEstimate: true, estimate: nav, fix: nil, fixAgeS: nil, gpsOff: false, speedKmh: nil).origin.estimate == nav)
        #expect(RouteInputs.build(runActive: false, showsEstimate: true, estimate: nav, fix: nil, fixAgeS: nil, gpsOff: false, speedKmh: nil).origin.estimate == nil)
        #expect(RouteInputs.build(runActive: true, showsEstimate: false, estimate: nav, fix: nil, fixAgeS: nil, gpsOff: false, speedKmh: nil).origin.estimate == nil)
    }

    @Test("The fix carries its accuracy and age; the speed is metres per second")
    func fixAndSpeed() {
        let inputs = RouteInputs.build(
            runActive: false, showsEstimate: true, estimate: nil, fix: fix(accuracy: 7), fixAgeS: 2, gpsOff: true, speedKmh: 36)
        #expect(inputs.origin.fix?.horizontalAccuracy == 7 && inputs.origin.fix?.ageS == 2)
        #expect(inputs.origin.gpsOff)
        #expect(inputs.speedMS == 10)
        let none = RouteInputs.build(runActive: false, showsEstimate: true, estimate: nil, fix: fix(accuracy: 7), fixAgeS: nil, gpsOff: false, speedKmh: nil)
        #expect(none.origin.fix == nil && none.speedMS == nil, "a fix with no known age is not offered")
    }
}
