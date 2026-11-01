import DriveLoggerCore
import Foundation
import Testing

@testable import DriveLogger

// UX-7 (prompt 47), recorder and service side: the no-OBD start rule, the
// no-OBD run, the user's Stop, the seeded restart when the adapter reaches
// `polling`, the OBD auto-stop back to no-OBD, Record from a no-OBD run,
// save/restore, pins and the UI's status. Fakes and rigs from
// RecordingTestSupport.swift, RecordingSessionNavigateTests.swift and
// NavigationRestoreAppTests.swift; short timings instead of 30 s. Synthetic
// positions a few hundred metres from (0, 0). What a phone does (real
// Location authorisation, background, BLE) is in docs/PLAN.md §6.

/// A `FakeBackgroundSource` that reports whether Location is granted, as
/// `ReferenceLocationSource` does on a phone (`LocationGrantReporting`).
@MainActor
final class FakeGrantSource: FakeBackgroundSource, LocationGrantReporting {
    var isLocationGranted = true {
        didSet { onAvailabilityChange?() }
    }
}

@Suite("Navigate without OBD (UX-7)", .serialized, .timeLimit(.minutes(3)))
@MainActor
struct NavigateNoOBDTests {
    typealias S = NavigationServiceNavigateTests
    typealias R = RestoreScript

    /// Navigate's timings with a short no-OBD start and still phase.
    static func config(after: Duration = .milliseconds(400), autoStop: Duration = .seconds(600)) -> NavigateConfiguration {
        NavigateConfiguration(stillCalibration: .milliseconds(200), autoStopAfter: autoStop, noOBDStartAfter: after)
    }

    /// A rig whose link is not polling and whose app is active, Navigate
    /// not yet enabled.
    static func rig(_ store: LogStore = RecordingSessionNavigateTests.absentStore(),
                    service: NavigationService = NavigationService(),
                    extraSources: [any SensorSource] = []) -> NavigateRig {
        let rig = NavigateRig(store: store, service: service, extraSources: extraSources)
        rig.link.state = .ready
        rig.session.handleScenePhase(.active)
        service.provideNoOBD(to: rig.session)
        return rig
    }

    /// `range` (script seconds on the run's clock, whose 0 is uptime
    /// `runBase`) of driving from the scripted source: motion at 50 Hz with a
    /// slight yaw, a GNSS fix on whole seconds after 0 while `fixes`. No OBD.
    /// Returns the inputs sent.
    @discardableResult
    static func drive(_ rig: NavigateRig, _ range: Range<Double>, runBase: Double, fixes: Bool = true) -> Int {
        var sent = 0
        var k = Int((range.lowerBound * 50).rounded())
        while Double(k) / 50 < range.upperBound - 1e-9 {
            let t = Double(k) / 50
            var events = [S.motion(t, yawRate: 0.002)]
            if fixes, k % 50 == 0, k > 0 { events.insert(S.fix(t), at: 0) }
            rig.uptime.set(runBase + t)
            rig.source.emit(events)
            sent += events.count
            k += 1
        }
        return sent
    }

    /// Waits until a no-OBD run runs; its generation.
    static func noOBDRun(_ rig: NavigateRig, within seconds: Double = 5) async throws -> Int {
        #expect(await eventually(seconds) { rig.session.navigateState == .runningNoOBD })
        return try #require(rig.session.navigateGeneration)
    }

    static func isOBDRun(_ state: NavigateState) -> Bool {
        switch state {
        case .calibrating, .running, .waitingForOBD: true
        case .off, .runningNoOBD: false
        }
    }

    // MARK: Start rule

    @Test("An adapter reaching polling within the window starts the OBD run; the timer stops and no no-OBD run ever starts")
    func adapterWithinWindow() async throws {
        let rig = Self.rig()
        rig.session.enableNavigate(Self.config(after: .milliseconds(600)))
        #expect(rig.session.navigateState == .off)
        #expect(rig.session.noOBDStartArmedAt != nil, "armed: active, Location granted, no adapter")
        try await Task.sleep(for: .milliseconds(200))
        rig.link.state = .polling(protocolNumber: "A6", voltage: 12.4)
        #expect(await eventually(5) { Self.isOBDRun(rig.session.navigateState) })
        #expect(rig.session.noOBDStartArmedAt == nil)
        try await Task.sleep(for: .milliseconds(900))
        #expect(Self.isOBDRun(rig.session.navigateState))
        #expect(rig.tee.feeds.count == 1 && rig.tee.feeds.allSatisfy { !$0.noOBD && $0.restartCapture == nil })
        #expect(rig.session.noOBDNavigation == nil)
        rig.session.disableNavigate()
    }

