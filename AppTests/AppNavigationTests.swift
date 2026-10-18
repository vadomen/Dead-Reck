import Foundation
import Testing

@testable import DriveLogger

@Suite("App navigation and map recording control")
struct AppNavigationTests {
    @Test("-uiTab maps in tab order; out of range opens Map")
    func uiTab() {
        #expect(AppTab(launchValue: 0) == .map)
        #expect(AppTab(launchValue: 1) == .sessions)
        #expect(AppTab(launchValue: 2) == .settings)
        // Console is no longer a tab (UX-4): its old value opens Map.
        #expect(AppTab(launchValue: 3) == .map)
        #expect(AppTab.allCases.count == 3)
        #expect(AppTab(launchValue: -1) == .map)
        #expect(AppTab(launchValue: 9) == .map)
        // The key missing from UserDefaults reads as 0.
        #expect(AppNavigation().tab == .map)
    }

    @Test("Console is a Settings row, two taps from any tab")
    func consoleRoute() {
        #expect(SettingsRoute.allCases == [.recording, .console])
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
