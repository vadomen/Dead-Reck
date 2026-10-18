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
    private let session: RecordingSession
    private let services: AppServices
    @State private var nav: AppNavigation
    @State private var firstLaunch: FirstLaunchModel

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
        var mapsModel = MapsModel(library: library)
        #if DEBUG
        // `-uiFakeMaps 1`: two synthetic installed packs and one pending removal
        // (simulator screenshots; the simulator has no packs).
        if UserDefaults.standard.bool(forKey: "uiFakeMaps") { mapsModel = MapsModel(status: DebugFakes.mapsStatus) }
        #endif
        _maps = State(initialValue: mapsModel)
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
        if UserDefaults.standard.bool(forKey: "uiMaps") { initial.tab = .settings; initial.settingsPath = [.maps] }
        #endif
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
                roadsWarning: roadsWarning
            )
        } sessions: {
            SessionsScreen(model: sessions)
        } settings: {
            SettingsScreen(path: $nav.settingsPath, roads: roads, maps: maps, onShowChecklist: { firstLaunch.showAgain() }) {
                RecordingScreen(model: recording)
            } console: {
                ConsoleScreen(model: console)
            }
        }
        // Ingest at the root so the track keeps filling on other tabs. The
        // feed is its own view so only it observes the 16 Hz `live` status.
        .background(MapFeed(session: session, model: map))
        .task { await roadsWarning.run() }
        .fullScreenCover(isPresented: $firstLaunch.isPresented) {
            FirstLaunchChecklistView(
                checklist: $firstLaunch.checklist, canContinue: firstLaunch.canContinue,
                onContinue: { firstLaunch.confirm() })
        }
    }
}
