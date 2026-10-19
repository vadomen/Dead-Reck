import Foundation
import Testing

@testable import DriveLogger

@Suite("Map HUD (UX-32)")
struct MapHUDTests {
    private func speed(_ source: MapSpeedSource) -> MapSpeedReadout {
        MapSpeedReadout(source: source, kmh: source == .none ? nil : 54, quality: .good)
    }

    private func state(
        _ source: MapSpeedSource, gps: HUDGPS = .ok, obd: HUDOBD = .connected,
        thermal: ProcessInfo.ThermalState = .nominal
    ) -> MapHUDState {
        MapHUDState.make(speed: speed(source), gps: gps, obd: obd, thermal: thermal)
    }

    @Test("GPS and OBD labels, and a failed state is slashed AND flagged failed")
    func indicators() {
        for gps in [HUDGPS.ok, .none, .off] {
            for obd in [HUDOBD.connected, .lost] {
                let s = state(.obd, gps: gps, obd: obd)
                #expect(s.gps.label == ["GPS", "No GPS", "GPS off"][[HUDGPS.ok, .none, .off].firstIndex(of: gps)!])
                #expect(s.gps.failed == (gps != .ok))
                #expect(s.gps.slashed == s.gps.failed)
                #expect(s.obd.label == (obd == .connected ? "OBD" : "OBD lost"))
                #expect(s.obd.failed == (obd == .lost))
                #expect(s.obd.slashed == s.obd.failed)
            }
        }
    }

    @Test("The indicator of the current speed source is emphasised; none emphasises neither")
    func sourceEmphasis() {
        let obd = state(.obd)
        #expect(obd.obd.emphasised && !obd.gps.emphasised)
        let gps = state(.gps, obd: .lost)
        #expect(gps.gps.emphasised && !gps.obd.emphasised)
        let none = state(.none, gps: .none, obd: .lost)
        #expect(!none.gps.emphasised && !none.obd.emphasised)
        // GPS off while the source is OBD: OBD stays emphasised.
        #expect(state(.obd, gps: .off).obd.emphasised)
    }

    @Test("OBD is connected while the link is initialised (ready or polling), lost otherwise, before any connection too")
    func obdFromLink() {
        #expect(HUDOBD.from(link: .polling(protocolNumber: "A6", voltage: 12.4)) == .connected)
        #expect(HUDOBD.from(link: .ready) == .connected)
        let notConnected: [OBDLinkState] = [
            .unavailable(reason: "Bluetooth is off"), .idle, .scanning, .connecting, .discoveringServices,
            .initialising, .reconnecting(attempt: 1), .failed(reason: "x"),
        ]
        for state in notConnected {
            #expect(HUDOBD.from(link: state) == .lost, "\(state)")
        }
        // No link at all (previews): lost.
        #expect(HUDOBD.from(link: nil) == .lost)
    }

    @Test("The OBD indicator follows the link, not the speed: a silent engine on a live link reads OBD")
    func obdIndependentOfSpeed() {
        // Link polling, but no fresh OBD speed (engine off): the source is GPS
        // (UX-5 rule, unchanged) and the indicator still says OBD.
        let s = MapHUDState.make(
            speed: speed(.gps), gps: .ok, obd: HUDOBD.from(link: .polling(protocolNumber: "6", voltage: nil)),
            thermal: .nominal)
        #expect(s.obd.label == "OBD" && !s.obd.failed)
        #expect(s.gps.emphasised && !s.obd.emphasised, "emphasis stays with the speed source")
        // Link lost while the last OBD speed is still the source: lost, and emphasised.
        let lost = MapHUDState.make(speed: speed(.obd), gps: .ok, obd: HUDOBD.from(link: .reconnecting(attempt: 1)), thermal: .nominal)
        #expect(lost.obd.label == "OBD lost" && lost.obd.failed && lost.obd.emphasised)
    }

    @Test("HUD fakes: obdLost fakes the link as lost, otherwise connected")
    func fakeOBD() {
        #expect(HUDFakes.parse("ok").obd == .connected)
        #expect(HUDFakes.parse("obdLost").obd == .lost)
    }

    @Test("GPS state: fresh fix ok, stale none, the reserved switch wins")
    func gpsState() {
        #expect(MapHUDState.gpsState(stale: false) == .ok)
        #expect(MapHUDState.gpsState(stale: true) == .none)
        #expect(MapHUDState.gpsState(stale: false, switchedOff: true) == .off)
        #expect(MapHUDState.gpsState(stale: true, switchedOff: true) == .off)
    }