    @Test("The timer fires: a no-OBD run with the Navigate run's sources, background location, tap-only sink and no altimeter; its engine is the no-OBD one; no calibration; the UI status is published")
    func timerStartsNoOBDRun() async throws {
        let altimeter = FakeRecordingOnlySource(name: "fakeBaro")
        let store = RecordingSessionNavigateTests.absentStore()
        let rig = Self.rig(store, extraSources: [altimeter])
        let armed = ContinuousClock.now
        rig.session.enableNavigate(Self.config())
        let generation = try await Self.noOBDRun(rig)
        #expect(ContinuousClock.now - armed >= .milliseconds(380), "not before the window")
        #expect(rig.session.noOBDStartArmedAt == nil)
        let feed = try #require(rig.tee.feed(generation))
        #expect(feed.noOBD && feed.output == .navigateOnly && feed.restartCapture == nil && feed.navPrior == nil)
        #expect(feed.header.adapter == nil && feed.header.polling == nil, "no adapter in the (unwritten) header")
        #expect(rig.source.startedWithBackgroundLocation == [true])
        #expect(altimeter.starts == 0)
        #expect(rig.idle.values.last == true)
        #expect(rig.session.noOBDNavigation != nil)
        #expect(rig.session.navigateStartedAt != nil)
        #expect(!FileManager.default.fileExists(atPath: store.directory.path), "nothing written")

        let runBase = rig.uptime.uptimeSeconds
        let sent = Self.drive(rig, 0..<4, runBase: runBase)
        #expect(await rig.settled(generation, sent))
        #expect(rig.session.navigateState == .runningNoOBD, "no calibration phase")
        #expect(await eventually(5) { rig.session.noOBDNavigation?.estimatedSpeedKmh != nil })
        let status = try #require(rig.session.noOBDNavigation)
        #expect(!status.positionUncertain && status.lastFixOrPinT != nil)
        rig.session.disableNavigate()
        #expect(await R.ended(rig.tee.service, generation))
        #expect(await rig.tee.service.finished.last?.noOBD == true)
        #expect(rig.session.noOBDNavigation == nil && rig.source.stops == 1)
    }

    enum Condition: String, CaseIterable, Sendable {
        case background, recording, demo, locationDenied, locationNotGranted, navigateDisabled
    }

    @Test("Each start condition breaking cancels the timer; when all hold again it starts again from 0", arguments: Condition.allCases)
    func conditionCancelsTimer(_ condition: Condition) async throws {
        let scratch = try ScratchStore()
        defer { scratch.remove() }
        let denied = FakeBackgroundSource(name: "fakeLocation")
        let grant = FakeGrantSource(name: "fakeGrant")
        let rig = Self.rig(scratch.store, extraSources: [denied, grant])
        let window = Duration.milliseconds(600)
        rig.session.enableNavigate(Self.config(after: window))
        #expect(rig.session.noOBDStartArmedAt != nil)
        try await Task.sleep(for: .milliseconds(200))

        switch condition {
        case .background: rig.session.handleScenePhase(.background)
        case .recording: try await rig.session.start(mount: "", vehicle: "", allowWithoutOBD: true, calibration: .zero)
        case .demo: #expect(rig.session.holdForDemo())
        case .locationDenied: denied.availability = SensorUnavailableReason.locationDenied.availability
        case .locationNotGranted: grant.isLocationGranted = false
        case .navigateDisabled: rig.session.disableNavigate()
        }
        #expect(rig.session.noOBDStartArmedAt == nil, "cancelled")
        try await Task.sleep(for: .milliseconds(900))
        #expect(rig.session.navigateState == .off)
        #expect(!rig.tee.feeds.contains { $0.noOBD })

        switch condition {
        case .background: rig.session.handleScenePhase(.active)
        case .recording: await rig.session.stop()
        case .demo: rig.session.releaseDemoHold()
        case .locationDenied: denied.availability = .available
        case .locationNotGranted: grant.isLocationGranted = true
        case .navigateDisabled: rig.session.enableNavigate(Self.config(after: window))
        }
        let restored = ContinuousClock.now
        #expect(rig.session.noOBDStartArmedAt != nil, "armed again")
        let generation = try await Self.noOBDRun(rig)
        #expect(ContinuousClock.now - restored >= .milliseconds(580), "from 0 again, not the first arming's deadline")
        rig.session.disableNavigate()
        #expect(await R.ended(rig.tee.service, generation))
    }

