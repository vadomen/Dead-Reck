import CoreLocation
import DriveLoggerCore
import Foundation
import Testing

@testable import DriveLogger

/// A `DisplayLocationProviding` that logs every start and stop, so a test
/// sees the order of hand-overs and the fixes the session accepts.
@MainActor
final class FakeDisplayLocation: DisplayLocationProviding {
    private(set) var isRunning = false
    private(set) var starts = 0
    private(set) var stops = 0
    var onFix: (@MainActor (LocationSample) -> Void)?
    var onAuthorizationChange: (@MainActor () -> Void)?

    func start() {
        guard !isRunning else { return }
        isRunning = true
        starts += 1
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        stops += 1
    }

    /// The feed shows a fix (whether or not it runs: a late hop).
    func show(_ fix: LocationSample) { onFix?(fix) }

    static func fix(_ latitude: Double = 50.45) -> LocationSample {
        LocationSample(
            latitude: latitude, longitude: 30.52, altitude: 0, horizontalAccuracy: 5, verticalAccuracy: 3,
            speed: -1, speedAccuracy: -1, course: -1, courseAccuracy: -1)
    }
}

/// A run's location source that notes whether the display feed was running
/// at the moment it started: it must never be (one consumer at a time).
@MainActor
final class OrderCheckedLocationSource: FakeReferenceFixSource {
    var display: FakeDisplayLocation?
    private(set) var displayRunningAtStart: [Bool] = []

    override func start(clock: SessionClock, sink: LogSink) throws {
        displayRunningAtStart.append(display?.isRunning ?? false)
        try super.start(clock: clock, sink: sink)
    }
}

/// R61.1-4: the map-only position feed. Runs only while the app is active,
/// Navigate has no session and no recording runs; hands over to each run's
/// source and back; never in the background; writes nothing.
@Suite("Display location (R61.1-4)")
@MainActor
struct DisplayLocationTests {
    private func rig(_ scratch: ScratchStore) -> (NavigateRig, FakeDisplayLocation, OrderCheckedLocationSource) {
        let display = FakeDisplayLocation()
        let location = OrderCheckedLocationSource(name: "fakeLocation")
        location.display = display
        let rig = NavigateRig(store: scratch.store, extraSources: [location], displayLocation: display)
        return (rig, display, location)
    }

    @Test("Runs only while the app is active: not before a scene phase, not inactive or background; a fix after stop is dropped")
    func scenePhases() throws {
        let scratch = try ScratchStore()
        defer { scratch.remove() }
        let (rig, display, _) = rig(scratch)
        #expect(!display.isRunning, "no scene phase yet")

        rig.session.handleScenePhase(.active)
        #expect(display.isRunning)
        let fix = FakeDisplayLocation.fix()
        display.show(fix)
        #expect(rig.session.displayFix == fix)
        #expect(rig.session.latestFix == nil, "latestFix stays the live run's fix")

        rig.session.handleScenePhase(.inactive)
        #expect(!display.isRunning)
        #expect(rig.session.displayFix == nil)
        rig.session.handleScenePhase(.active)
        #expect(display.isRunning)

        rig.session.handleScenePhase(.background)
        #expect(!display.isRunning, "D7: no location in the background")
        display.show(FakeDisplayLocation.fix(1))
        #expect(rig.session.displayFix == nil, "a fix hopped over after stop")
        rig.session.handleScenePhase(.inactive)
        #expect(!display.isRunning)
        rig.session.handleScenePhase(.active)
        #expect(display.isRunning)
        #expect(display.starts == 3)
    }

    @Test("Navigate takes location over from the display feed before its source starts, and gives it back when it ends")
    func navigateHandOver() async throws {
        let scratch = try ScratchStore()
        defer { scratch.remove() }
        let (rig, display, location) = rig(scratch)
        rig.session.handleScenePhase(.active)
        await rig.connect(speed: 0)
        // Navigate enabled and polling: a session exists.
        display.show(FakeDisplayLocation.fix())
        #expect(rig.session.displayFix != nil)
        rig.session.enableNavigate(RecordingSessionNavigateTests.quick)
        #expect(rig.session.navigateState != .off)
        #expect(!display.isRunning)
        #expect(rig.session.displayFix == nil)
        #expect(location.displayRunningAtStart == [false])
        #expect(location.isRunning)

        // A late display fix does not leak into the run's fix or the map's.
        display.show(FakeDisplayLocation.fix(2))
        #expect(rig.session.displayFix == nil && rig.session.latestFix == nil)

        // Background and back: the run's source goes on, the display stays off.
        rig.session.handleScenePhase(.background)
        rig.session.handleScenePhase(.active)
        #expect(!display.isRunning)

        rig.session.disableNavigate()
        #expect(!location.isRunning)
        #expect(display.isRunning, "back to the display feed once Navigate ends")
        #expect(display.starts == 2)
    }