    @Test("Thermal row only when not nominal")
    func thermal() {
        #expect(state(.obd, thermal: .nominal).thermal == nil)
        #expect(state(.obd, thermal: .fair).thermal == "Thermal fair")
        #expect(state(.obd, thermal: .serious).thermal == "Thermal serious")
        #expect(state(.obd, thermal: .critical).thermal == "Thermal critical")
    }

    @Test("Speed text and the VoiceOver summary")
    func summary() {
        #expect(state(.obd).speedText == "54")
        #expect(state(.none, gps: .none, obd: .lost).speedText == "—")
        #expect(state(.obd, gps: .none).accessibilitySummary == "54 km/h, No GPS, OBD")
        #expect(state(.gps, obd: .lost, thermal: .fair).accessibilitySummary == "54 km/h, GPS, OBD lost, Thermal fair")
    }

    // MARK: Bottom zone

    @Test("Bottom zone stacks offer, toast, banner, roads warning, hint, strip: top to bottom")
    func stackOrder() {
        let all = MapBottomZone.items(
            offer: true, toast: true, status: true, roadsWarning: true, resumeHint: true, debugSetting: true)
        #expect(all == [.offerCard, .toast, .statusLine, .roadsWarning, .resumeHint, .debugStrip])
        #expect(Set(all).count == all.count)
        #expect(Set(all) == Set(MapBottomItem.allCases))
    }

    @Test("The debug strip is gated by the setting alone; off takes no space")
    func debugGate() {
        let off = MapBottomZone.items(
            offer: false, toast: false, status: false, roadsWarning: false, resumeHint: false, debugSetting: false)
        #expect(off.isEmpty)
        let on = MapBottomZone.items(
            offer: false, toast: false, status: false, roadsWarning: false, resumeHint: false, debugSetting: true)
        #expect(on == [.debugStrip])
        let busy = MapBottomZone.items(
            offer: true, toast: true, status: true, roadsWarning: true, resumeHint: true, debugSetting: false)
        #expect(!busy.contains(.debugStrip))
    }

    @Test("The strip is two lines: timing/ESS/heading, then scale/dropped/on road")
    func stripLines() {
        let stats = NavStatsDisplay(
            msPerStep: 6.7, maxMsPerStep: 50, effectiveSampleSize: 1830, headingStdDeg: 55.9,
            speedScale: 1.016, droppedInputs: 0, onRoadShare: 0.94)
        let lines = DebugStrip.lines(stats: stats)
        #expect(lines.count == 2)
        #expect(lines[0] == "6.70 ms/step (max 50.0) · ESS 1830 · hdg σ 55.9°")
        #expect(lines[1].hasPrefix("scale 1.016 · dropped 0 · on road"))
        #expect(DebugStrip.lines(stats: nil) == ["nav: idle"])
        // The one-line form the stats already had is unchanged.
        #expect(stats.line.hasPrefix("6.70 ms/step (max 50.0) · ESS 1830 · hdg σ 55.9° · scale 1.016 · dropped 0"))
    }

    // MARK: Layout

    @Test("The destination slot lifts the rail and the bottom zone; 0 in v1.0")
    func bottomSlot() {
        #expect(MapLayout.bottomSlotHeight == 0)
        #expect(MapLayout.bottomInset() == MapLayout.attributionBand + 8)
        #expect(MapLayout.bottomInset(slot: 56) == MapLayout.bottomInset() + 56)
        // The bottom zone stops left of the rail.
        #expect(MapLayout.railReserved == MapLayout.edgeInset * 2 + MapLayout.controlSize)
        #expect(MapLayout.controlSize >= 56 && MapLayout.minTapTarget >= 44)
    }

    // MARK: Contrast (UX-13)

    @Test("Every HUD text and glyph colour is at least 4.5:1 on its face, light and dark, over black and white")
    func contrast() {
        for scheme in [HUDScheme.light, .dark] {
            let pairs: [(String, HUDRGB, HUDRGB)] = [
                ("text on card", scheme.text, scheme.card),
                ("muted on card", scheme.muted, scheme.card),
                ("warn on card", scheme.warn, scheme.card),
                ("accent glyph on card", scheme.accentOnCard, scheme.card),
                ("record on card", scheme.record, scheme.card),
                ("text on button", scheme.text, scheme.button),
                ("glyph on active button", scheme.onAccent, scheme.accent),
            ]
            for (name, fg, face) in pairs {
                let ratio = scheme.worstContrast(fg, on: face)
                #expect(ratio >= 4.5, "\(name): \(ratio)")
            }
        }
    }