    @Test("Never armed while inactive or before the first scene phase, nor without the configuration's window (the demo session)")
    func notArmedWithoutForegroundOrWindow() async throws {
        let rig = NavigateRig(store: RecordingSessionNavigateTests.absentStore())
        rig.link.state = .ready
        rig.session.enableNavigate(Self.config())
        #expect(rig.session.noOBDStartArmedAt == nil, "no scene phase yet")
        rig.session.handleScenePhase(.inactive)
        #expect(rig.session.noOBDStartArmedAt == nil)
        rig.session.enableNavigate(NavigateConfiguration(stillCalibration: .zero, autoStopAfter: .seconds(600),
                                                         noOBDStartAfter: nil))
        rig.session.handleScenePhase(.active)
        #expect(rig.session.noOBDStartArmedAt == nil, "no window: never")
        try await Task.sleep(for: .milliseconds(600))
        #expect(rig.session.navigateState == .off && rig.tee.feeds.isEmpty)
    }

    @Test("The app's timings: the decided 30 s window; off only in a DEBUG build hosting XCTest (this process), so the host app never starts a no-OBD run beside the tests")
    func appTimings() {
        #expect(NavigateConfiguration().noOBDStartAfter == .seconds(30))
        #expect(AppServices.navigateConfiguration(environment: [:]) == NavigateConfiguration())
        #expect(AppServices.isTestHost(environment: ProcessInfo.processInfo.environment), "the tests run in the host app")
        #expect(AppServices.navigateConfiguration().noOBDStartAfter == nil)
        let configuration = AppServices.navigateConfiguration()
        #expect(configuration.stillCalibration == .seconds(5) && configuration.autoStopAfter == .seconds(300))
    }

    // MARK: Restart with OBD

    @Test("The adapter reaches polling mid no-OBD run: the run ends and an OBD run starts at once, seeded from the no-OBD estimate (prior present, not a hand-over, class moving, unconfirmed), position continuous")
    func adapterMidRunSeedsOBDRun() async throws {
        let service = NavigationService()
        let rig = Self.rig(service: service)
        rig.session.enableNavigate(Self.config())
        let noOBD = try await Self.noOBDRun(rig)
        let runBase = rig.uptime.uptimeSeconds
        let sent = Self.drive(rig, 0..<8, runBase: runBase)
        #expect(await rig.settled(noOBD, sent))
        #expect(await eventually(5) { service.handOver.capture?.generation == noOBD })
        let capture = try #require(service.handOver.capture?.state)

        rig.link.state = .polling(protocolNumber: "A6", voltage: 12.4)
        #expect(await eventually(5) { Self.isOBDRun(rig.session.navigateState) })
        let obd = try #require(rig.session.navigateGeneration)
        #expect(obd > noOBD)
        let feed = try #require(rig.tee.feed(obd))
        #expect(!feed.noOBD)
        #expect(feed.restartCapture == capture, "the no-OBD run's capture, taken before its sources stopped")
        #expect(await R.ended(service, noOBD))
        #expect(await R.wait { await service.lastNoOBDRestart?.generation == obd })
        let restart = try #require(await service.lastNoOBDRestart)
        #expect(!restart.handOver && restart.restoreClass == .moving)
        #expect(restart.ageS >= 0 && restart.ageS < 1)
        #expect(await service.lastRestoreGeneration == obd)

        // The OBD run's first inputs on its own clock (0 = the restart).
        let obdBase = rig.uptime.uptimeSeconds
        var obdSent = 0
        for k in 0..<25 {
            let t = Double(k) / 50
            rig.uptime.set(obdBase + t)
            rig.source.emit([S.motion(t, yawRate: 0.002)])
            obdSent += 1
            if k == 10 {
                await rig.send(InitScript.poll(seq: 500, speed: 36, at: obdBase + t))
                obdSent += 1
            }
        }
        #expect(await rig.settled(obd, obdSent))
        let snapshot = await service.snapshot(at: MonotonicTimestamp(seconds: 0.48))
        #expect(snapshot.restore.status == .unconfirmed)
        #expect(snapshot.initialized)
        // Continuity: within the prior's growth of where the no-OBD run was
        // (10 m/s for under 1 s, plus its ellipse).
        let jump = S.distanceM(snapshot, capture.latitude, capture.longitude)
        #expect(jump < 30, "position jump at the restart: \(jump) m")
        #expect(await service.finished.first { $0.generation == noOBD }?.noOBD == true)
        rig.session.disableNavigate()
        #expect(await R.ended(service, obd))
        #expect(await service.finished.first { $0.generation == obd }?.noOBD == false)
    }

