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
    private let session: RecordingSession
    private let services: AppServices
    @State private var nav: AppNavigation

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
        _roadsWarning = State(initialValue: RoadsWarningModel(source: {
            await RoadsWarning.current(service: service, library: library)
        }))
        var initial = AppNavigation()
        #if DEBUG
        // `-uiTab N` opens a tab at launch (simulator screenshots), N in tab order:
        // 0 = Map (default), 1 = Sessions, 2 = Settings.
        initial.tab = AppTab(launchValue: UserDefaults.standard.integer(forKey: "uiTab"))
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
                onStart: { nav.openRecordingSettings() },
                onOpenDiagnostics: { nav.tab = .settings; nav.settingsPath = [] },
                roadsWarning: roadsWarning
            )
        } sessions: {
            SessionsScreen(model: sessions)
        } settings: {
            SettingsScreen(path: $nav.settingsPath, roads: roads) {
                RecordingScreen(model: recording)
            } console: {
                ConsoleScreen(model: console)
            }
        }
        // Ingest at the root so the track keeps filling on other tabs. The
        // feed is its own view so only it observes the 16 Hz `live` status.
        .background(MapFeed(session: session, model: map))
        .task { await roadsWarning.run() }
    }
}