    @Test("Navigate waiting for the adapter still owns location; Navigate without a session (no OBD) does not")
    func noOBD() async throws {
        let scratch = try ScratchStore()
        defer { scratch.remove() }
        let (rig, display, location) = rig(scratch)
        rig.link.state = .idle
        rig.session.handleScenePhase(.active)
        rig.session.enableNavigate(RecordingSessionNavigateTests.quick)   // no link yet: no session
        #expect(rig.session.navigateState == .off)
        #expect(display.isRunning && !location.isRunning)
        await rig.connect(speed: 0)
        rig.link.state = .polling(protocolNumber: "A6", voltage: 12.4)
        #expect(await eventually(5) { rig.session.navigateState != .off })
        #expect(!display.isRunning && location.isRunning)
        rig.session.disableNavigate()
    }

    @Test("Record takes location over, a recording's fix is the run's latestFix, and the display feed returns after Stop")
    func recordHandOver() async throws {
        let scratch = try ScratchStore()
        defer { scratch.remove() }
        let (rig, display, location) = rig(scratch)
        rig.session.handleScenePhase(.active)
        #expect(display.isRunning)
        display.show(FakeDisplayLocation.fix())

        try await rig.session.start(mount: "", vehicle: "", allowWithoutOBD: true, calibration: .zero)
        #expect(!display.isRunning)
        #expect(location.displayRunningAtStart == [false], "the display feed stops before the recording's source starts")
        #expect(rig.session.displayFix == nil)
        #expect(rig.session.latestFix == nil, "no fix until the run's first fix")
        let recorded = location.fix(speed: 10)
        location.show(recorded)
        #expect(rig.session.latestFix == recorded)
        #expect(rig.session.displayFix == nil)
        display.show(FakeDisplayLocation.fix(3))
        #expect(rig.session.displayFix == nil, "a late display fix during a recording")

        rig.session.handleScenePhase(.background)
        rig.session.handleScenePhase(.active)
        #expect(!display.isRunning, "still the recording's")

        await rig.session.stop()
        #expect(rig.session.latestFix == nil)
        #expect(display.isRunning, "no Navigate session (no OBD): back to the display feed")
        #expect(display.starts == 2)
    }

    @Test("A Start that throws leaves the display feed running; Record then Navigate: it stays off")
    func startThrowsAndNavigateAfterRecord() async throws {
        let scratch = try ScratchStore()
        defer { scratch.remove() }
        let (rig, display, location) = rig(scratch)
        rig.link.state = .idle
        rig.session.handleScenePhase(.active)
        await #expect(throws: RecordingStartBlocker.self) {
            try await rig.session.start(mount: "", vehicle: "", allowWithoutOBD: false, calibration: .zero)
        }
        #expect(display.isRunning, "nothing took location")

        await rig.connect(speed: 0)
        rig.link.state = .polling(protocolNumber: "A6", voltage: 12.4)
        rig.session.enableNavigate(RecordingSessionNavigateTests.quick)
        #expect(!display.isRunning)
        try await rig.session.start(mount: "", vehicle: "", allowWithoutOBD: false, calibration: .zero)
        #expect(!display.isRunning)
        await rig.session.stop()
        #expect(rig.session.navigateState != .off, "Navigate resumes after Stop")
        #expect(!display.isRunning, "and keeps location")
        #expect(location.displayRunningAtStart.allSatisfy { !$0 })
        rig.session.disableNavigate()
        #expect(display.isRunning)
    }

    @Test("The simulator suite has a simulated display feed outside `sources`; the real feed never starts without granted authorisation")
    func sources() {
        let suite = SensorSuite.simulated()
        #expect(suite.displayLocation is SimulatedDisplayLocationSource)
        #expect(!suite.sources.contains { $0 === (suite.displayLocation as AnyObject) })
        for status in [CLAuthorizationStatus.notDetermined, .denied, .restricted] {
            let source = DisplayLocationSource(authorization: FakeLocationAuthorization(status))
            source.start()
            #expect(!source.isRunning, "no prompt, no updates")
        }
    }

    @Test("MapViewModel.ingestDisplay: the dot and age, no track, no run change; ignored while inactive")
    func mapModel() {
        let model = MapViewModel()
        let fix = FakeDisplayLocation.fix()
        model.ingestDisplay(fix, isActive: false)
        #expect(model.latest == nil)
        model.ingestDisplay(nil, isActive: true)
        #expect(model.latest == nil && !model.isReceiving)
        model.ingestDisplay(fix, isActive: true)
        #expect(model.latest == fix && model.isReceiving)
        #expect(model.track.points.isEmpty, "display fixes are not a track")
        #expect(model.currentRun == nil && model.currentFile == nil)

        // After a run ended the model keeps the run's track; display moves only the dot.
        var runFix = FakeDisplayLocation.fix(1)
        runFix.receivedT = MonotonicTimestamp(seconds: 1)
        model.ingest(runFix, file: nil, run: 7, isActive: true)
        let trackCount = model.track.points.count
        #expect(trackCount > 0)
        model.ingest(nil, file: nil, run: nil, isActive: true)
        model.ingestDisplay(FakeDisplayLocation.fix(2), isActive: true)
        #expect(model.track.points.count == trackCount && model.currentRun == 7)
        #expect(model.latest == FakeDisplayLocation.fix(2) && model.isReceiving)
    }
}