    @Test("The adapter reaches polling before the no-OBD engine has an estimate: no capture, so the OBD run restores from the saved estimate as any Navigate start (the prior is not lost)")
    func restartWithoutCaptureReadsTheStore() async throws {
        let restore = RestoreScratch()
        defer { restore.remove() }
        let service = R.service(restore.store)
        let rig = Self.rig(service: service)
        // A saved estimate on this boot, 1 s before the rig's uptime.
        restore.store.save(NavigationRestoreState(
            savedAt: Date().addingTimeInterval(-1), bootSessionID: R.boot, uptimeSeconds: NavigateRig.base - 1,
            latitude: 0, longitude: 0, covEE: 25, covEN: 0, covNN: 25, headingDeg: 60, headingStdDeg: 3,
            converged: true, restoreClass: .moving, speedMps: 10, lastOBDSpeedKmh: nil, lastOBDAgeS: nil))
        await restore.store.drain()
        rig.session.enableNavigate(Self.config())
        let noOBD = try await Self.noOBDRun(rig)
        #expect(await R.wait { await service.lastRestoreGeneration == noOBD })
        // No inputs: the no-OBD engine publishes nothing yet.
        #expect(service.handOver.state(generation: noOBD) == nil)
        rig.link.state = .polling(protocolNumber: "A6", voltage: 12.4)
        #expect(await eventually(5) { Self.isOBDRun(rig.session.navigateState) })
        let obd = try #require(rig.session.navigateGeneration)
        #expect(rig.tee.feed(obd)?.restartCapture == nil)
        #expect(await R.wait { await service.lastRestoreGeneration == obd })
        if case .restored = await service.lastRestore {} else {
            Issue.record("not restored: \(String(describing: await service.lastRestore))")
        }
        #expect(await service.lastNoOBDRestart == nil)
        rig.session.disableNavigate()
        #expect(await R.ended(service, obd))
    }

    // MARK: OBD auto-stop, back to no-OBD

