import CoreGraphics
import DriveLoggerCore
import Foundation
import MapKit
import SwiftUI
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

/// P52B-QA-1 and R92.1-1: a route card in the bottom column lifts the car and
/// the ellipse fit above it, and never pushes the rail up under the HUD. iPhone
/// SE (3rd generation) is the smallest screen: 375 x 667 pt, no bottom safe area.
@Suite("Route card layout")
struct RouteCardLayoutTests {
    static let se = CGSize(width: 375, height: 667)
    /// The tallest card measured: uncertain position and an offline failure, uk (R92.1-1), ~304 pt plus the 8 pt gap.
    static let tallestBar = 304.0 + MapLayout.aboveCreditGap
    static let topSafe = 20.0
    static var cap: Double { MapBottomLayout.maxRouteBarHeight(containerHeight: Double(se.height), topSafe: topSafe) }

    /// The card's top edge, points from the map's top (the bar ends at the credit band).
    private func cardTop(barHeight: Double) -> Double {
        Double(Self.se.height) - MapLayout.attributionBand - barHeight
    }

    @Test("The route bar adds only its height beyond the idle bar's slot, plus the gap; the offer card keeps its own number")
    func obstruction() {
        #expect(MapLayout.bottomObstruction(offerShown: false) == 0)
        #expect(MapLayout.bottomObstruction(offerShown: false, routeBarHeight: MapLayout.bottomSlotHeight) == 0, "the idle bar is inside the base inset")
        #expect(MapLayout.bottomObstruction(offerShown: false, routeBarHeight: 110) == 110 - MapLayout.bottomSlotHeight + MapLayout.offerCardGap)
        #expect(MapLayout.bottomObstruction(offerShown: true) == MapLayout.offerCardReserved)
        #expect(MapLayout.bottomObstruction(offerShown: true, offerHeight: 200) == 200 + MapLayout.offerCardGap)
        #expect(MapLayout.bottomObstruction(offerShown: true, offerHeight: 200, routeBarHeight: 110)
            == MapLayout.bottomObstruction(offerShown: true, offerHeight: 200) + 110 - MapLayout.bottomSlotHeight, "both up: they stack")
        #expect(MapLayout.bottomObstruction(offerShown: false, routeBarHeight: .nan) == 0)
    }

    @Test("Tallest card on the SE: the car's point and the ellipse fit box sit above the card's top edge, heading-up and north-up")
    func carAndEllipseAboveCard() {
        for barHeight in [Self.tallestBar, Self.cap, 110, MapLayout.bottomSlotHeight] {
            let viewport = EllipseFit.Viewport.make(size: Self.se, safeBottom: 0, offerShown: false, routeBarHeight: barHeight)
            let top = cardTop(barHeight: barHeight)
            for headingUp in [true, false] {
                let from = CarPlacement.carFromTop(headingUp: headingUp, offerShown: false, viewport: viewport)
                let carY = Double(Self.se.height) * from
                #expect(carY + CarPlacement.carRadius <= top, "car mark above the card: headingUp \(headingUp), bar \(barHeight)")
                #expect(carY - CarPlacement.carRadius >= viewport.top, "and below the HUD")
                // A large ellipse across the track: its fitted box, in points, around the car.
                let ellipse = FitEllipse(semiMajorM: 600, semiMinorM: 300, orientationDeg: 0)
                let span = EllipseFit.requiredSpanM(ellipse: ellipse, cameraHeadingDeg: 0, carFromTop: from, viewport: viewport)
                let pointsPerMetre = Double(Self.se.height) / span
                let (_, ey) = EllipseFit.halfExtents(semiMajorM: 600, semiMinorM: 300, orientationDeg: 0, cameraHeadingDeg: 0)
                #expect(carY + ey * pointsPerMetre <= top + 0.5, "ellipse bottom above the card: headingUp \(headingUp), bar \(barHeight)")
                #expect(carY - ey * pointsPerMetre >= viewport.top - 0.5, "ellipse top below the HUD")
            }
        }
    }

    @Test("Without a card the placement is the old one; the camera centre puts the car where the placement says")
    func placementWithoutCard() {
        let free = EllipseFit.Viewport.make(size: Self.se, safeBottom: 0, offerShown: false)
        #expect(CarPlacement.carFromTop(headingUp: true, offerShown: false, viewport: free) == CarPlacement.carFromTop)
        #expect(CarPlacement.carFromTop(headingUp: false, offerShown: false, viewport: free) == 0.5)
        let card = EllipseFit.Viewport.make(size: Self.se, safeBottom: 0, offerShown: false, routeBarHeight: Self.tallestBar)
        let from = CarPlacement.carFromTop(headingUp: false, offerShown: false, viewport: card)
        #expect(from < 0.5, "north-up lifts the car too")
        let ahead = CarPlacement.aheadMetres(cameraDistance: 900, headingUp: true, carFromTop: from)
        #expect(abs(CarPlacement.carScreenFraction(aheadMetres: ahead, cameraDistance: 900) - from) < 1e-9)
        var zoom = FollowZoom()
        zoom.carFromTop = 0.4
        zoom.northUpCarFromTop = 0.3
        #expect(zoom.placement(headingUp: true) == 0.4 && zoom.placement(headingUp: false) == 0.3)
    }

    @Test("The offer card keeps its placement (centred) when it clears; a taller one lifts the car above it")
    func offerPlacement() {
        let viewport = EllipseFit.Viewport.make(size: Self.se, safeBottom: 0, offerShown: true, offerHeight: 120)
        #expect(CarPlacement.carFromTop(headingUp: true, offerShown: true, viewport: viewport) == 0.5)
        let tall = EllipseFit.Viewport.make(size: Self.se, safeBottom: 0, offerShown: true, offerHeight: 260)
        let from = CarPlacement.carFromTop(headingUp: true, offerShown: true, viewport: tall)
        #expect(Double(Self.se.height) * from + CarPlacement.carRadius <= Double(Self.se.height) - tall.bottom)
    }

    @Test("R92.1-1: the capped bar keeps the rail under the HUD reserve; uncapped it would not")
    func railUnderCap() {
        let rail = CGSize(width: 56, height: MapLayout.railHeight)
        func railTop(barHeight: Double) -> Double {
            Double(MapBottomLayout.frames(container: Self.se, items: [], railSize: rail, creditWidth: 190, slot: barHeight).rail.minY)
        }
        let reserve = MapLayout.compassReserved(topSafe: Self.topSafe)
        #expect(railTop(barHeight: Self.tallestBar) < reserve, "uncapped: over the compass, the reported bug")
        #expect(railTop(barHeight: Self.cap) >= reserve - 0.001)
        #expect(Self.cap > MapLayout.bottomSlotHeight)
        // Taller screens leave more room; a tiny container still keeps the idle slot.
        #expect(MapBottomLayout.maxRouteBarHeight(containerHeight: 852, topSafe: Self.topSafe) > Self.cap)
        #expect(MapBottomLayout.maxRouteBarHeight(containerHeight: 852, topSafe: 59) < MapBottomLayout.maxRouteBarHeight(containerHeight: 852, topSafe: 20), "a notch pushes the compass down")
        #expect(MapBottomLayout.maxRouteBarHeight(containerHeight: 100, topSafe: Self.topSafe) == MapLayout.bottomSlotHeight)
    }

    @Test("R93.1-1: at default type the uncertain place card (240 pt bar) and the three-route card (226 pt bar) fit under the cap on the SE, and the rail stays below the compass")
    func defaultCardsFitWithoutScrolling() {
        // Measured from the 52b screenshots at 2x, default type, uk: surface 232 + 8 gap; alternatives 218 + 8.
        let reserve = MapLayout.compassReserved(topSafe: Self.topSafe)
        for barHeight in [240.0, 226.0] {
            #expect(barHeight <= Self.cap, "bar \(barHeight) pt, cap \(Self.cap)")
            let rail = CGSize(width: 56, height: MapLayout.railHeight)
            let frames = MapBottomLayout.frames(container: Self.se, items: [], railSize: rail, creditWidth: 190, slot: barHeight)
            #expect(Double(frames.rail.minY) >= reserve, "rail top \(frames.rail.minY) under the compass reserve \(reserve)")
        }
        // The compass reserve is the status bar plus the compass, not the HUD card on the left.
        #expect(reserve < MapLayout.hudReserved)
    }

    @Test("R93.1-2, P52C-QA-1: the origin note, the failure message and Retry are pinned with the actions (in that order), only the header scrolls")
    func failureIsPinned() {
        #expect(PlaceCardRow.pinned == [.originNote, .failure, .actions], "the note directly above the buttons it explains")
        #expect(PlaceCardRow.scrolling == [.header])
        #expect(Set(PlaceCardRow.pinned + PlaceCardRow.scrolling) == Set(PlaceCardRow.allCases), "every row is somewhere, once")
        #expect(PlaceCardRow.pinned.count + PlaceCardRow.scrolling.count == PlaceCardRow.allCases.count)
    }

    @Test("R92.1-1: whatever the text size, the card's surface stays within the cap; the actions stay outside the scroll")
    func scrollRoomHoldsCap() {
        let chrome = 20.0, spacing = 10.0, pinned = 108.0
        // Pinned: the actions (108), with the failure row (about 56) and at large type (about 230).
        // Info heights from default type to AX2 with the uk uncertain + offline texts.
        for pinned in [pinned, 164, 230] {
            for info in [60.0, 150, 250, 400, 700] {
                let room = RouteBarLayout.scrollRoom(maxHeight: Self.cap, pinnedHeight: pinned, spacing: spacing, chrome: chrome)
                let surface = chrome + min(info, room ?? .infinity) + spacing + pinned + MapLayout.aboveCreditGap
                #expect(surface <= Self.cap + 0.001, "pinned \(pinned), info \(info) pt")
            }
        }
        #expect(RouteBarLayout.scrollRoom(maxHeight: nil, pinnedHeight: pinned, spacing: spacing, chrome: chrome) == nil)
        #expect(RouteBarLayout.scrollRoom(maxHeight: 100, pinnedHeight: 200, spacing: spacing, chrome: chrome) == 0, "never negative, no floor that would push the bar past the cap")
    }
}

