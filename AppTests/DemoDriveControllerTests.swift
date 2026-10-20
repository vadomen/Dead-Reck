import DriveLoggerCore
import Foundation
import os
import Testing

@testable import DriveLogger

/// REL-DEMO part 2: the demo drive controller over the real demo pipeline
/// (bundled pack, `DemoSensorModel` sources, the simulated adapter, its own
/// session and navigation service). The app's own pipeline is a
/// `RecordingSession` over an `OBDLinkService` on `FakeBLECentral` (the
/// "real" adapter), so holding and releasing it is the production code.
/// No coordinates here.
@MainActor
@Suite("Demo drive controller (REL-DEMO)", .serialized, .timeLimit(.minutes(2)))
struct DemoDriveControllerTests {
    /// The app's pipeline and a demo controller over it.
    @MainActor
    final class Rig {
        let central = FakeBLECentral(scripts: [LinkTestSupport.benchCar()])
        let appLink: OBDLinkService
        let scratch: ScratchStore
        let appSession: RecordingSession
        let appIdle = IdleTimerSpy()
        let demoIdle = IdleTimerSpy()
        let demo: DemoDriveController

        /// Every sequenced input the demo's navigation got, by run.
        let sequenced = SequencedLog()

        init(_ label: String = #function) throws {
            appLink = LinkTestSupport.service(central)
            scratch = try ScratchStore(label)
            appSession = RecordingFixtures.session(link: appLink, sources: [FakeSource()], store: scratch.store, idle: appIdle)
            appSession.enableNavigate(NavigateConfiguration(stillCalibration: .milliseconds(50)))
            let demoIdle = demoIdle, sequenced = sequenced
            demo = DemoDriveController(
                session: appSession, link: appLink, packURL: DemoRoadPack.url(in: .main),
                options: DemoDriveController.Options(
                    linkLatency: .milliseconds(20),
                    navigate: NavigateConfiguration(stillCalibration: .milliseconds(200)),
                    setIdleTimerDisabled: { demoIdle.set($0) },
                    observeSequencedInput: { generation, input in sequenced.append(generation, input) }))
        }

        /// The app's adapter connected and polling, its Navigate running.
        func connectApp() async -> Bool {
            appLink.connect(to: FakeBLECentral.adapterID)
            return await eventually(10) { self.appLink.state.isPolling && self.appSession.navigateState != .off }
        }

        var appConnects: Int { central.calls.filter { $0 == "connect" }.count }

        func tearDown() {
            demo.stop()
            appLink.disconnect()
            scratch.remove()
        }
    }

