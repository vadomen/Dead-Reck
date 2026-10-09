import SwiftUI

/// Composes the tabs from the app's services. Each tab owns a thin view
/// model; the screens themselves take plain values (see `UI/`).
struct RootView: View {
    @State private var recording: RecordingViewModel
    @State private var map: MapViewModel
    @State private var navigation: NavigationFeed
    @State private var sessions: SessionsViewModel
    @State private var console: ConsoleViewModel
    private let session: RecordingSession
    private let services: AppServices
    @State private var tab: MainTabView<RecordingScreen, MapScreen, SessionsScreen, ConsoleScreen>.Tab

    init(services: AppServices) {
        _recording = State(initialValue: RecordingViewModel(services: services))
        session = services.session
        self.services = services
        _map = State(initialValue: MapViewModel())
        let service = services.navigation
        _navigation = State(initialValue: NavigationFeed(source: { await service.snapshot() }))
        _sessions = State(initialValue: SessionsViewModel(services: services))
        _console = State(initialValue: ConsoleViewModel(services: services))
        var initial = MainTabView<RecordingScreen, MapScreen, SessionsScreen, ConsoleScreen>.Tab.record
        #if DEBUG
        // `-uiTab 1|2|3` opens Sessions, Console or Map at launch (simulator screenshots).
        initial = .init(rawValue: UserDefaults.standard.integer(forKey: "uiTab")) ?? .record
        #endif
        _tab = State(initialValue: initial)
    }

    var body: some View {
        MainTabView(selection: $tab) {
            RecordingScreen(model: recording)
        } map: {
            MapScreen(
                model: map, session: session, navigation: navigation, isSelected: tab == .map,
                cachedLocation: { [services] in
                    services.sensors.sources.lazy
                        .compactMap { $0 as? any CachedLocationProviding }.first?.cachedLocation
                }
            )
        } sessions: {
            SessionsScreen(model: sessions)
        } console: {
            ConsoleScreen(model: console)
        }
        // Ingest at the root so the track keeps filling on other tabs. The
        // feed is its own view so only it observes the 16 Hz `live` status.
        .background(MapFeed(session: session, model: map))
    }
}