/// Review round 1 fix-up: the cards hug their content (as in 52b) and stretch to
/// the cap only when the content passes it. Rendered in a window of finite height,
/// like the bottom column: a ScrollView or ViewThatFits would take all of it.
@MainActor
@Suite("Route card hugs content")
struct RouteCardHugTests {
    final class Box { var height = 0.0 }

    private struct Probe: View {
        var flow: RouteFlowModel
        var cap: Double?
        var size: CGSize
        var box: Box
        var body: some View {
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                RouteBottomBar(flow: flow, maxHeight: cap)
                    .onGeometryChange(for: Double.self, of: { Double($0.size.height) }) { box.height = $0 }
            }
            .frame(width: size.width, height: size.height)
        }
    }

    private func spin(_ seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    /// The bar's height for the stub `state` (a place card without a failure for "place") in a screen of `size`.
    private func barHeight(state: String, cap: Double?, size: CGSize) async throws -> Double {
        let flow = try #require(RouteDebugStubs.flow(argument: state))
        for _ in 0..<100 where flow.phase != .placeCard { await spin(0.1) }
        #expect(flow.phase == .placeCard)
        let box = Box()
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        let host = UIHostingController(rootView: Probe(flow: flow, cap: cap, size: size, box: box))
        window.rootViewController = host
        window.makeKeyAndVisible()
        for _ in 0..<5 {
            await spin(0.15)
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
        }
        window.isHidden = true
        return box.height
    }

    @Test("A plain place card is as high with the cap as without it, and well under it, on the SE and a Plus")
    func hugsContent() async throws {
        for size in [CGSize(width: 375, height: 667), CGSize(width: 414, height: 896)] {
            let cap = MapBottomLayout.maxRouteBarHeight(containerHeight: Double(size.height), topSafe: 20)
            let free = try await barHeight(state: "place", cap: nil, size: size)
            let capped = try await barHeight(state: "place", cap: cap, size: size)
            #expect(free > 100, "measured at all: \(free)")
            #expect(abs(capped - free) <= 1, "capped \(capped) vs free \(free) at \(size.height)")
            #expect(capped < cap - 40, "well under the cap \(cap): \(capped)")
        }
    }

    @Test("A card taller than the cap is exactly the cap (the info scrolls)")
    func stretchesOnlyPastCap() async throws {
        let size = CGSize(width: 375, height: 667)
        let free = try await barHeight(state: "place", cap: nil, size: size)
        let cap = free - 40
        let capped = try await barHeight(state: "place", cap: cap, size: size)
        #expect(abs(capped - cap) <= 1, "capped \(capped), cap \(cap)")
    }

    @Test("P52C-QA-1: on the tallest card (uncertain + offline) on the SE, at every type size, the bar stays under the cap and the uncertain line and Close are fully visible")
    func uncertainLineStaysVisible() async throws {
        let size = CGSize(width: 375, height: 667)
        let cap = MapBottomLayout.maxRouteBarHeight(containerHeight: Double(size.height), topSafe: 20)
        for type in [UIContentSizeCategory.large, .accessibilityMedium, .accessibilityExtraLarge, .accessibilityExtraExtraExtraLarge] {
            let flow = try #require(RouteDebugStubs.flow(argument: "uncertainOffline"))
            for _ in 0..<100 where flow.failure == nil || flow.phase != .placeCard { await spin(0.1) }
            #expect(flow.failure != nil && flow.phase == .placeCard, "the tallest card is up")
            let box = Box()
            let found = Weak()
            let window = UIWindow(frame: CGRect(origin: .zero, size: size))
            let host = UIHostingController(
                rootView: Probe(flow: flow, cap: cap, size: size, box: box)
                    .environment(\.originNoteProbe) { found.views.append(($0, $1)) })
            host.traitOverrides.preferredContentSizeCategory = type
            window.rootViewController = host
            window.makeKeyAndVisible()
            for _ in 0..<5 {
                await spin(0.15)
                host.view.setNeedsLayout()
                host.view.layoutIfNeeded()
            }
            // The info part is also laid out once, invisibly, to measure it: only the shown copy counts.
            func shown(_ name: String) -> UIView? {
                found.views.filter { entry in
                    var n: UIView? = entry.1
                    while let x = n { if x.alpha == 0 || x.isHidden { return false }; n = x.superview }
                    return entry.0 == name && entry.1.window != nil
                }.last?.1
            }
            // The bar (its gap above the credit band included) fits under the cap.
            #expect(box.height <= cap + 0.5, "\(type): bar \(box.height) over the cap \(cap)")
            let card = CGRect(x: 0, y: size.height - box.height, width: size.width, height: box.height)
            var frames: [String: CGRect] = [:]
            for name in ["note", "close"] {
                let view = try #require(shown(name), "\(name) is on the card (\(type))")
                let frame = view.convert(view.bounds, to: host.view)
                frames[name] = frame
                #expect(frame.height > 10, "\(type) \(name) measured: \(frame)")
                #expect(card.insetBy(dx: -0.5, dy: -0.5).contains(frame), "\(type): \(name) \(frame) inside card \(card)")
                // No scroll view above it clips any of it.
                var ancestor = view.superview
                while let v = ancestor {
                    if let scroll = v as? UIScrollView {
                        let inScroll = scroll.convert(view.bounds, from: view)
                        #expect(scroll.bounds.insetBy(dx: -0.5, dy: -0.5).contains(inScroll), "\(type): \(name) \(inScroll) clipped by the scroll room \(scroll.bounds)")
                    }
                    ancestor = v.superview
                }
            }
            if let note = frames["note"], let close = frames["close"] {
                #expect(!note.intersects(close.insetBy(dx: 1, dy: 1)), "\(type): Close \(close) over the uncertain line \(note)")
            }
            window.isHidden = true
        }
    }

    private final class Weak { var views: [(String, UIView)] = [] }
}
