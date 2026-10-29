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
            for obd in [HUDOBD.connected, .lost, .none] {
                let s = state(.obd, gps: gps, obd: obd)
                #expect(s.gps.label == ["GPS", "No GPS", "GPS off"][[HUDGPS.ok, .none, .off].firstIndex(of: gps)!])
                #expect(s.gps.failed == (gps != .ok))
                #expect(s.gps.slashed == s.gps.failed)
                #expect(s.obd.label == ["OBD", "OBD lost", "No OBD"][[HUDOBD.connected, .lost, .none].firstIndex(of: obd)!])
                #expect(s.obd.failed == (obd == .lost))
                #expect(s.obd.slashed == (obd != .connected), "No OBD is slashed too")
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

    @Test("OBD is connected while the link is initialised (ready or polling), lost once a link was up, No OBD before")
    func obdFromLink() {
        #expect(HUDOBD.from(link: .polling(protocolNumber: "A6", voltage: 12.4), everConnected: false) == .connected)
        #expect(HUDOBD.from(link: .ready, everConnected: true) == .connected)
        let notConnected: [OBDLinkState] = [
            .unavailable(reason: "Bluetooth is off"), .idle, .scanning, .connecting, .discoveringServices,
            .initialising, .reconnecting(attempt: 1), .failed(reason: "x"),
        ]
        for state in notConnected {
            #expect(HUDOBD.from(link: state, everConnected: true) == .lost, "\(state)")
            #expect(HUDOBD.from(link: state, everConnected: false) == .none, "\(state)")
        }
        // No link at all (previews).
        #expect(HUDOBD.from(link: nil, everConnected: false) == .none)
        #expect(HUDOBD.from(link: nil, everConnected: true) == .lost)
    }

    @Test("No OBD is slashed but not failed (muted, no warning colour); lost is both")
    func noOBDIsNotAWarning() {
        let none = state(.gps, obd: .none).obd
        #expect(none.label == "No OBD" && none.slashed && !none.failed)
        let lost = state(.gps, obd: .lost).obd
        #expect(lost.slashed && lost.failed)
    }

    @Test("The view model remembers that a link was up, and keeps it after the drop")
    @MainActor func everConnected() {
        let model = MapViewModel()
        model.noteLink(nil)
        model.noteLink(.scanning)
        model.noteLink(.failed(reason: "x"))
        #expect(!model.obdEverConnected)
        model.noteLink(.polling(protocolNumber: "6", voltage: nil))
        #expect(model.obdEverConnected)
        model.noteLink(.reconnecting(attempt: 1))
        #expect(model.obdEverConnected)
        #expect(HUDOBD.from(link: .reconnecting(attempt: 1), everConnected: model.obdEverConnected) == .lost)
    }

    @Test("Forget clears the memory: connected A, Forget -> No OBD, not OBD lost (R70.1-1)")
    @MainActor func forgetClearsEverConnected() {
        let a = UUID()
        let model = MapViewModel()
        model.noteLink(.polling(protocolNumber: "6", voltage: nil), adapter: a)
        model.noteLink(.idle, adapter: nil)
        #expect(HUDOBD.from(link: .idle, everConnected: model.obdEverConnected) == .none)
    }

    @Test("Forget A then pair B: B connecting reads No OBD; once B was up and dropped, OBD lost")
    @MainActor func switchingAdapters() {
        let a = UUID(), b = UUID()
        let model = MapViewModel()
        model.noteLink(.polling(protocolNumber: "6", voltage: nil), adapter: a)
        model.noteLink(.idle, adapter: nil)
        model.noteLink(.connecting, adapter: b)
        #expect(HUDOBD.from(link: .connecting, everConnected: model.obdEverConnected) == .none)
        model.noteLink(.polling(protocolNumber: "6", voltage: nil), adapter: b)
        model.noteLink(.reconnecting(attempt: 1), adapter: b)
        #expect(HUDOBD.from(link: .reconnecting(attempt: 1), everConnected: model.obdEverConnected) == .lost)
    }

    @Test("A dropping while still paired reads OBD lost, across reconnect states")
    @MainActor func samePairedDropIsLost() {
        let a = UUID()
        let model = MapViewModel()
        model.noteLink(.polling(protocolNumber: "6", voltage: nil), adapter: a)
        for state: OBDLinkState in [.reconnecting(attempt: 1), .scanning, .failed(reason: "x")] {
            model.noteLink(state, adapter: a)
            #expect(HUDOBD.from(link: state, everConnected: model.obdEverConnected) == .lost)
        }
    }

    @Test("The OBD indicator follows the link, not the speed: a silent engine on a live link reads OBD")
    func obdIndependentOfSpeed() {
        // Link polling, but no fresh OBD speed (engine off): the source is GPS
        // (UX-5 rule, unchanged) and the indicator still says OBD.
        let s = MapHUDState.make(
            speed: speed(.gps), gps: .ok, obd: HUDOBD.from(link: .polling(protocolNumber: "6", voltage: nil), everConnected: true),
            thermal: .nominal)
        #expect(s.obd.label == "OBD" && !s.obd.failed)
        #expect(s.gps.emphasised && !s.obd.emphasised, "emphasis stays with the speed source")
        // Link lost while the last OBD speed is still the source: lost, and emphasised.
        let lost = MapHUDState.make(speed: speed(.obd), gps: .ok, obd: HUDOBD.from(link: .reconnecting(attempt: 1), everConnected: true), thermal: .nominal)
        #expect(lost.obd.label == "OBD lost" && lost.obd.failed && lost.obd.emphasised)
    }

    @Test("HUD fakes: obdLost fakes the link as lost, otherwise connected")
    func fakeOBD() {
        #expect(HUDFakes.parse("ok").obd == .connected)
        #expect(HUDFakes.parse("obdLost").obd == .lost)
        #expect(HUDFakes.parse("obdNone").obd == .none)
        #expect(HUDFakes.parse("obdNone").speed.source == .gps)
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
            offer: true, toast: true, status: true, positionStatus: true, restoreStatus: true, roadsWarning: true,
            resumeHint: true, debugSetting: true, permission: true)
        #expect(all == [.offerCard, .toast, .statusLine, .permissionLine, .restoreStatus, .positionStatus, .roadsWarning, .resumeHint, .debugStrip])
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
        let stop = HUDFakes.parse("calibrating,stopped")
        #expect(stop.calibrating && stop.stopped && stop.obd == .connected && stop.speed.kmh == 0)
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

    @Test("R68.1-1: heading-up, an along-track ellipse's rear half fits in the room below the car")
    func ellipseFitBehindCar() {
        let viewport = EllipseFit.Viewport.reference
        for semi in [100.0, 300, 450] {
            let ellipse = FitEllipse(semiMajorM: semi, semiMinorM: 5, orientationDeg: 0)
            let d = FollowZoom.distance(chosen: 100, headingUp: true, ellipse: ellipse, viewport: viewport)
            let visibleHeight = d * CarPlacement.spanPerDistance
            let roomBelowPoints = viewport.height * (1 - CarPlacement.carFromTop) - viewport.bottom
            let behind = roomBelowPoints / viewport.height * visibleHeight
            #expect(behind >= semi, "semi \(semi): \(behind) m behind the car")
            #expect(behind <= semi * EllipseFit.margin * 1.001, "not inflated beyond the margin")
        }
        // A small ellipse leaves the driver's zoom alone.
        #expect(FollowZoom.distance(chosen: 500, headingUp: true, ellipse: FitEllipse(semiMajorM: 20)) == 500)
        #expect(FollowZoom.distance(chosen: 500, headingUp: true, ellipse: nil) == 500)
    }

    @Test("R68.1-3: the car is centred while the offer card is up (heading-up), unchanged otherwise")
    func carFromTopWithOffer() {
        #expect(CarPlacement.carFromTop(headingUp: true, offerShown: false) == CarPlacement.carFromTop)
        #expect(CarPlacement.carFromTop(headingUp: true, offerShown: true) == 0.5)
        #expect(CarPlacement.carFromTop(headingUp: false, offerShown: false) == 0.5)
        #expect(CarPlacement.carFromTop(headingUp: false, offerShown: true) == 0.5)
        // Centred: no camera offset, and the ellipse fit is the north-up one (no 1.5 factor).
        #expect(CarPlacement.aheadMetres(cameraDistance: 800, headingUp: true, carFromTop: 0.5) == 0)
        let ahead = FitEllipse(semiMajorM: 300, semiMinorM: 10, orientationDeg: 0)
        let centred = FollowZoom.distance(chosen: 100, headingUp: true, ellipse: ahead, carFromTop: 0.5)
        let lowered = FollowZoom.distance(chosen: 100, headingUp: true, ellipse: ahead)
        #expect(lowered > centred, "the lower-third fit needs a wider view")
        // The zoom state uses its own placement for the fit.
        var zoom = FollowZoom()
        let before = zoom.autoFollowDistance(headingUp: true, ellipse: ahead)
        zoom.carFromTop = 0.5
        #expect(zoom.autoFollowDistance(headingUp: true, ellipse: ahead) < before)
    }

    @Test("R68.1-3: the offer card never covers the car on the smallest iPhone, heading-up and north-up")
    func offerCardClearsCar() {
        let se = CGSize(width: 375, height: 667)
        // Compact card at default type (~120 pt) up to its stacked worst case at accessibility2 (~250 pt).
        for height in [120.0, 160, 250] {
            let card = CarPlacement.offerCardFrame(size: se, height: height)
            for headingUp in [true, false] {
                let from = CarPlacement.carFromTop(headingUp: headingUp, offerShown: true)
                #expect(CarPlacement.clears(card: card, size: se, carFromTop: from),
                        "headingUp \(headingUp), card \(height) pt")
            }
        }
        // The old placement did collide with the old ~210 pt card: the test can fail.
        let old = CarPlacement.offerCardFrame(size: se, height: 210)
        #expect(!CarPlacement.clears(card: old, size: se, carFromTop: CarPlacement.carFromTop))
    }

    @Test("R68.1-2: the HUD card ends in the recording row only while a recording is active")
    func hasRecordingRow() {
        #expect(MapRecordingControl.isActive(.calibrating) && MapRecordingControl.isActive(.recording)
            && MapRecordingControl.isActive(.stopping))
        #expect(!MapRecordingControl.isActive(.idle))
        #expect(!MapRecordingControl.isActive(.failed(reason: "disk full", unwrittenEvents: 0)))
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
