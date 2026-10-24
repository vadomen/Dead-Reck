import DriveLoggerCore
import SwiftUI

/// Composes the map and Settings from the app's services. Each screen owns a thin view
/// model; the screens themselves take plain values (see `UI/`).
struct RootView: View {
    @State private var recording: RecordingViewModel
    @State private var map: MapViewModel
    @State private var navigation: NavigationFeed
    @State private var sessions: SessionsViewModel
    @State private var console: ConsoleViewModel
    @State private var roads: RoadsDiagnosticsModel
    @State private var roadsWarning: RoadsWarningModel
    @State private var maps: MapsModel
    @State private var gate: DeveloperGate
    private let session: RecordingSession
    private let services: AppServices
    @State private var nav: AppNavigation
    /// The first-run info cards (UX-18 (1)), before the maps step.
    @State private var onboarding: OnboardingModel
    @State private var firstMaps: FirstLaunchMapsModel
    /// The one-time in-car mount card (UX-18 (2)): fed by `MapFeed`, shown by the map.
    @State private var mountConfirmation: MountConfirmationModel
    /// The demo drive's own map objects (REL-DEMO), made fresh at each start
    /// so nothing of the previous run shows: the estimate feed, the roads
    /// warning and the converted roads.
    @State private var demoFeed: NavigationFeed
    @State private var demoWarning: RoadsWarningModel
    @State private var demoLayers: DemoRoadLayers?

