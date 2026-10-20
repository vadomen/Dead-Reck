import Foundation
import Testing

@testable import DriveLogger

@Suite("App navigation and map recording control")
struct AppNavigationTests {
    @Test("-uiScreen: each value opens Settings at its screen; map and unknown values open the map")
    func uiScreen() {
        #expect(AppNavigation.launch(screen: nil) == AppNavigation())
        #expect(AppNavigation.launch(screen: "map") == AppNavigation())
        #expect(AppNavigation.launch(screen: "bogus") == AppNavigation())
        #expect(AppNavigation.launch(screen: "") == AppNavigation())
        #expect(AppNavigation.launch(screen: "settings") == AppNavigation(isSettingsPresented: true, settingsPath: []))
        let routes: [(String, SettingsRoute)] = [
            ("sessions", .sessions), ("maps", .maps), ("console", .console),
            ("recording", .recording), ("adapter", .adapter), ("about", .about),
        ]
        for (value, route) in routes {
            #expect(AppNavigation.launch(screen: value) == AppNavigation(isSettingsPresented: true, settingsPath: [route]))
        }
        // Every launch value is covered above (map + settings + the six routes).
        #expect(AppNavigation.LaunchScreen.allCases.count == 8)
    }

    @Test("-uiMaps and the -uiFake* family open Settings -> Maps; an explicit -uiScreen wins")
    func mapsShortcut() {
        #expect(AppNavigation.launch(screen: nil, mapsShortcut: true) == AppNavigation(isSettingsPresented: true, settingsPath: [.maps]))
        #expect(AppNavigation.launch(screen: nil, mapsShortcut: false) == AppNavigation())
        #expect(AppNavigation.launch(screen: "about", mapsShortcut: true).settingsPath == [.about])
        #expect(AppNavigation.launch(screen: "map", mapsShortcut: true) == AppNavigation())
    }

    @Test("Gear opens Settings at the root, the roads warning opens Maps, Done returns to the map with a clean stack")
    func openAndClose() {
        var nav = AppNavigation()
        #expect(nav.mapIsLive)
        nav.openSettings()
        #expect(nav.isSettingsPresented && nav.settingsPath.isEmpty)
        #expect(!nav.mapIsLive)
        nav.settingsPath = [.sessions]
        nav.closeSettings()
        #expect(!nav.isSettingsPresented && nav.settingsPath.isEmpty && nav.mapIsLive)
        nav.openSettings(.maps)
        #expect(nav.isSettingsPresented && nav.settingsPath == [.maps])
    }

    @Test("Settings routes: Sessions and About are rows, Console and Maps stay")
    func routes() {
        #expect(SettingsRoute.allCases == [.recording, .sessions, .maps, .adapter, .console, .about])
    }

