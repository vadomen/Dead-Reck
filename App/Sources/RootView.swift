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
    @State private var firstLaunch: FirstLaunchModel
    @State private var firstMaps: FirstLaunchMapsModel
    /// The one-time in-car mount card (UX-18 (2)): fed by `MapFeed`, shown by the map.
    @State private var mountConfirmation: MountConfirmationModel

    init(services: AppServices) {
        _recording = State(initialValue: RecordingViewModel(services: services))
        session = services.session
        self.services = services
        _map = State(initialValue: MapViewModel())
        let service = services.navigation
        _navigation = State(initialValue: NavigationFeed(source: { await service.snapshot() }))
        _sessions = State(initialValue: SessionsViewModel(services: services))
        _console = State(initialValue: ConsoleViewModel(services: services))
        _roads = State(initialValue: RoadsDiagnosticsModel(library: services.roadPacks, service: service))
        let library = services.roadPacks
        var mapsModel = MapsModel(library: library, manifest: services.manifest, downloader: services.downloader)
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
        if UserDefaults.standard.bool(forKey: "uiFakeMapsShort") { mapsModel = DebugFakes.shortMapsModel }
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
        var forceFirstLaunch = false
        #if DEBUG
        // `-uiFirstLaunch 1` shows the first-launch checklist (screenshots).
        forceFirstLaunch = UserDefaults.standard.bool(forKey: "uiFirstLaunch")
        #endif
        _firstLaunch = State(initialValue: FirstLaunchModel(forced: forceFirstLaunch))
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

    var body: some View {
        // The map is the app (UX-14): full screen, Settings is a cover over it.
        // MapScreen stays mounted under the cover, so its model, camera mode
        // and Following state live on.
        MapScreen(
            model: map, session: session, navigation: navigation, isSelected: nav.mapIsLive,
            cachedLocation: { [services] in
                services.sensors.sources.lazy
                    .compactMap { $0 as? any CachedLocationProviding }.first?.cachedLocation
            },
            onOpenMaps: { nav.openSettings(.maps) },
            onOpenSettings: { nav.openSettings() },
            roadsWarning: roadsWarning,
            offers: services.packOffers,
            link: services.link,
            mountConfirmation: mountConfirmation
        )
        .fullScreenCover(isPresented: $nav.isSettingsPresented) {
            SettingsScreen(
                path: $nav.settingsPath, roads: roads, maps: maps, offers: services.packOffers, gate: gate,
                onShowChecklist: {
                    // One cover at a time: close Settings, then show the checklist.
                    nav.closeSettings()
                    Task {
                        try? await Task.sleep(for: .milliseconds(500))
                        firstLaunch.showAgain()
                    }
                },
                onDone: { nav.closeSettings() }
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
        .background(MapFeed(session: session, model: map, mount: mountConfirmation))
        .task { await roadsWarning.run() }
        // UX-8 (2): the at-a-stop offer loop, with Settings open too.
        .task {
            let map = map
            await services.packOffers.run(live: services.packOfferInputs(speedKmh: { map.speed.kmh.map(Double.init) }))
        }
        .fullScreenCover(isPresented: $firstLaunch.isPresented) {
            FirstLaunchChecklistView(
                checklist: $firstLaunch.checklist, canContinue: firstLaunch.canContinue,
                onContinue: { firstLaunch.confirm() })
        }
        // UX-8 (1): after the checklist, never on top of it.
        .fullScreenCover(isPresented: Binding(
            get: { !firstLaunch.isPresented && firstMaps.isPresented }, set: { _ in })
        ) {
            FirstLaunchMapsView(model: firstMaps)
        }
    }
}