    init(services: AppServices) {
        _recording = State(initialValue: RecordingViewModel(services: services))
        session = services.session
        self.services = services
        _map = State(initialValue: MapViewModel())
        let service = services.navigation
        _navigation = State(initialValue: NavigationFeed(
            source: { await service.snapshot() }, generation: { await service.currentGeneration }))
        _demoFeed = State(initialValue: Self.makeDemoFeed(services))
        _demoWarning = State(initialValue: Self.makeDemoWarning(services))
        _sessions = State(initialValue: SessionsViewModel(services: services))
        _console = State(initialValue: ConsoleViewModel(services: services))
        _roads = State(initialValue: RoadsDiagnosticsModel(library: services.roadPacks, service: service))
        let library = services.roadPacks
        let session = services.session
        var mapsModel = MapsModel(
            library: library, manifest: services.manifest, downloader: services.downloader,
            runActive: { session.hasActiveRun }, cancelRemoval: services.cancelRemoval)
        #if DEBUG
        // `-uiFakeMaps 1`: two synthetic installed packs and one pending removal
        // (simulator screenshots; the simulator has no packs).
        if UserDefaults.standard.bool(forKey: "uiFakeMaps") { mapsModel = MapsModel(status: DebugFakes.mapsStatus) }
        // `-uiFakeDownloads 1`: a synthetic manifest with a row in each state;
        // `-uiFakeOffline 1`: the same with the "Offline" note.
        let fakeOffline = UserDefaults.standard.bool(forKey: "uiFakeOffline")
        if UserDefaults.standard.bool(forKey: "uiFakeDownloads") || fakeOffline {
            // With `-uiFakeConnection`, the rows and the state line follow it (and the toggle's launch value).
            mapsModel = DebugFakes.downloadsModel(
                offline: fakeOffline, connection: DebugFakes.connection(UserDefaults.standard.string(forKey: "uiFakeConnection")) ?? .unmetered,
                cellularAllowed: UserDefaults.standard.bool(forKey: MapsSettings.cellularKey))
        }
        if UserDefaults.standard.bool(forKey: "uiFakeMapsStore") { mapsModel = DebugFakes.storeMapsModel }
        if UserDefaults.standard.bool(forKey: "uiFakeMapsShort") { mapsModel = DebugFakes.shortMapsModel }
        if UserDefaults.standard.bool(forKey: "uiFakeRemovalPending") { mapsModel = DebugFakes.removalModel }
        #endif
        _maps = State(initialValue: mapsModel)
        var developerGate = DeveloperGate()
        #if DEBUG
        // `-uiReleaseGate 1`: behave like Release with the diagnostics locked;
        // `-uiReleaseGate 2`: like Release after the 7 taps (screenshots).
        let releaseGate = UserDefaults.standard.integer(forKey: "uiReleaseGate")
        if releaseGate > 0 {
            let suite = UserDefaults(suiteName: "uiReleaseGate") ?? .standard
            suite.set(releaseGate == 2, forKey: DeveloperGate.defaultsKey)
            developerGate = DeveloperGate(isDebug: false, defaults: suite)
        }
        #endif
        _gate = State(initialValue: developerGate)
        var warningModel = RoadsWarningModel(source: {
            await RoadsWarning.current(service: service, library: library)
        }, attributionSource: {
            await RoadsWarning.attributionCurrent(service: service)
        })
        #if DEBUG
        // `-uiFakeRoads 1`: the map shows the attribution as if roads were attached.
        if UserDefaults.standard.bool(forKey: "uiFakeRoads") { warningModel = RoadsWarningModel(message: nil, attribution: true) }
        #endif
        _roadsWarning = State(initialValue: warningModel)
        var initial = AppNavigation()
        var forcedCard: Int?
        #if DEBUG
        // `-uiOnboarding 1...4` opens the info cards at that card, seen or not (screenshots).
        forcedCard = UserDefaults.standard.object(forKey: "uiOnboarding") == nil
            ? nil : UserDefaults.standard.integer(forKey: "uiOnboarding")
        #endif
        _onboarding = State(initialValue: OnboardingModel(forcedCard: forcedCard))
        var forceMountCard = false
        #if DEBUG
        // `-uiMountCard 1` shows the in-car mount card whatever the state (screenshots).
        forceMountCard = UserDefaults.standard.bool(forKey: "uiMountCard")
        #endif
        _mountConfirmation = State(initialValue: MountConfirmationModel(forced: forceMountCard))
        #if DEBUG
        // `-uiScreen map|settings|sessions|maps|console|recording|adapter|about`
        // opens Map, Settings or a Settings sub-screen at launch (screenshots).
        // The older `-uiMaps` / `-uiFake*` shortcuts open Settings → Maps.
        let defaults = UserDefaults.standard
        initial = AppNavigation.launch(
            screen: defaults.string(forKey: "uiScreen"),
            mapsShortcut: defaults.bool(forKey: "uiMaps") || defaults.bool(forKey: "uiFakeDownloads")
                || defaults.bool(forKey: "uiFakeOffline") || defaults.bool(forKey: "uiFakeMapsShort"))
        #endif
        var forceMaps = false
        #if DEBUG
        forceMaps = UserDefaults.standard.bool(forKey: FirstLaunchMapsStore.forceKey)
        #endif
        var mapsStep = FirstLaunchMapsModel(services: services, forced: forceMaps)
        #if DEBUG
        // `-uiFakeFirstLaunchList ok|offline|cached`: a synthetic manifest (screenshots).
        if let mode = UserDefaults.standard.string(forKey: "uiFakeFirstLaunchList") {
            mapsStep = FirstLaunchMapsModel(
                services: services, manifest: DebugFakes.firstLaunchManifest(mode: mode, downloader: services.downloader),
                forced: forceMaps)
        }
        // `-uiFakeConnection none|cellular|metered|wifi`: hold the downloader's
        // connection (the simulator is online), for the Settings → Maps line
        // and first-launch button wording shots. Held for the whole run: the
        // real monitor's reports are overridden every half second.
        if let fake = DebugFakes.connection(UserDefaults.standard.string(forKey: "uiFakeConnection")) {
            let downloader = services.downloader
            Task { while !Task.isCancelled { await downloader.setPath(PackPath(connection: fake)); try? await Task.sleep(for: .milliseconds(500)) } }
        }
        #endif
        _firstMaps = State(initialValue: mapsStep)
        _nav = State(initialValue: initial)
    }

    /// The demo's feed: its own navigation service, no shared state with the app's.
    private static func makeDemoFeed(_ services: AppServices) -> NavigationFeed {
        let service = services.demo.navigation
        return NavigationFeed(source: { await service.snapshot() })
    }

    private static func makeDemoWarning(_ services: AppServices) -> RoadsWarningModel {
        let service = services.demo.navigation
        guard let library = services.demo.roadPacks else { return RoadsWarningModel(message: nil) }
        return RoadsWarningModel(source: {
            await RoadsWarning.current(service: service, library: library)
        }, attributionSource: {
            await RoadsWarning.attributionCurrent(service: service)
        })
    }

