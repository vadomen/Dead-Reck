import Foundation

/// Screens pushed inside Settings (UX-14), in the order of the rows.
enum SettingsRoute: Hashable, CaseIterable {
    case recording
    case sessions
    case maps
    /// UX-34: pair, connect and forget the OBD adapter (`AdapterSettingsScreen`).
    case adapter
    case console
    case about

    /// The "OBD adapter" row shows (UX-34 built its screen).
    static let adapterRowAvailable = true
}

/// Where the app is: the map is always underneath, Settings is a full-screen
/// cover with its own stack. Pure, so the routing rules are unit-testable.
struct AppNavigation: Equatable {
    var isSettingsPresented = false
    var settingsPath: [SettingsRoute] = []

    init(isSettingsPresented: Bool = false, settingsPath: [SettingsRoute] = []) {
        self.isSettingsPresented = isSettingsPresented
        self.settingsPath = settingsPath
    }

    /// Opens Settings at its root, or straight on `route` (the roads warning
    /// opens Settings → Maps).
    mutating func openSettings(_ route: SettingsRoute? = nil) {
        isSettingsPresented = true
        settingsPath = route.map { [$0] } ?? []
    }

    /// Done: back to the map. The stack resets, so the gear opens the root.
    mutating func closeSettings() {
        isSettingsPresented = false
        settingsPath = []
    }

    /// Whether the map shows live: it does not while Settings covers it (the
    /// MapKit view, its camera loop and the at-a-stop card pause, as they did
    /// when Settings was a tab). Navigate/Record do not depend on it.
    var mapIsLive: Bool { !isSettingsPresented }

    /// The DEBUG `-uiScreen` values.
    enum LaunchScreen: String, CaseIterable {
        case map, settings, sessions, maps, console, recording, adapter, about

        var route: SettingsRoute? {
            switch self {
            case .map, .settings: nil
            case .sessions: .sessions
            case .maps: .maps
            case .console: .console
            case .recording: .recording
            case .adapter: .adapter
            case .about: .about
            }
        }
    }

    /// Initial state from `-uiScreen map|settings|sessions|maps|console|recording|adapter|about`.
    /// `mapsShortcut` is the old `-uiMaps` / `-uiFake*` family: Settings → Maps,
    /// unless `-uiScreen` names something else. Unknown or missing values open the map.
    static func launch(screen: String?, mapsShortcut: Bool = false) -> AppNavigation {
        var nav = AppNavigation()
        if let screen, let known = LaunchScreen(rawValue: screen) {
            if known != .map { nav.openSettings(known.route) }
        } else if mapsShortcut {
            nav.openSettings(.maps)
        }
        return nav
    }
}
