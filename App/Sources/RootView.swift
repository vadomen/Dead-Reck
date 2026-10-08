import SwiftUI

/// Composes the tabs from the app's services. Each tab owns a thin view
/// model; the screens themselves take plain values (see `UI/`).
struct RootView: View {
    @State private var recording: RecordingViewModel
    @State private var sessions: SessionsViewModel
    @State private var console: ConsoleViewModel
    @State private var tab: MainTabView<RecordingScreen, SessionsScreen, ConsoleScreen>.Tab

    init(services: AppServices) {
        _recording = State(initialValue: RecordingViewModel(services: services))
        _sessions = State(initialValue: SessionsViewModel(services: services))
        _console = State(initialValue: ConsoleViewModel(services: services))
        var initial = MainTabView<RecordingScreen, SessionsScreen, ConsoleScreen>.Tab.record
        #if DEBUG
        // `-uiTab 1|2` opens Sessions or Console at launch (simulator screenshots).
        initial = .init(rawValue: UserDefaults.standard.integer(forKey: "uiTab")) ?? .record
        #endif
        _tab = State(initialValue: initial)
    }

    var body: some View {
        MainTabView(selection: $tab) {
            RecordingScreen(model: recording)
        } sessions: {
            SessionsScreen(model: sessions)
        } console: {
            ConsoleScreen(model: console)
        }
    }
}