    /// Settings → Demo drive: starts the demo and goes to the map. Refused
    /// (Record active, no pack): the row says why, nothing changes.
    private func startDemo() {
        let demo = services.demo
        if demo.isRunning {
            nav.closeSettings()
            return
        }
        demoFeed = Self.makeDemoFeed(services)
        demoWarning = Self.makeDemoWarning(services)
        do { try demo.start() } catch { return }
        demoLayers = demo.roads.map(DemoRoadLayers.init)
        nav.closeSettings()
    }

    var body: some View {
        // Every map-facing object is the app's, or the running demo's: one
        // choice, so no frame mixes them (REL-DEMO).
        let bound = MapBindings.make(
            appSession: session, appLink: services.link, appFeed: navigation, appWarning: roadsWarning,
            mount: mountConfirmation, offers: services.packOffers,
            cachedLocation: { [services] in
                services.sensors.sources.lazy
                    .compactMap { $0 as? any CachedLocationProviding }.first?.cachedLocation
            },
            demo: services.demo, demoFeed: demoFeed, demoWarning: demoWarning, demoRoads: demoLayers)
        // The map is the app (UX-14): full screen, Settings is a cover over it.
        // MapScreen stays mounted under the cover, so its model, camera mode
        // and Following state live on.
        MapScreen(
            model: map, session: bound.session, navigation: bound.navigation, isSelected: nav.mapIsLive,
            cachedLocation: bound.cachedLocation,
            onOpenMaps: { nav.openSettings(.maps) },
            onOpenSettings: { nav.openSettings() },
            roadsWarning: bound.roadsWarning,
            offers: bound.offers,
            link: bound.link,
            mountConfirmation: bound.mountConfirmation,
            demo: bound.demo
        )
        .fullScreenCover(isPresented: $nav.isSettingsPresented) {
            SettingsScreen(
                path: $nav.settingsPath, roads: roads, maps: maps, offers: services.packOffers, gate: gate,
                onDone: { nav.closeSettings() },
                onDemoDrive: { startDemo() },
                demoRow: DemoDriveRow.make(services.demo.startBlocker)
            ) {
                RecordingScreen(model: recording)
            } console: {
                ConsoleScreen(model: console)
            } sessions: {
                SessionsScreen(model: sessions)
            } adapter: {
                // UX-34: the Console's model, so the same guards apply.
                #if DEBUG
                // `-uiFakeAdapter connected|notfound|searching|bluetoothOff` (screenshots).
                if let fake = AdapterFake.parse(UserDefaults.standard.string(forKey: "uiFakeAdapter")) {
                    AdapterSettingsContent.fake(fake)
                } else {
                    AdapterSettingsScreen(model: console)
                }
                #else
                AdapterSettingsScreen(model: console)
                #endif
            }
        }
        // Ingest at the root so the track keeps filling while Settings is open. The
        // feed is its own view so only it observes the 16 Hz `live` status.
        .background(MapFeed(session: bound.session, model: map, mount: bound.mountConfirmation))
        .task { await roadsWarning.run() }
        // The demo's own roads warning, polled only while it runs.
        .task(id: services.demo.isRunning) {
            if services.demo.isRunning { await demoWarning.run() }
        }
        .onChange(of: services.demo.isRunning) { _, running in
            if !running { demoLayers = nil }
        }
        .task {
            #if DEBUG
            // `-uiDemo 1` starts the demo at launch (screenshots, UI tests).
            if UserDefaults.standard.bool(forKey: "uiDemo") { startDemo() }
            // `-storeDemoReadyAt S`: signal the capture script at demo second S.
            if let at = StoreScreenshotMode.readyAt() {
                let demo = services.demo
                await StoreScreenshotMode.signalReady(at: at, elapsed: { demo.elapsedSeconds })
            }
            #endif
        }
        // UX-8 (2): the at-a-stop offer loop, with Settings open too.
        .task {
            let map = map
            await services.packOffers.run(live: services.packOfferInputs(speedKmh: { map.speed.kmh.map(Double.init) }))
        }
        .fullScreenCover(isPresented: $onboarding.isPresented) {
            OnboardingCardsView(model: onboarding)
        }
        // UX-8 (1): after the info cards, never on top of them.
        .fullScreenCover(isPresented: Binding(
            get: { !onboarding.isPresented && firstMaps.isPresented }, set: { _ in })
        ) {
            FirstLaunchMapsView(model: firstMaps)
        }
    }
}