    /// Polls an async condition on the main actor until it holds or
    /// `seconds` pass.
    func until(_ seconds: Double, _ condition: @MainActor () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(Int(seconds * 1000)))
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return await condition()
    }

    // MARK: Pipeline, and stop restores

    @Test("Start: the app's session and link are held (Navigate ended, link idle, Record refused); the demo session navigates on the simulated car with roads from the demo pack only. Stop: exactly the state before (link reconnects, a fresh Navigate session, Start allowed)")
    func startRunsTheDemoAndStopRestores() async throws {
        let rig = try Rig()
        defer { rig.tearDown() }
        #expect(await rig.connectApp())
        let appGeneration = try #require(rig.appSession.navigateGeneration)
        #expect(rig.demo.canStart && !rig.demo.showsDemoBadge && rig.demo.session == nil && rig.demo.roads == nil)

        try rig.demo.start()
        #expect(rig.demo.isRunning && rig.demo.showsDemoBadge && rig.demo.startedAt != nil)
        #expect(rig.appSession.isHeldForDemo && rig.appSession.navigateState == .off)
        #expect(rig.appSession.startBlocker == .demoDriveRunning)
        #expect(rig.appLink.isHeldForDemo && rig.appLink.state == .idle)
        #expect(rig.appIdle.values.last == false, "the app session no longer keeps the screen on")
        let demoSession = try #require(rig.demo.session)
        #expect(demoSession !== rig.appSession)
        let roads = try #require(rig.demo.roads)
        #expect(roads.lines.count > 10 && roads.route.count > 100)

        // Navigate on the simulated adapter and the demo sources.
        #expect(await eventually(15) { demoSession.navigateState == .running })
        #expect(rig.demo.link?.state.isPolling == true)
        #expect(rig.demoIdle.values == [true], "the demo keeps the screen on")
        #expect(await eventually(15) { (demoSession.live.obdSpeedKmh ?? 0) > 0 }, "the demo car drives off after its stop")
        #expect(demoSession.latestFix?.simulated == true)
        #expect((rig.demo.elapsedSeconds ?? 0) > 4)
        // The demo's navigation: estimates, and roads from the demo pack alone.
        let attached = await until(40) { await rig.demo.navigation.roadsStatus().packNames == ["demo.roadpack"] }
        #expect(attached)
        let snapshot = await AppServices.liveSnapshot(app: NavigationService(), demo: rig.demo.navigation)()
        let estimate = try #require(snapshot.estimate)
        #expect(estimate.latitude >= roads.southWest.latitude && estimate.latitude <= roads.northEast.latitude)
        #expect(estimate.longitude >= roads.southWest.longitude && estimate.longitude <= roads.northEast.longitude)
        #expect(rig.appSession.navigateState == .off && rig.appLink.state == .idle, "still held")

        rig.demo.stop()
        #expect(!rig.demo.isRunning && !rig.demo.showsDemoBadge && rig.demo.session == nil && rig.demo.link == nil)
        #expect(rig.demo.roads == nil && rig.demo.elapsedSeconds == nil && rig.demo.startedAt == nil)
        #expect(demoSession.navigateState == .off)
        #expect(rig.demoIdle.values == [true, false])
        #expect(!rig.appSession.isHeldForDemo && !rig.appLink.isHeldForDemo)
        #expect(rig.appSession.startBlocker == nil || rig.appSession.startBlocker == .obdNotReady)
        #expect(await eventually(10) { rig.appLink.state.isPolling })
        #expect(await eventually(10) { rig.appSession.navigateState != .off })
        #expect(rig.appSession.navigateGeneration != appGeneration, "a fresh Navigate session")
        #expect(rig.appSession.startBlocker == nil)
        #expect(await until(10) { await !rig.demo.navigation.hasActiveRun }, "the demo run ended")
        #expect(rig.demo.canStart)
    }

    // MARK: Nothing written

    @Test("The demo writes nothing: no file in Documents or Application Support, nothing anywhere naming its session, no sidecar, no recording, no remembered adapter outside memory")
    func writesNothing() async throws {
        await FootprintLock.shared.acquire()
        defer { FootprintLock.shared.release() }
        let rig = try Rig()
        defer { rig.tearDown() }
        let key = OBDLinkService.rememberedAdapterKey
        let standardBefore = UserDefaults.standard.string(forKey: key)
        let simulatedSuite = UserDefaults(suiteName: "DriveLogger.SimulatedOBDLink")
        let simulatedBefore = simulatedSuite?.string(forKey: key)
        let before = NavigationServiceNavigateTests.Footprint()

        try rig.demo.start()
        let demoSession = try #require(rig.demo.session)
        #expect(await eventually(15) { demoSession.navigateState == .running })
        #expect(await until(40) { await rig.demo.navigation.roadsStatus().inUse })
        #expect(await eventually(15) { (demoSession.live.obdSpeedKmh ?? 0) > 0 })
        demoSession.handleScenePhase(.background)
        demoSession.handleScenePhase(.active)
        rig.demo.stop()
        #expect(await until(10) { await !rig.demo.navigation.finished.isEmpty })

        let finished = try #require(await rig.demo.navigation.finished.last)
        #expect(finished.sidecarURL == nil && finished.sidecarBytes == 0 && finished.sidecarFailure == nil)
        #expect(finished.roadPackNames == ["demo.roadpack"])
        #expect(finished.inputs > 100)
        #expect(before.writtenSince(sessionID: finished.sessionID) == [])
        #expect(rig.scratch.files.isEmpty, "no recording")
        #expect(!FileManager.default.fileExists(atPath: FileManager.default.temporaryDirectory
            .appending(path: "DriveLogger-demo-never-written").path))
        // The demo adapter was remembered, in memory only.
        #expect(rig.demo.pipeline?.link.rememberedAdapterID == SimulatedBLECentral.adapterID)
        #expect(UserDefaults.standard.string(forKey: key) == standardBefore)
        #expect(simulatedSuite?.string(forKey: key) == simulatedBefore)
    }

    // MARK: Mutual exclusion

    @Test("Record and the demo exclude each other: Record active refuses the demo (nothing held); the demo running refuses Record, without OBD too; a second start is refused")
    func demoAndRecordExclude() async throws {
        let rig = try Rig()
        defer { rig.tearDown() }
        try await rig.appSession.start(mount: "test", vehicle: "test", allowWithoutOBD: true, calibration: .zero)
        #expect(rig.appSession.isRecordActive)
        #expect(rig.demo.startBlocker == .recordActive && !rig.demo.canStart)
        #expect(throws: DemoDriveStartBlocker.recordActive) { try rig.demo.start() }
        #expect(!rig.demo.isRunning && rig.demo.pipeline == nil)
        #expect(!rig.appSession.isHeldForDemo && !rig.appLink.isHeldForDemo)
        #expect(rig.appSession.holdForDemo() == false, "the session refuses a hold while recording")
        #expect(!rig.appSession.isHeldForDemo)
        await rig.appSession.stop()
        let files = rig.scratch.files.count
        #expect(files >= 1)

        #expect(rig.demo.canStart)
        try rig.demo.start()
        #expect(rig.appSession.startBlocker == .demoDriveRunning)
        rig.appSession.allowsRecordingWithoutOBD = true
        #expect(rig.appSession.startBlocker == .demoDriveRunning && !rig.appSession.canStart)
        await #expect(throws: RecordingStartBlocker.demoDriveRunning) {
            try await rig.appSession.start(mount: "test", vehicle: "test", allowWithoutOBD: true, calibration: .zero)
        }
        #expect(!rig.appSession.isRecordActive && rig.appSession.state == .idle && rig.appSession.isHeldForDemo)
        #expect(rig.scratch.files.count == files, "no file for the refused Start")
        #expect(throws: DemoDriveStartBlocker.running) { try rig.demo.start() }
        #expect(StartBlockerNotice(.demoDriveRunning)?.offersRecordWithoutOBD == false)

        rig.demo.stop()
        #expect(rig.appSession.startBlocker == nil, "recording without OBD is allowed again")
    }

    // MARK: The real adapter waits

    @Test("While the demo runs a real adapter cannot take over: Bluetooth back on, state restoration and a pick in Settings connect nothing; after Stop the adapter reconnects")
    func realAdapterWaits() async throws {
        let rig = try Rig()
        defer { rig.tearDown() }
        #expect(await rig.connectApp())
        let connects = rig.appConnects
        try rig.demo.start()
        #expect(await eventually { rig.central.calls.last == "cancel" })
        let demoSession = try #require(rig.demo.session)

        rig.central.send(.availability(.unavailable("off"), uptime: FakeBLECentral.now))
        rig.central.send(.availability(.poweredOn, uptime: FakeBLECentral.now))
        rig.central.send(.restored([FakeBLECentral.adapterID], uptime: FakeBLECentral.now))
        rig.appLink.connect(to: FakeBLECentral.adapterID)
        #expect(await eventually(15) { demoSession.navigateState == .running })
        try await Task.sleep(for: .milliseconds(300))
        #expect(rig.appConnects == connects, "nothing connected the real adapter")
        #expect(rig.appLink.state == .idle && rig.appLink.isHeldForDemo)
        #expect(rig.appSession.navigateState == .off && rig.appSession.navigateGeneration == nil)
        #expect(rig.demo.isRunning && demoSession.navigateState == .running, "the demo keeps its session")

        rig.demo.stop()
        #expect(await eventually(10) { rig.appLink.state.isPolling })
        #expect(rig.appConnects == connects + 1)
        #expect(await eventually(10) { rig.appSession.navigateState != .off })
    }

    @Test("Disconnect or forget during the hold: nothing reconnects after it (forget also forgets); a pick during the hold connects after it")
    func holdKeepsTheUsersChoice() async throws {
        let central = FakeBLECentral(scripts: [LinkTestSupport.benchCar()])
        let link = LinkTestSupport.service(central)
        defer { link.disconnect() }
        link.connect(to: FakeBLECentral.adapterID)
        #expect(await eventually { link.state.isPolling })
        link.holdForDemo()
        link.holdForDemo()
        #expect(link.isHeldForDemo && link.state == .idle)
        link.disconnect()
        link.releaseDemoHold()
        try await Task.sleep(for: .milliseconds(200))
        #expect(!link.isHeldForDemo && link.state == .idle && link.bleState == .idle)
        // Nothing was wanted at the hold; a pick during it connects after.
        link.holdForDemo()
        link.connect(to: FakeBLECentral.adapterID)
        try await Task.sleep(for: .milliseconds(200))
        #expect(link.state == .idle)
        link.releaseDemoHold()
        #expect(await eventually { link.state.isPolling })
        link.releaseDemoHold()
        // Forget during the hold: nothing reconnects, nothing remembered.
        link.holdForDemo()
        link.forget()
        link.releaseDemoHold()
        try await Task.sleep(for: .milliseconds(200))
        #expect(link.state == .idle && link.rememberedAdapterID == nil)
    }

    @Test("The hold stops the app session's map-only position feed (its sensors all stop) and the release brings it back while active")
    func holdStopsThePositionFeed() throws {
        let scratch = try ScratchStore()
        defer { scratch.remove() }
        let display = FakeDisplayLocation()
        let link = FakeLink()
        link.state = .idle
        let session = RecordingSession(
            link: link, sources: [FakeSource()], displayLocation: display, store: scratch.store,
            diskSpace: FakeDisk(RecordingFixtures.roomy), app: RecordingFixtures.app, device: RecordingFixtures.device,
            setIdleTimerDisabled: { _ in }, beginBackgroundTask: { _ in {} })
        session.handleScenePhase(.active)
        #expect(display.isRunning)
        #expect(session.holdForDemo())
        #expect(!display.isRunning)
        session.handleScenePhase(.inactive)
        session.handleScenePhase(.active)
        #expect(!display.isRunning, "still held")
        session.releaseDemoHold()
        #expect(display.isRunning)
    }

    // MARK: Determinism

    @Test("Deterministic: two demo starts feed their navigation the same session ID (so seed) and, over the first 8 s of live scheduling, exactly the canonical inputs; roads attach inline from the demo pack")
    func twoStartsAreIdentical() async throws {
        let rig = try Rig()
        defer { rig.tearDown() }
        let horizon = MonotonicTimestamp(seconds: 8)
        var generations: [Int] = []
        for _ in 0..<2 {
            try rig.demo.start()
            let session = try #require(rig.demo.session)
            #expect(await eventually(15) { session.navigateGeneration != nil })
            let generation = try #require(session.navigateGeneration)
            generations.append(generation)
            #expect(await eventually(20) { (rig.sequenced.inputs(generation).last?.timestamp ?? .zero) > horizon })
            #expect(await until(10) { await rig.demo.navigation.roadsStatus().packNames == ["demo.roadpack"] })
            rig.demo.stop()
            #expect(await until(10) { await !rig.demo.navigation.hasActiveRun })
        }
        let finished = await rig.demo.navigation.finished
        #expect(finished.count == 2)
        #expect(finished.allSatisfy { $0.sessionID == DemoSensorModel.sessionID })
        #expect(finished.allSatisfy { $0.roadPackNames == ["demo.roadpack"] })
        let model = try #require(rig.demo.pipeline?.model)
        let canonical = model.canonicalInputs(until: 8)
        let first = rig.sequenced.inputs(generations[0]).filter { $0.timestamp <= horizon }
        let second = rig.sequenced.inputs(generations[1]).filter { $0.timestamp <= horizon }
        #expect(first.count == canonical.count)
        #expect(first == canonical)
        #expect(second == canonical)
    }

    // MARK: Lifecycle

    @Test("Backgrounding stops the demo and releases the app's pipeline; inactive and active change nothing")
    func backgroundStops() async throws {
        let rig = try Rig()
        defer { rig.tearDown() }
        try rig.demo.start()
        rig.demo.handleScenePhase(.inactive)
        rig.demo.handleScenePhase(.active)
        #expect(rig.demo.isRunning && rig.appSession.isHeldForDemo)
        rig.demo.handleScenePhase(.background)
        #expect(!rig.demo.isRunning && !rig.appSession.isHeldForDemo && !rig.appLink.isHeldForDemo)
        // And it starts again on the same pipeline.
        let pipeline = try #require(rig.demo.pipeline)
        try rig.demo.start()
        #expect(rig.demo.pipeline === pipeline && rig.demo.session === pipeline.session)
        #expect(await eventually(15) { pipeline.session.navigateState == .running })
    }

    @Test("Without the demo pack the demo is unavailable and nothing is held")
    func missingPack() throws {
        let scratch = try ScratchStore()
        defer { scratch.remove() }
        let link = FakeLink()
        let session = RecordingFixtures.session(link: link, store: scratch.store)
        let demo = DemoDriveController(session: session, link: link, packURL: nil)
        #expect(demo.canStart)
        #expect(throws: DemoDriveStartBlocker.unavailable(reason: DemoDrivePipeline.Failure.packMissing.description)) {
            try demo.start()
        }
        #expect(!demo.isRunning && !session.isHeldForDemo)
        #expect(demo.startBlocker == .unavailable(reason: DemoDrivePipeline.Failure.packMissing.description))
    }
}

/// Sequenced inputs by run generation, appended from the demo's relay task.
final class SequencedLog: Sendable {
    private let state = OSAllocatedUnfairLock<[Int: [NavigationInput]]>(initialState: [:])

    func append(_ generation: Int, _ input: NavigationInput) {
        state.withLock { $0[generation, default: []].append(input) }
    }

    func inputs(_ generation: Int) -> [NavigationInput] {
        state.withLock { $0[generation] ?? [] }
    }
}