    @Test("OBD run auto-stops (estimate saved as engine off) → off → a no-OBD run starts after the window in the foreground and restores from that estimate; in the background nothing starts until active again", arguments: [false, true])
    func autoStopThenNoOBD(_ background: Bool) async throws {
        let restore = RestoreScratch()
        defer { restore.remove() }
        let service = R.service(restore.store)
        let rig = NavigateRig(store: RecordingSessionNavigateTests.absentStore(), service: service)
        service.provideNoOBD(to: rig.session)
        rig.session.handleScenePhase(.active)
        let driver = ScriptDriver(rig)
        await rig.connect(speed: 0)
        rig.session.enableNavigate(Self.config(after: .milliseconds(400), autoStop: .milliseconds(300)))
        let obd = try #require(rig.session.navigateGeneration)
        #expect(rig.session.noOBDStartArmedAt == nil, "the link polls")
        await driver.drive(0..<3, runStart: 0, parked: true)
        #expect(await NavigationRestoreSessionTests.ingested(service, obd, driver.sent))
        if background { rig.session.handleScenePhase(.background) }
        rig.link.state = .idle
        #expect(await eventually(5) { rig.session.navigateState == .off })
        #expect(await R.ended(service, obd))
        await restore.store.drain()
        #expect(try restore.saved().restoreClass == .parked, "auto-stop: engine off, last OBD 0")
        if background {
            try await Task.sleep(for: .milliseconds(900))
            #expect(rig.session.navigateState == .off && rig.session.noOBDStartArmedAt == nil)
            #expect(!rig.tee.feeds.contains { $0.noOBD })
            rig.session.handleScenePhase(.active)
        }
        let noOBD = try await Self.noOBDRun(rig)
        #expect(await R.wait { await service.lastRestoreGeneration == noOBD })
        if case .restored = await service.lastRestore {} else {
            Issue.record("not restored: \(String(describing: await service.lastRestore))")
        }
        rig.session.disableNavigate()
        #expect(await R.ended(service, noOBD))
    }

    // MARK: Stop

    @Test("User Stop ends the no-OBD run and it does not restart: not after the window, not on inactive → active; it re-arms after background → active, or when an adapter reaches polling")
    func userStopDoesNotRestart() async throws {
        let rig = Self.rig()
        rig.session.enableNavigate(Self.config())
        let first = try await Self.noOBDRun(rig)
        rig.session.stopNoOBDNavigate()
        #expect(rig.session.navigateState == .off && rig.session.noOBDStoppedByUser)
        #expect(rig.session.noOBDStartArmedAt == nil && rig.session.noOBDNavigation == nil)
        #expect(rig.idle.values.last == false)
        #expect(await R.ended(rig.tee.service, first))
        try await Task.sleep(for: .milliseconds(800))
        #expect(rig.session.navigateState == .off)
        rig.session.handleScenePhase(.inactive)
        rig.session.handleScenePhase(.active)
        try await Task.sleep(for: .milliseconds(800))
        #expect(rig.session.navigateState == .off && rig.session.noOBDStoppedByUser, "inactive is not the background")

        rig.session.handleScenePhase(.background)
        #expect(rig.session.noOBDStoppedByUser && rig.session.noOBDStartArmedAt == nil)
        rig.session.handleScenePhase(.active)
        #expect(!rig.session.noOBDStoppedByUser && rig.session.noOBDStartArmedAt != nil)
        let second = try await Self.noOBDRun(rig)
        #expect(second > first)

        // Stop again; then an adapter polls: the OBD run, and the stop no
        // longer holds once that run has ended.
        rig.session.stopNoOBDNavigate()
        rig.link.state = .polling(protocolNumber: "A6", voltage: 12.4)
        #expect(await eventually(5) { Self.isOBDRun(rig.session.navigateState) })
        #expect(!rig.session.noOBDStoppedByUser)
        // Stop does nothing to an OBD run.
        rig.session.stopNoOBDNavigate()
        #expect(Self.isOBDRun(rig.session.navigateState) && !rig.session.noOBDStoppedByUser)
        rig.session.disableNavigate()
    }

    // MARK: Record

    @Test("Record started from a no-OBD run: the prompt-40 hand-over applies unchanged (navPrior row, the recording starts from it); after Stop the start rule brings the no-OBD run back")
    func recordFromNoOBDRun() async throws {
        let scratch = try ScratchStore()
        defer { scratch.remove() }
        let service = NavigationService()
        let rig = Self.rig(scratch.store, service: service)
        service.provideHandOver(to: rig.session)
        rig.session.enableNavigate(Self.config())
        let noOBD = try await Self.noOBDRun(rig)
        let sent = Self.drive(rig, 0..<5, runBase: rig.uptime.uptimeSeconds)
        #expect(await rig.settled(noOBD, sent))
        #expect(await eventually(5) { service.handOver.capture?.generation == noOBD })

        try await rig.session.start(mount: "", vehicle: "", allowWithoutOBD: true, calibration: .zero)
        #expect(rig.session.navigateEndedByStart == noOBD)
        #expect(rig.session.navigateState == .off && rig.session.noOBDStartArmedAt == nil)
        let recordFeed = try #require(rig.tee.feeds.last)
        #expect(recordFeed.navPrior != nil && !recordFeed.noOBD)
        #expect(await R.wait { await service.recordingsFromPrior == 1 })
        await rig.session.stop()
        let rows = try NavigationHandOverAppTests.navPriors(try recordFeed.requiredRecordingURL)
        #expect(rows.count == 1)
        let next = try await Self.noOBDRun(rig)
        #expect(next > recordFeed.generation)
        rig.session.disableNavigate()
        #expect(await R.ended(service, next))
    }

