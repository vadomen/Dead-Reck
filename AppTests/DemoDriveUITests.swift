import DriveLoggerCore
import Foundation
import Testing

@testable import DriveLogger

/// REL-DEMO part 3: what the UI binds to while the demo runs, the roads
/// overlay data, the Settings row, the gate guard and the credits.
/// No coordinates here.
@MainActor
@Suite("Demo drive UI (REL-DEMO)", .serialized, .timeLimit(.minutes(2)))
struct DemoDriveUITests {
    /// The map's bindings for `rig`, with distinct app-side objects.
    @MainActor
    struct Objects {
        let appFeed = NavigationFeed(display: nil)
        let demoFeed = NavigationFeed(display: nil)
        let appWarning = RoadsWarningModel(message: "app")
        let demoWarning = RoadsWarningModel(message: "demo")
        let mount: MountConfirmationModel
        var layers: DemoRoadLayers?

        init() {
            let suite = UserDefaults(suiteName: "DemoDriveUITests-\(UUID().uuidString)")!
            mount = MountConfirmationModel(store: OnboardingStore(defaults: suite))
        }

        func bindings(_ rig: DemoDriveControllerTests.Rig) -> MapBindings {
            MapBindings.make(
                appSession: rig.appSession, appLink: rig.appLink, appFeed: appFeed, appWarning: appWarning,
                mount: mount, offers: nil,
                cachedLocation: { CachedLocation(latitude: 1, longitude: 2, horizontalAccuracy: 10) },
                demo: rig.demo, demoFeed: demoFeed, demoWarning: demoWarning, demoRoads: layers)
        }
    }

    @Test("Bindings follow isRunning: the app's objects, then the demo's (session, link, feed, warning, no mount card, no offers, no cached position, DEMO + Stop), then the app's again after Stop")
    func bindingsSwitchAndRestore() async throws {
        let rig = try DemoDriveControllerTests.Rig()
        defer { rig.tearDown() }
        var objects = Objects()

        let before = objects.bindings(rig)
        #expect(before.session === rig.appSession && before.link === rig.appLink)
        #expect(before.navigation === objects.appFeed && before.roadsWarning === objects.appWarning)
        #expect(before.mountConfirmation === objects.mount && before.demo == nil && !before.isDemo)
        #expect(before.cachedLocation() != nil)

        try rig.demo.start()
        objects.layers = rig.demo.roads.map(DemoRoadLayers.init)
        let during = objects.bindings(rig)
        #expect(during.session === rig.demo.session && during.session !== rig.appSession)
        #expect(during.link === rig.demo.link && during.link !== rig.appLink)
        #expect(during.navigation === objects.demoFeed && during.roadsWarning === objects.demoWarning)
        #expect(during.mountConfirmation == nil, "the mount card cannot fire or be marked seen")
        #expect(during.offers == nil)
        #expect(during.cachedLocation() == nil, "the user's real position never frames the demo")
        #expect(during.isDemo && rig.demo.showsDemoBadge)

        rig.demo.stop()
        let after = objects.bindings(rig)
        #expect(after.session === rig.appSession && after.link === rig.appLink)
        #expect(after.navigation === objects.appFeed && after.roadsWarning === objects.appWarning)
        #expect(after.mountConfirmation === objects.mount && after.demo == nil)
        #expect(after.cachedLocation() != nil)
    }

    @Test("The DEMO badge and the overlay data exist only while the demo runs")
    func badgeAndOverlayOnlyWhileRunning() async throws {
        let rig = try DemoDriveControllerTests.Rig()
        defer { rig.tearDown() }
        #expect(!rig.demo.showsDemoBadge && rig.demo.roads == nil)
        try rig.demo.start()
        #expect(rig.demo.showsDemoBadge)
        let roads = try #require(rig.demo.roads)
        let layers = DemoRoadLayers(roads)
        #expect(layers.lineCount > 100, "the roads are drawn")
        #expect(layers.lineCount < roads.lines.count, "service roads are dropped")
        rig.demo.stop()
        #expect(!rig.demo.showsDemoBadge && rig.demo.roads == nil)
    }