    @Test("Groups: OBD adapter, Maps, Mount, How FuGPS works; then Developer with recording, Sessions, Console (UX-34, prompt 31)")
    func groups() {
        #expect(SettingsRows.driver(adapterAvailable: true) == [.route(.adapter), .route(.maps), .mountAndOrientation, .howItWorks])
        #expect(SettingsRows.driver(adapterAvailable: false) == [.route(.maps), .mountAndOrientation, .howItWorks])
        #expect(SettingsRoute.adapterRowAvailable, "UX-34: the screen exists, so the row shows")
        #expect(SettingsRows.developer(showsConsole: true) == [.route(.recording), .route(.sessions), .route(.console)])
        #expect(SettingsRows.developer(showsConsole: false) == [.route(.recording), .route(.sessions)],
                "Release without the Diagnostics gate: recording and Sessions stay, no Console")
        #expect(SettingsRows.developerFooter == "For test drives and diagnostics")
        let all = SettingsRows.driver() + SettingsRows.developer(showsConsole: true)
        #expect(Set(all) == Set(SettingsRoute.allCases.filter { $0 != .about }.map(SettingsRow.route) + [.mountAndOrientation, .howItWorks]),
                "every route except About (its own section) is in exactly one group")
    }

    @Test("Console follows the Diagnostics gate in Release: hidden until the 7 taps, always in DEBUG")
    @MainActor func consoleGate() {
        let suite = UserDefaults(suiteName: "AppNavigationTests.consoleGate")!
        suite.removePersistentDomain(forName: "AppNavigationTests.consoleGate")
        let release = DeveloperGate(isDebug: false, defaults: suite)
        #expect(!SettingsRows.developer(showsConsole: release.showsDiagnostics).contains(.route(.console)))
        let t0 = Date(timeIntervalSince1970: 1_000)
        for i in 0..<7 { release.tapVersion(at: t0.addingTimeInterval(Double(i) * 0.2)) }
        #expect(SettingsRows.developer(showsConsole: release.showsDiagnostics).contains(.route(.console)))
        let debug = DeveloperGate(isDebug: true, defaults: suite)
        #expect(SettingsRows.developer(showsConsole: debug.showsDiagnostics).contains(.route(.console)))
    }

    @Test("About links point at the site's own pages (EN) and the OSM licence pages")
    func aboutLinks() {
        #expect(AboutContent.privacyURL.absoluteString == "https://fugps.pages.dev/privacy")
        #expect(AboutContent.supportURL.absoluteString == "https://fugps.pages.dev/support")
        #expect(AboutContent.dataURL.absoluteString == "https://fugps.pages.dev/data")
        #expect(AboutContent.osmCopyrightURL.absoluteString == "https://www.openstreetmap.org/copyright")
        #expect(AboutContent.odblURL.host == "opendatacommons.org")
        // Same host as the pack manifest the app downloads from.
        #expect(PackManifestService.manifestURL.host == AboutContent.privacyURL.host)
        #expect(AboutContent.osmCredit.contains("OpenStreetMap contributors") && AboutContent.osmCredit.contains("ODbL"))
        #expect(AboutContent.attention == "Keep your eyes on the road; set up the app before you drive.")
    }

    @Test("Indicator while calibrating, recording or stopping; nothing otherwise (Start is in Settings)")
    func controlState() {
        #expect(MapRecordingControl.make(state: .idle, elapsed: 0) == .none)
        #expect(MapRecordingControl.make(state: .failed(reason: "disk full", unwrittenEvents: 0), elapsed: 5) == .none)
        #expect(MapRecordingControl.make(state: .calibrating, elapsed: 3) == .indicator(elapsed: "0:03"))
        #expect(MapRecordingControl.make(state: .recording, elapsed: 754) == .indicator(elapsed: "12:34"))
        #expect(MapRecordingControl.make(state: .stopping, elapsed: 61) == .indicator(elapsed: "1:01"))
    }

    @Test("Elapsed formatting: m:ss, h:mm:ss from an hour, bad values as 0:00")
    func elapsedFormat() {
        #expect(MapRecordingControl.make(state: .recording, elapsed: 3600) == .indicator(elapsed: "1:00:00"))
        #expect(MapRecordingControl.make(state: .recording, elapsed: 59.9) == .indicator(elapsed: "0:59"))
        #expect(MapRecordingControl.make(state: .recording, elapsed: -4) == .indicator(elapsed: "0:00"))
        #expect(MapRecordingControl.make(state: .recording, elapsed: .nan) == .indicator(elapsed: "0:00"))
    }

    @Test("Stop needs a confirmation: a tap only asks; the dialog going away clears it")
    func stopConfirmation() {
        var stop = StopConfirmation()
        #expect(!stop.isPending)
        stop.request()
        #expect(stop.isPending)
        stop.cancel()
        #expect(!stop.isPending)
        // Request, then the dialog dismisses itself (button or tap outside).
        stop.request()
        stop.cancel()
        #expect(!stop.isPending)
    }

    @Test("Diagnostics build configuration name")
    func configuration() {
        #expect(AppInfo.configurationName(isDebug: true) == "Debug")
        #expect(AppInfo.configurationName(isDebug: false) == "Release")
    }
}