    // MARK: Save and restore

    @Test("A no-OBD run saves like any Navigate run (every interval and at its end, class moving with no OBD, never invalidated); after a relaunch the no-OBD run restores it")
    func saveAndRestore() async throws {
        let restore = RestoreScratch()
        defer { restore.remove() }
        let service = R.service(restore.store, saveInterval: .milliseconds(50))
        let rig = Self.rig(service: service)
        rig.session.enableNavigate(Self.config())
        let noOBD = try await Self.noOBDRun(rig)
        var sent = 0
        for second in 0..<3 {
            sent += Self.drive(rig, Double(second)..<Double(second + 1), runBase: NavigateRig.base)
            try await Task.sleep(for: .milliseconds(80))
        }
        #expect(await rig.settled(noOBD, sent))
        await restore.store.drain()
        #expect(restore.fileExists, "saved during the run (interval)")
        rig.session.stopNoOBDNavigate()
        #expect(await R.ended(service, noOBD))
        await restore.store.drain()
        let saved = try restore.saved()
        #expect(saved.restoreClass == .moving && saved.lastOBDSpeedKmh == nil)
        #expect(await service.savesInvalidated == 0)

        // Relaunch: a new session and service on the same store and boot, 10 s later.
        let relaunched = R.service(restore.store)
        let rig2 = Self.rig(service: relaunched)
        rig2.uptime.set(NavigateRig.base + 10)
        rig2.session.enableNavigate(Self.config())
        let next = try await Self.noOBDRun(rig2)
        #expect(await R.wait { await relaunched.lastRestoreGeneration == next })
        guard case .restored(let ageS) = await relaunched.lastRestore else {
            Issue.record("not restored: \(String(describing: await relaunched.lastRestore))")
            return
        }
        #expect(ageS > 5 && ageS < 10)
        rig2.uptime.set(NavigateRig.base + 10.02)
        rig2.source.emit([S.motion(0.02)])
        #expect(await rig2.settled(next, 1))
        #expect(await relaunched.snapshot(at: MonotonicTimestamp(seconds: 0.02)).restore.status == .unconfirmed)
        rig2.session.disableNavigate()
        #expect(await R.ended(relaunched, next))
    }

    @Test("Relaunch with a saved estimate older than 24 h: the no-OBD run refuses it and deletes it (the 24 h rule)")
    func staleSaveRefused() async throws {
        let restore = RestoreScratch()
        defer { restore.remove() }
        restore.store.save(NavigationRestoreState(
            savedAt: Date().addingTimeInterval(-25 * 3_600), bootSessionID: "another-boot", uptimeSeconds: 10,
            latitude: 0, longitude: 0, covEE: 25, covEN: 0, covNN: 25, headingDeg: 60, headingStdDeg: 3,
            converged: true, restoreClass: .moving, speedMps: 10, lastOBDSpeedKmh: nil, lastOBDAgeS: nil))
        await restore.store.drain()
        #expect(restore.fileExists)
        let service = R.service(restore.store)
        let rig = Self.rig(service: service)
        rig.session.enableNavigate(Self.config())
        let noOBD = try await Self.noOBDRun(rig)
        #expect(await R.wait { await service.lastRestoreGeneration == noOBD })
        guard case .refused = await service.lastRestore else {
            Issue.record("not refused: \(String(describing: await service.lastRestore))")
            return
        }
        await restore.store.drain()
        #expect(!restore.fileExists)
        rig.session.disableNavigate()
        #expect(await R.ended(service, noOBD))
    }