    @Test("Overlay layers: service roads dropped, minor first and major last, every line has 2+ points; the region covers the bounds")
    func overlayLayers() throws {
        func line(_ c: RoadClass, _ n: Int = 2) -> DemoDriveRoads.Line {
            DemoDriveRoads.Line(
                highwayClass: c, isOneway: false,
                points: (0..<n).map { GeoPoint(latitude: 10 + Double($0) * 0.001, longitude: 20) })
        }
        #expect(DemoRoadTier.tier(for: .service) == nil)
        #expect(DemoRoadTier.tier(for: .motorway) == .major && DemoRoadTier.tier(for: .tertiary) == .collector)
        #expect(DemoRoadTier.tier(for: .residential) == .minor)
        #expect(DemoRoadTier.major.lineWidth > DemoRoadTier.collector.lineWidth)
        #expect(DemoRoadTier.collector.lineWidth > DemoRoadTier.minor.lineWidth)
        let roads = DemoDriveRoads(
            lines: [line(.primary), line(.service), line(.residential), line(.residential, 1), line(.secondary)],
            southWest: GeoPoint(latitude: 10, longitude: 20), northEast: GeoPoint(latitude: 10.2, longitude: 20.4), route: [])
        let layers = DemoRoadLayers(roads)
        #expect(layers.layers.map(\.tier) == [.minor, .collector, .major])
        #expect(layers.lineCount == 3)
        let demo = MapDemo(roads: layers, southWest: roads.southWest, northEast: roads.northEast, onStop: {})
        let region = demo.region
        #expect(region.span.latitudeDelta > 0.2 && region.span.longitudeDelta > 0.4)
        #expect(abs(region.center.latitude - 10.1) < 1e-9 && abs(region.center.longitude - 20.2) < 1e-9)
    }

    @Test("Settings row: ready, blocked while Record runs (with the reason), blocked without the pack; reset of the map model clears the other source's state")
    func settingsRow() async throws {
        #expect(DemoDriveRow.make(nil) == .ready)
        #expect(DemoDriveRow.make(.recordActive) == .blocked(DemoDriveRow.recordActiveText))
        #expect(DemoDriveRow.make(.unavailable(reason: "x")) != .ready)
        let rig = try DemoDriveControllerTests.Rig()
        defer { rig.tearDown() }
        try await rig.appSession.start(mount: "test", vehicle: "test", allowWithoutOBD: true, calibration: .zero)
        #expect(DemoDriveRow.make(rig.demo.startBlocker) == .blocked(DemoDriveRow.recordActiveText))
        await rig.appSession.stop()
        #expect(DemoDriveRow.make(rig.demo.startBlocker) == .ready)
    }

    @Test("The map model forgets the other source at a demo start or stop: track, dot, bearing, speed, link memory")
    func mapModelReset() {
        let model = MapViewModel()
        let fix = MapPreviewData.fix(1, accuracy: 5)
        model.ingest(fix, file: nil, run: 3, isActive: true)
        model.noteLink(.polling(protocolNumber: "6", voltage: nil), adapter: UUID())
        #expect(model.latest != nil && !model.track.runs.isEmpty && model.obdEverConnected)
        model.resetForDemo()
        #expect(model.latest == nil && model.track.runs.isEmpty && !model.isReceiving)
        #expect(model.bearing == nil && !model.obdEverConnected && model.runKey == MapRunKey(file: nil, run: nil))
        #expect(model.speed == .none)
        // The next run is a new run again.
        model.ingest(fix, file: nil, run: 3, isActive: true)
        #expect(model.latest != nil)
    }

    @Test("Record's start UI shows the demo blocker text")
    func recordShowsDemoBlocker() {
        let notice = StartBlockerNotice(.demoDriveRunning)
        #expect(notice?.message == "The demo drive is running. Stop it to record.")
        #expect(StartErrorText.message(for: RecordingStartBlocker.demoDriveRunning) == notice?.message)
    }

    @Test("Gate guard: in Release with the gate closed the recording, Sessions and Console routes are not allowed and leave the path; open gate and Debug allow all")
    func gateGuard() {
        for route in [SettingsRoute.recording, .sessions, .console] {
            #expect(!route.isAllowed(isDebug: false, gateOpen: false))
            #expect(route.isAllowed(isDebug: false, gateOpen: true))
            #expect(route.isAllowed(isDebug: true, gateOpen: false))
        }
        for route in [SettingsRoute.maps, .adapter, .about] {
            #expect(route.isAllowed(isDebug: false, gateOpen: false))
        }
        let path: [SettingsRoute] = [.maps, .console, .about, .recording, .sessions]
        #expect(SettingsRoute.permitted(path, isDebug: false, gateOpen: false) == [.maps, .about])
        #expect(SettingsRoute.permitted(path, isDebug: false, gateOpen: true) == path)
        #expect(SettingsRoute.permitted(path, isDebug: true, gateOpen: false) == path)
    }

    @Test("About lists the bundled demo map data: ODbL 1.0, the OSM date and the extract, no place name; consistent with the map credit")
    func aboutCredit() {
        let text = AboutContent.demoMapCredit
        #expect(text.hasPrefix(DemoDriveRoads.attribution))
        #expect(DemoDriveRoads.attribution == MapAttribution.text)
        #expect(text.contains("ODbL 1.0") && text.contains("2026-10-08") && text.contains("Geofabrik"))
    }

    @Test("Loop key restarts the map's framing task when the demo starts or stops")
    func loopKey() {
        #expect(MapLoopKey(isLive: true, showsEstimate: true, isDemo: true) != MapLoopKey(isLive: true, showsEstimate: true))
    }
}