    @Test("Contrast maths: black on white is 21:1, equal colours 1:1")
    func contrastMaths() {
        let black = HUDRGB(r: 0, g: 0, b: 0), white = HUDRGB(r: 255, g: 255, b: 255)
        #expect(abs(HUDRGB.contrast(black, white) - 21) < 0.001)
        #expect(abs(HUDRGB.contrast(white, white) - 1) < 0.001)
        let half = HUDRGB(r: 0, g: 0, b: 0, a: 0.5).over(white)
        #expect(abs(half.r - 127.5) < 0.001)
    }

    // MARK: Fakes

    @Test("-uiFakeHUD parsing")
    func fakes() {
        #expect(HUDFakes.parse(nil) == HUDFakes())
        #expect(HUDFakes.parse("") == HUDFakes())
        #expect(!HUDFakes.parse("nonsense").isActive)
        let f = HUDFakes.parse("gpsLost, recording,debug,bogus")
        #expect(f.isActive && f.gpsLost && f.recording && f.debugStrip && !f.obdLost && !f.thermal && !f.banner)
        #expect(HUDFakes.parse("banner").banner)
        #expect(HUDFakes.parse("obdLost").speed.source == .gps)
        #expect(HUDFakes.parse("ok").speed.source == .obd)
    }
}

@Suite("Car placement (UX-32)")
struct CarPlacementTests {
    /// Metres visible behind the car (below it) for a camera distance, heading-up.
    private func visibleBehindCar(cameraDistance d: Double) -> Double {
        (1 - CarPlacement.carFromTop) * d * CarPlacement.spanPerDistance
    }

    @Test("R68.1-1: heading-up, the ellipse's rear half fits below the car; north-up and small ellipses unchanged")
    func ellipseFitBehindCar() {
        for semi in [100.0, 300, 450] {
            let d = FollowZoom.distance(chosen: 100, headingUp: true, semiMajorM: semi)
            let behind = visibleBehindCar(cameraDistance: d)
            #expect(behind >= semi, "semi \(semi): \(behind) m behind the car")
            #expect(behind <= semi * 1.15, "not inflated beyond the 2.2 margin")
        }
        // North-up: the old fit, car centred.
        #expect(abs(FollowZoom.distance(chosen: 100, headingUp: false, semiMajorM: 300) - 100) < 1e-9)
        #expect(abs(FollowSpan.span(minimum: 500, semiMajorM: 300) - 660) < 1e-9)
        // A small ellipse leaves the driver's zoom alone.
        #expect(FollowZoom.distance(chosen: 500, headingUp: true, semiMajorM: 50) == 500)
        #expect(FollowZoom.distance(chosen: 500, headingUp: true, semiMajorM: nil) == 500)
    }

    @Test("Heading-up puts the camera centre ahead so the car lands at two thirds; north-up does not")
    func ahead() {
        let d = 1000.0
        let ahead = CarPlacement.aheadMetres(cameraDistance: d, headingUp: true)
        #expect(ahead > 0)
        let fraction = CarPlacement.carScreenFraction(aheadMetres: ahead, cameraDistance: d)
        #expect(abs(fraction - 2.0 / 3.0) < 1e-9)
        #expect(CarPlacement.aheadMetres(cameraDistance: d, headingUp: false) == 0)
        #expect(CarPlacement.aheadMetres(cameraDistance: 0, headingUp: true) == 0)
        #expect(CarPlacement.aheadMetres(cameraDistance: .nan, headingUp: true) == 0)
        // Scales with the zoom.
        #expect(abs(CarPlacement.aheadMetres(cameraDistance: 2 * d, headingUp: true) - 2 * ahead) < 1e-9)
    }

    @Test("The centre moves along the camera heading")
    func centre() {
        let north = CarPlacement.cameraCenter(latitude: 10, longitude: 20, headingDegrees: 0, aheadMetres: 111.32)
        #expect(abs(north.latitude - 10.001) < 1e-9 && north.longitude == 20)
        let east = CarPlacement.cameraCenter(latitude: 0, longitude: 20, headingDegrees: 90, aheadMetres: 111.32)
        #expect(abs(east.longitude - 20.001) < 1e-9 && abs(east.latitude) < 1e-12)
        let south = CarPlacement.cameraCenter(latitude: 10, longitude: 20, headingDegrees: 180, aheadMetres: 111.32)
        #expect(south.latitude < 10)
        let same = CarPlacement.cameraCenter(latitude: 10, longitude: 20, headingDegrees: 77, aheadMetres: 0)
        #expect(same.latitude == 10 && same.longitude == 20)
    }
}
