import DriveLoggerCore
import SwiftUI

/// Composes the tabs from the app's services. Each tab owns a thin view
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
            mapsModel = DebugFakes.downloadsModel(offline: fakeOffline)
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
        #if DEBUG
        // `-uiTab N` opens a tab at launch (simulator screenshots), N in tab order:
        // 0 = Map (default), 1 = Sessions, 2 = Settings.
        initial.tab = AppTab(launchValue: UserDefaults.standard.integer(forKey: "uiTab"))
        // `-uiMaps 1` opens Settings → Maps.
        if UserDefaults.standard.bool(forKey: "uiMaps") || UserDefaults.standard.bool(forKey: "uiFakeDownloads")
            || UserDefaults.standard.bool(forKey: "uiFakeOffline")
            || UserDefaults.standard.bool(forKey: "uiFakeMapsShort") { initial.tab = .settings; initial.settingsPath = [.maps] }
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
        // `-uiFakeConnection none|cellular`: hold the downloader's connection
        // (the simulator is online), for first-launch button wording shots.
        if let value = UserDefaults.standard.string(forKey: "uiFakeConnection") {
            let downloader = services.downloader
            let fake: PackDownloadRules.Connection = value == "cellular" ? .cellularOrExpensive : .none
            Task { for _ in 0..<60 { await downloader.setConnection(fake); try? await Task.sleep(for: .milliseconds(500)) } }
        }
        #endif
        _firstMaps = State(initialValue: mapsStep)
        _nav = State(initialValue: initial)
    }

    var body: some View {
        MainTabView(selection: $nav.tab) {
            MapScreen(
                model: map, session: session, navigation: navigation, isSelected: nav.tab == .map,
                cachedLocation: { [services] in
                    services.sensors.sources.lazy
                        .compactMap { $0 as? any CachedLocationProviding }.first?.cachedLocation
                },
                onOpenMaps: { nav.tab = .settings; nav.settingsPath = [.maps] },
                roadsWarning: roadsWarning,
                offers: services.packOffers
            )
        } sessions: {
            SessionsScreen(model: sessions)
        } settings: {
            SettingsScreen(path: $nav.settingsPath, roads: roads, maps: maps, offers: services.packOffers, gate: gate, onShowChecklist: { firstLaunch.showAgain() }) {
                RecordingScreen(model: recording)
            } console: {
                ConsoleScreen(model: console)
            }
        }
        // Ingest at the root so the track keeps filling on other tabs. The
        // feed is its own view so only it observes the 16 Hz `live` status.
        .background(MapFeed(session: session, model: map))
        .task { await roadsWarning.run() }
        // UX-8 (2): the at-a-stop offer loop, on any tab.
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
