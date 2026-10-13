import Foundation

/// The main tabs, raw values in tab order. The DEBUG `-uiTab N` launch
/// override uses them: 0 Map, 1 Sessions, 2 Settings, 3 Console.
enum AppTab: Int, Hashable, CaseIterable {
    case map = 0, sessions = 1, settings = 2, console = 3

    /// Tab for a `-uiTab` value; anything out of range opens Map.
    init(launchValue: Int) {
        self = AppTab(rawValue: launchValue) ?? .map
    }
}

/// Screens pushed inside the Settings tab.
enum SettingsRoute: Hashable {
    case recording
}

/// Where the app is: the selected tab and the Settings stack. Pure, so the
/// routing rules are unit-testable.
struct AppNavigation: Equatable {
    var tab: AppTab = .map
    var settingsPath: [SettingsRoute] = []

    init(tab: AppTab = .map, settingsPath: [SettingsRoute] = []) {
        self.tab = tab
        self.settingsPath = settingsPath
    }

    /// The map's Start button: Settings, with Recording pushed. It starts
    /// nothing itself; the checklist and Start live there.
    mutating func openRecordingSettings() {
        tab = .settings
        settingsPath = [.recording]
    }
}
