import DriveLoggerCore
import Foundation
import Testing

@testable import DriveLogger

@Suite("UX-1 part 2: first-launch checklist, heading reset, Record from Settings", .serialized)
@MainActor
struct FirstLaunchAndTestDriveTests {
    func defaults() -> UserDefaults {
        let name = "firstlaunch-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    @Test("First launch asks; confirming stores it; the next launch does not ask")
    func askedOnce() {
        let d = defaults()
        let first = FirstLaunchModel(store: FirstLaunchStore(defaults: d))
        #expect(first.isPresented)
        first.confirm()  // nothing ticked: refused
        #expect(first.isPresented)
        #expect(!FirstLaunchStore(defaults: d).isConfirmed)
        first.checklist.mountConfirmed = true
        #expect(!first.canContinue)
        first.confirm()
        #expect(first.isPresented)
        first.checklist.orientationConfirmed = true
        #expect(first.canContinue)
        first.confirm()
        #expect(!first.isPresented)
        #expect(FirstLaunchStore(defaults: d).isConfirmed)

        let second = FirstLaunchModel(store: FirstLaunchStore(defaults: d))
        #expect(!second.isPresented)
    }

    @Test("The debug override forces it even when confirmed; Settings shows it again unticked")
    func forcedAndShownAgain() {
        let d = defaults()
        FirstLaunchStore(defaults: d).markConfirmed()
        #expect(FirstLaunchModel(store: FirstLaunchStore(defaults: d), forced: true).isPresented)
        let model = FirstLaunchModel(store: FirstLaunchStore(defaults: d))
        model.checklist = PreDriveChecklist(mountConfirmed: true, orientationConfirmed: true)
        model.showAgain()
        #expect(model.isPresented)
        #expect(!model.checklist.isComplete)
        // Closing it again does not unset the stored answer.
        #expect(FirstLaunchStore(defaults: d).isConfirmed)
    }

    @Test("It is separate from Record's per-drive checklist")
    func separateFromRecord() {
        let d = defaults()
        let model = FirstLaunchModel(store: FirstLaunchStore(defaults: d))
        model.checklist = PreDriveChecklist(mountConfirmed: true, orientationConfirmed: true)
        model.confirm()
        // Record's store keeps only notes, and its checklist is still incomplete.
        #expect(ChecklistStore(defaults: d).load().isComplete == false)
    }

    @Test("Heading resets on a new recording and on a new Navigate session, not on the same run or before any")
    func headingResetKey() {
        let a = URL(fileURLWithPath: "/tmp/a.jsonl.gz")
        let b = URL(fileURLWithPath: "/tmp/b.jsonl.gz")
        let nav1 = MapRunKey(file: nil, run: 1)
        let nav2 = MapRunKey(file: nil, run: 3)
        #expect(HeadingReset.isNewRun(from: nil, to: nav1), "first Navigate session")
        #expect(HeadingReset.isNewRun(from: nav1, to: nav2), "Navigate, then another Navigate session")
        #expect(HeadingReset.isNewRun(from: nav1, to: MapRunKey(file: a, run: 2)), "Navigate, then Record")
        #expect(HeadingReset.isNewRun(from: MapRunKey(file: a, run: 2), to: MapRunKey(file: b, run: 4)))
        #expect(HeadingReset.isNewRun(from: MapRunKey(file: a, run: 2), to: nav2), "Record, then Navigate")
        #expect(HeadingReset.isNewRun(from: MapRunKey(file: a, run: nil), to: MapRunKey(file: b, run: nil)), "file alone")
        #expect(!HeadingReset.isNewRun(from: nav1, to: nav1), "a reconnect keeps the session")
        #expect(!HeadingReset.isNewRun(from: nav1, to: nil))
        #expect(!HeadingReset.isNewRun(from: nil, to: MapRunKey(file: nil, run: nil)))
    }

    @Test("The model's run key follows ingest: Navigate runs and recordings each give a new key")
    func modelRunKey() {
        let model = MapViewModel()
        #expect(model.runKey == MapRunKey(file: nil, run: nil))
        model.ingest(nil, file: nil, run: 1, isActive: true)
        let first = model.runKey
        #expect(first == MapRunKey(file: nil, run: 1))
        model.ingest(nil, file: nil, run: 1, isActive: true)
        #expect(model.runKey == first)
        model.ingest(nil, file: nil, run: 2, isActive: true)
        #expect(HeadingReset.isNewRun(from: first, to: model.runKey))
        let file = URL(fileURLWithPath: "/tmp/r.jsonl.gz")
        let before = model.runKey
        model.ingest(nil, file: file, run: 3, isActive: true)
        #expect(HeadingReset.isNewRun(from: before, to: model.runKey))
    }

    @Test("Test drive: Start from Settings (the Record view model) shows the map's indicator; Stop from the map ends it and the indicator goes")
    func startFromSettingsStopFromMap() async throws {
        let scratch = try ScratchStore()
        defer { scratch.remove() }
        let link = FakeLink()
        let session = RecordingFixtures.session(link: link, store: scratch.store)
        let d = defaults()
        let model = RecordingViewModel(
            session: session, link: link, sources: [], simulatedSensors: false, store: ChecklistStore(defaults: d))
        #expect(MapRecordingControl.make(state: session.state, elapsed: 0) == .none, "no Start on the map")

        model.checklist.mountConfirmed = true
        model.checklist.orientationConfirmed = true
        await model.start()
        #expect(session.state == .recording || session.state == .calibrating)
        let control = MapRecordingControl.make(state: session.state, elapsed: session.live.elapsed)
        guard case .indicator = control else {
            Issue.record("expected the red indicator, got \(control)")
            return
        }
        var stop = StopConfirmation()
        stop.request()
        #expect(stop.isPending, "a tap on the indicator only asks")
        #expect(session.state != .idle)
        // The dialog's destructive button: the map's onStop is `session.stop()`.
        await session.stop()
        stop.cancel()
        #expect(session.state == .idle)
        #expect(MapRecordingControl.make(state: session.state, elapsed: 0) == .none)
    }

    @Test("The session says when Navigate began, for the countdown, and clears it at the end")
    func navigateStartedAt() async throws {
        let scratch = try ScratchStore()
        defer { scratch.remove() }
        let session = RecordingFixtures.session(store: scratch.store)
        #expect(session.navigateStartedAt == nil)
        #expect(session.navigateTimings == nil)
        let config = NavigateConfiguration(stillCalibration: .seconds(30), autoStopAfter: .seconds(60))
        let before = ContinuousClock.now
        session.enableNavigate(config)
        #expect(session.navigateTimings == config)
        #expect(session.navigateState == .calibrating)
        let started = try #require(session.navigateStartedAt)
        #expect(started >= before && started <= .now)
        session.disableNavigate()
        #expect(session.navigateState == .off)
        #expect(session.navigateStartedAt == nil)
    }

    @Test("R61.1-1: the map's loop task restarts when the estimate becomes visible (OBD connects after the app opened)")
    func loopKeyFollowsShowsEstimate() {
        let noOBD = NavigateStatus.make(
            navigate: .off, recording: .idle, startedAt: nil, timings: NavigateConfiguration(), now: .now)
        let running = NavigateStatus.make(
            navigate: .running, recording: .idle, startedAt: nil, timings: NavigateConfiguration(), now: .now)
        let before = MapLoopKey(isLive: true, showsEstimate: noOBD.showsEstimate)
        let after = MapLoopKey(isLive: true, showsEstimate: running.showsEstimate)
        #expect(before != after, "keyed on isLive alone (the old wiring) the loop kept its no-estimate copy")
        #expect(before == MapLoopKey(isLive: true, showsEstimate: false))
        #expect(after == MapLoopKey(isLive: true, showsEstimate: true))
        #expect(after != MapLoopKey(isLive: false, showsEstimate: true))
    }
}