    // MARK: Pins and the UI status

    @Test("A pin is accepted in a no-OBD run (its engine applies it) and refused with no engine at all (before the run, after Stop)")
    func pinGating() async throws {
        let service = NavigationService()
        let rig = Self.rig(service: service)
        rig.session.enableNavigate(Self.config())
        #expect(rig.session.manualFixTapTime() == nil, "no run: no engine")
        #expect(rig.session.stageManualFix(latitude: 0.001, longitude: 0.001, tapT: .zero, mapSpanM: 200) == nil)
        let noOBD = try await Self.noOBDRun(rig)
        let sent = Self.drive(rig, 0..<3, runBase: rig.uptime.uptimeSeconds)
        #expect(await rig.settled(noOBD, sent))
        let p = S.position(3)
        let tapT = try #require(rig.session.manualFixTapTime())
        #expect(rig.session.stageManualFix(latitude: p.latitude, longitude: p.longitude, tapT: tapT, mapSpanM: 200) != nil)
        #expect(await eventually(5) { rig.session.pendingManualFixes.isEmpty })
        #expect(await R.wait { await service.currentCounters?.manualFixes == 1 })
        #expect(await service.snapPin(latitude: p.latitude, longitude: p.longitude, mapSpanM: 200,
                                      viewportHeightPt: 600) == .noNetwork, "no roads in this rig: the 300 m rule")
        rig.session.stopNoOBDNavigate()
        #expect(rig.session.manualFixTapTime() == nil)
        #expect(rig.session.stageManualFix(latitude: p.latitude, longitude: p.longitude, tapT: tapT, mapSpanM: 200) == nil)
    }

    @Test("noOBDNavigation: position uncertain 120 s after the last accepted fix (session uptime moved on), cleared by a pin; the speed is the engine's estimate")
    func uncertainFlagIsPublished() async throws {
        let service = NavigationService()
        let rig = Self.rig(service: service)
        rig.session.enableNavigate(Self.config())
        let noOBD = try await Self.noOBDRun(rig)
        let runBase = rig.uptime.uptimeSeconds
        let sent = Self.drive(rig, 0..<4, runBase: runBase)
        #expect(await rig.settled(noOBD, sent))
        #expect(await eventually(5) { rig.session.noOBDNavigation?.estimatedSpeedKmh != nil })
        #expect(rig.session.noOBDNavigation?.positionUncertain == false)
        let lastFix = try #require(rig.session.noOBDNavigation?.lastFixOrPinT)
        #expect(abs(lastFix.seconds - 3) < 1e-6, "the fix at 3 s")
        // The engine's own estimate at the same session time (the fake
        // uptime stands still), in km/h, at the next refresh at the latest.
        let engine = try #require(await service.snapshot().estimate?.speedMps)
        #expect(await eventually(3) { rig.session.noOBDNavigation?.estimatedSpeedKmh == engine * 3.6 },
                "published \(String(describing: rig.session.noOBDNavigation?.estimatedSpeedKmh)) km/h, engine \(engine) m/s")

        rig.uptime.set(runBase + 3 + LiveNavigationRun.positionUncertainAfterS - 1)
        try await Task.sleep(for: .milliseconds(1_300))
        #expect(rig.session.noOBDNavigation?.positionUncertain == false, "119 s: not yet")
        rig.uptime.set(runBase + 3 + LiveNavigationRun.positionUncertainAfterS + 1)
        #expect(await eventually(3) { rig.session.noOBDNavigation?.positionUncertain == true })

        let p = S.position(124)
        let tapT = try #require(rig.session.manualFixTapTime())
        #expect(rig.session.stageManualFix(latitude: p.latitude, longitude: p.longitude, tapT: tapT, mapSpanM: 200) != nil)
        #expect(await R.wait { await service.currentCounters?.manualFixes == 1 })
        #expect(await eventually(3) { rig.session.noOBDNavigation?.positionUncertain == false })
        rig.session.disableNavigate()
        #expect(await R.ended(service, noOBD))
    }
}
