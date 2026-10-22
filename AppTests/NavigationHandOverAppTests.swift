import DriveLoggerCore
import Foundation
import Testing

@testable import DriveLogger

// Prompt 40, app side: Record's Start takes over the running Navigate
// estimate. The navigation service publishes Navigate's estimate at each
// engine step (`NavigateHandOver`); the session's `navPriorProvider`
// (`NavigationService.provideHandOver(to:)`) writes it as the recording's
// `navPrior` row, and the recording's run starts from it at once.
// `NavigateRig` and `ScriptDriver` from RecordingSessionNavigateTests.swift
// and NavigationRestoreAppTests.swift; the track is synthetic, near (0, 0).

@Suite("Navigate → Record hand-over (prompt 40)", .serialized)
@MainActor
struct NavigationHandOverAppTests {
    typealias R = RestoreScript
    typealias S = NavigationServiceNavigateTests

    static func ingested(_ service: NavigationService, _ generation: Int, _ count: Int) async -> Bool {
        await NavigationRestoreSessionTests.ingested(service, generation, count)
    }

    static func navPriors(_ url: URL) throws -> [NavPriorSample] {
        try LogFileReader(url: url).compactMap { if case .navPrior(let s) = $0.payload { s } else { nil } }
    }

    /// Major-axis σ of a snapshot's ellipse, metres (95 % semi-axis / √5.991).
    static func sigma(_ snapshot: NavigationSnapshot) -> Double {
        (snapshot.estimate?.ellipse.semiMajorM ?? .infinity) / ErrorEllipse.chiSquare95.squareRoot()
    }

    @Test("Navigate (converged) → Record: the navPrior row is Navigate's estimate at its last step; Record starts from it at its first input: converged kept, heading and position within the grown σ, confirmed as a hand-over; no Finding-your-position or Restored line; GPS gone after the switch and the position carries on; the save is never invalidated")
    func convergedHandOverKeepsTheEstimate() async throws {
        let scratch = try ScratchStore()
        defer { scratch.remove() }
        let restore = RestoreScratch()
        defer { restore.remove() }
        let service = R.service(restore.store, saveInterval: .milliseconds(100))
        let rig = NavigateRig(store: scratch.store, service: service)
        service.provideHandOver(to: rig.session)
        let driver = ScriptDriver(rig)
        await rig.connect(speed: 36)
        rig.session.enableNavigate(RecordingSessionNavigateTests.quick)
        let navigate = try #require(rig.session.navigateGeneration)
        await driver.drive(0..<3, runStart: 0)
        #expect(await Self.ingested(service, navigate, driver.sent))
        let published = try #require(service.handOver.capture)
        #expect(published.generation == navigate)
        let navigateLast = await service.snapshot(at: MonotonicTimestamp(seconds: published.state.uptimeSeconds - NavigateRig.base))
        #expect(navigateLast.converged)
        let headingAtSwitch = try #require(navigateLast.headingDeg)

        // Record at script 3 s; no fix from here on (jammed).
        try await rig.session.start(mount: "m", vehicle: "v", allowWithoutOBD: false, calibration: .zero)
        let record = try #require(rig.session.currentGeneration)
        let url = try #require(rig.session.currentFile)
        #expect(rig.session.navigateEndedByStart == navigate)
        let feed = try #require(rig.tee.feeds.last)
        let row = try #require(feed.navPrior)
        #expect(row.source == "navigate" && row.converged && row.restoreClass == "moving")
        let ageAtStart = -row.estimateT.seconds
        #expect(ageAtStart >= 0 && ageAtStart < 0.5, "Navigate's last step, \(ageAtStart) s before Record's Start")
        #expect(NavPriorSample(handOver: published.state, clock: feed.clock) == row, "the published capture, on Record's clock")

        driver.reset()
        await driver.step(3, runStart: 3, fixes: false)
        #expect(await Self.ingested(service, record, driver.sent))
        #expect(await service.recordingsFromPrior == 1)
        let first = await service.snapshot(at: MonotonicTimestamp(seconds: 0.18))
        #expect(first.restore.status == .confirmed && first.restore.reason == .handOver)
        #expect(first.converged, "converged carries over")
        #expect(PositionStatus.line(NavDisplay(first)) == nil, "no Finding your position line")
        #expect(RestoreStatus.line(RestoreDisplay(first.restore, run: record)) == nil, "no Restored line")
        #expect(abs(R.angleDifference(try #require(first.headingDeg), headingAtSwitch)) < 3)
        let sigma = Self.sigma(first)
        let truth = S.position(3.18)
        #expect(S.distanceM(first, truth.latitude, truth.longitude) < 2 * sigma)
        let fromNavigate = S.distanceM(first, try #require(navigateLast.latitude), try #require(navigateLast.longitude))
        let carried = S.speedMS * (3.18 - (published.state.uptimeSeconds - NavigateRig.base))
        #expect(abs(fromNavigate - carried) < sigma, "dead-reckoned on from Navigate's estimate: \(fromNavigate) m vs \(carried) m")
        print("Prompt 40 app hand-over: estimate \(String(format: "%.2f", ageAtStart)) s old at Start; first Record estimate "
              + String(format: "%.1f m from the truth, σ %.1f m, heading %.1f° vs %.1f°", S.distanceM(first, truth.latitude, truth.longitude),
                       sigma, first.headingDeg ?? .nan, headingAtSwitch))

        // 5 s more without GPS: still converged, on the track, never reseeded.
        await driver.drive(3.2..<8, runStart: 3, fixes: false)
        #expect(await Self.ingested(service, record, driver.sent))
        let later = await service.snapshot(at: MonotonicTimestamp(seconds: 4.9))
        let laterTruth = S.position(7.9)
        #expect(later.converged && S.distanceM(later, laterTruth.latitude, laterTruth.longitude) < 2 * Self.sigma(later))
        #expect(await service.currentCounters?.reseeds == 0)
        // R77.4-3 with a hand-over: the run has an estimate, the save is Record's.
        await service.flush()
        #expect(await service.savesInvalidated == 0)
        let saved = try restore.saved()
        #expect(saved.uptimeSeconds > NavigateRig.base + 7.5, "Record's own save at its last step: \(saved.uptimeSeconds - NavigateRig.base) s")

        await rig.session.stop()
        #expect(try Self.navPriors(url) == [row], "exactly the feed's sample, once")
        rig.session.disableNavigate()
    }

    @Test("Navigate without an estimate (no fix yet) → Record: no navPrior row, a fresh engine as before")
    func noEstimateNoRow() async throws {
        let scratch = try ScratchStore()
        defer { scratch.remove() }
        let service = R.service(nil)
        let rig = NavigateRig(store: scratch.store, service: service)
        service.provideHandOver(to: rig.session)
        let driver = ScriptDriver(rig)
        await rig.connect(speed: 36)
        rig.session.enableNavigate(RecordingSessionNavigateTests.quick)
        let navigate = try #require(rig.session.navigateGeneration)
        await driver.drive(0..<2, runStart: 0, fixes: false)
        #expect(await Self.ingested(service, navigate, driver.sent))
        #expect(service.handOver.capture == nil)

        try await rig.session.start(mount: "m", vehicle: "v", allowWithoutOBD: false, calibration: .zero)
        let record = try #require(rig.session.currentGeneration)
        let url = try #require(rig.session.currentFile)
        #expect(rig.session.navigateEndedByStart == navigate)
        #expect(rig.tee.feeds.last?.navPrior == nil)
        driver.reset()
        await driver.drive(2..<3, runStart: 2, fixes: false)
        #expect(await Self.ingested(service, record, driver.sent))
        let snapshot = await service.snapshot(at: MonotonicTimestamp(seconds: 0.9))
        #expect(!snapshot.initialized && snapshot.restore.status == .none)
        #expect(await service.recordingsFromPrior == 0)
        await rig.session.stop()
        #expect(try Self.navPriors(url).isEmpty)
        rig.session.disableNavigate()
    }

    @Test("A Navigate run that ended before Record's Start (Navigate off) is never handed over, though its capture is still held (Start ended no run: the nil navigateEndedByStart guard; the generation check is staleCaptureIsNotHandedOver)")
    func endedNavigateIsNotHandedOver() async throws {
        let scratch = try ScratchStore()
        defer { scratch.remove() }
        let service = R.service(nil)
        let rig = NavigateRig(store: scratch.store, service: service)
        service.provideHandOver(to: rig.session)
        let driver = ScriptDriver(rig)
        await rig.connect(speed: 36)
        rig.session.enableNavigate(RecordingSessionNavigateTests.quick)
        let navigate = try #require(rig.session.navigateGeneration)
        await driver.drive(0..<3, runStart: 0)
        #expect(await Self.ingested(service, navigate, driver.sent))
        rig.session.disableNavigate()
        #expect(await R.ended(service, navigate))
        #expect(service.handOver.capture?.generation == navigate)

        try await rig.session.start(mount: "m", vehicle: "v", allowWithoutOBD: false, calibration: .zero)
        let url = try #require(rig.session.currentFile)
        #expect(rig.session.navigateEndedByStart == nil)
        #expect(rig.tee.feeds.last?.navPrior == nil)
        await rig.session.stop()
        #expect(try Self.navPriors(url).isEmpty)
    }

    @Test("R78.1-B1: Navigate g1 converges → Record g2 → Navigate g3 with no estimate (no fix, no restore) → Record g4: the slot still holds g1's capture, but Start ended g3, so no navPrior row and Record starts fresh")
    func staleCaptureIsNotHandedOver() async throws {
        let scratch = try ScratchStore()
        defer { scratch.remove() }
        let service = R.service(nil)
        let rig = NavigateRig(store: scratch.store, service: service)
        service.provideHandOver(to: rig.session)
        let driver = ScriptDriver(rig)
        await rig.connect(speed: 36)
        rig.session.enableNavigate(RecordingSessionNavigateTests.quick)

        // g1: converged on fixes, published.
        let first = try #require(rig.session.navigateGeneration)
        await driver.drive(0..<3, runStart: 0)
        #expect(await Self.ingested(service, first, driver.sent))
        #expect(service.handOver.capture?.generation == first)

        // g2: Record takes g1's estimate over, and stops.
        try await rig.session.start(mount: "m", vehicle: "v", allowWithoutOBD: false, calibration: .zero)
        let firstRecord = try #require(rig.session.currentGeneration)
        #expect(rig.session.navigateEndedByStart == first)
        #expect(rig.tee.feeds.last?.navPrior != nil, "g1 handed over to g2")
        driver.reset()
        await driver.step(3, runStart: 3, fixes: false)
        #expect(await Self.ingested(service, firstRecord, driver.sent))
        #expect(await service.recordingsFromPrior == 1)
        await rig.session.stop()
        #expect(await R.ended(service, firstRecord))

        // g3: Navigate resumes after the stop; no fix, no saved estimate: never initialised, never publishes.
        let third = try #require(rig.session.navigateGeneration)
        #expect(third > firstRecord)
        driver.reset()
        await driver.drive(3.2..<5, runStart: 3.2, fixes: false)
        #expect(await Self.ingested(service, third, driver.sent))
        #expect(!(await service.snapshot(at: MonotonicTimestamp(seconds: 1.7))).initialized)
        #expect(service.handOver.capture?.generation == first, "the slot still holds g1's capture: only the generation check stands between it and g4")

        // g4: Start ended g3, which had no estimate: no row, a fresh engine.
        try await rig.session.start(mount: "m", vehicle: "v", allowWithoutOBD: false, calibration: .zero)
        let record = try #require(rig.session.currentGeneration)
        let url = try #require(rig.session.currentFile)
        #expect(rig.session.navigateEndedByStart == third)
        let feed = try #require(rig.tee.feeds.last)
        #expect(feed.generation == record)
        #expect(feed.navPrior == nil, "g1's stale estimate is not handed over")
        driver.reset()
        await driver.drive(5..<6, runStart: 5, fixes: false)
        #expect(await Self.ingested(service, record, driver.sent))
        let snapshot = await service.snapshot(at: MonotonicTimestamp(seconds: 0.9))
        #expect(!snapshot.initialized && snapshot.restore.status == .none)
        #expect(await service.recordingsFromPrior == 1, "only g2 started from a prior")
        await rig.session.stop()
        #expect(try Self.navPriors(url).isEmpty)
        rig.session.disableNavigate()
    }

    @Test("Navigate is itself an unconfirmed restore → Record: the row says not converged, so Record stays unconfirmed (Restored line) instead of being confirmed unseen")
    func unconfirmedRestoreStaysUnconfirmed() async throws {
        let scratch = try ScratchStore()
        defer { scratch.remove() }
        let restore = RestoreScratch()
        defer { restore.remove() }
        // Parked 10 min ago at the start of the track, converged.
        let saved = NavigationRestoreState(
            savedAt: Date().addingTimeInterval(-600), bootSessionID: R.boot, uptimeSeconds: NavigateRig.base - 600,
            latitude: 0, longitude: 0, covEE: 25, covEN: 0, covNN: 25, headingDeg: S.courseDeg, headingStdDeg: 2,
            converged: true, restoreClass: .parked, speedMps: 0, lastOBDSpeedKmh: 0, lastOBDAgeS: 1)
        try restore.write(try saved.encoded())
        let service = R.service(restore.store)
        let rig = NavigateRig(store: scratch.store, service: service)
        service.provideHandOver(to: rig.session)
        let driver = ScriptDriver(rig)
        await rig.connect(speed: 0)
        rig.session.enableNavigate(RecordingSessionNavigateTests.quick)
        let navigate = try #require(rig.session.navigateGeneration)
        #expect(await R.wait { await service.lastRestoreGeneration == navigate })
        await driver.drive(0..<2, runStart: 0, fixes: false, parked: true)
        #expect(await Self.ingested(service, navigate, driver.sent))
        let navigateNow = await service.snapshot(at: MonotonicTimestamp(seconds: 1.9))
        #expect(navigateNow.restore.status == .unconfirmed && navigateNow.converged)
        #expect(service.handOver.capture?.state.converged == false, "published as not converged while unconfirmed")

        try await rig.session.start(mount: "m", vehicle: "v", allowWithoutOBD: false, calibration: .zero)
        let record = try #require(rig.session.currentGeneration)
        let row = try #require(rig.tee.feeds.last?.navPrior)
        #expect(!row.converged)
        driver.reset()
        await driver.step(2, runStart: 2, fixes: false, parked: true)
        #expect(await Self.ingested(service, record, driver.sent))
        let first = await service.snapshot(at: MonotonicTimestamp(seconds: 0.18))
        #expect(first.initialized && first.restore.status == .unconfirmed)
        #expect(RestoreStatus.line(RestoreDisplay(first.restore, run: record)) != nil, "the Restored line stays")
        await rig.session.stop()
        rig.session.disableNavigate()
    }

    @Test("Roads: the hand-over Record run asks for roads at its first input and attaches the pack Navigate had (the library's verified candidates, no new verification)")
    func handOverRunAttachesRoadsAtOnce() async throws {
        await FootprintLock.shared.acquire()
        defer { FootprintLock.shared.release() }
        let scratch = try ScratchStore()
        defer { scratch.remove() }
        let dir = try RoadPackFixture.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try RoadPackFixture.write(try RoadPackFixture.data(), named: "fixture.roadpack", in: dir)
        let library = RoadPackLibrary(source: RoadPackLibrary.directorySource(dir), cacheURL: nil)
        let service = NavigationService(library: library)
        let rig = NavigateRig(store: scratch.store, service: service)
        service.provideHandOver(to: rig.session)
        let driver = ScriptDriver(rig)
        await rig.connect(speed: 36)
        rig.session.enableNavigate(RecordingSessionNavigateTests.quick)
        let navigate = try #require(rig.session.navigateGeneration)
        await driver.drive(0..<3, runStart: 0)
        #expect(await Self.ingested(service, navigate, driver.sent))
        #expect(await NavigationRestoreAppTestsWait.until { await service.roadsStatus().inUse })
        let navigateRoads = await service.roadsStatus()
        let builtBefore = await service.networksBuilt

        try await rig.session.start(mount: "m", vehicle: "v", allowWithoutOBD: false, calibration: .zero)
        let record = try #require(rig.session.currentGeneration)
        #expect(rig.tee.feeds.last?.navPrior != nil)
        driver.reset()
        await driver.step(3, runStart: 3, fixes: false)
        #expect(await Self.ingested(service, record, driver.sent))
        #expect(await NavigationRestoreAppTestsWait.until {
            let status = await service.roadsStatus()
            return await service.currentGeneration == record && status.inUse
        })
        let status = await service.roadsStatus()
        #expect(status.packNames == navigateRoads.packNames && status.roadSetHashPrefix == navigateRoads.roadSetHashPrefix)
        let activeAt = try #require(status.activeAtSessionS)
        #expect(activeAt < 0.2, "attached at Record's first inputs: \(activeAt) s")
        #expect(await service.networksBuilt == builtBefore + 1, "one selection for the new run")
        print("Prompt 40 app roads: Record's roads active at session \(String(format: "%.2f", activeAt)) s (Navigate's at \(navigateRoads.activeAtSessionS ?? .nan) s)")
        await rig.session.stop()
        rig.session.disableNavigate()
    }
}

// R78.1-B1: the slot itself, without a session.
@Suite("NavigateHandOver slot (prompt 40)")
struct NavigateHandOverTests {
    typealias R = RestoreScript

    @Test("prior(navigate:) hands over only the capture of the generation asked for: g1's capture is nil for g3, and for nil")
    func priorMatchesTheGeneration() throws {
        let handOver = NavigateHandOver()
        let clock = R.clock()
        let g1 = R.state(ageS: 5, northM: 10)
        handOver.publish(generation: 1, state: g1)
        #expect(handOver.capture == NavigateHandOver.Capture(generation: 1, state: g1))
        #expect(handOver.prior(navigate: 3, clock: clock) == nil)
        #expect(handOver.prior(navigate: nil, clock: clock) == nil)
        let row = try #require(handOver.prior(navigate: 1, clock: clock))
        #expect(row == NavPriorSample(handOver: g1, clock: clock))
        #expect(row.estimateT.seconds == -5, "on the asking clock: the estimate's uptime, 5 s before its reference")
    }

    @Test("An older generation's publish (a run still draining) never replaces a newer one's capture; once the newest has published nil, a late older capture fills the slot but is still not handed over for the newest")
    func olderPublishDoesNotReplaceNewer() throws {
        let handOver = NavigateHandOver()
        let clock = R.clock()
        let g1 = R.state(ageS: 5, northM: 10), g3 = R.state(ageS: 1, northM: 30)
        handOver.publish(generation: 1, state: g1)
        handOver.publish(generation: 3, state: g3)
        handOver.publish(generation: 1, state: g1)
        #expect(handOver.capture == NavigateHandOver.Capture(generation: 3, state: g3))
        #expect(handOver.prior(navigate: 3, clock: clock) == NavPriorSample(handOver: g3, clock: clock))
        #expect(handOver.prior(navigate: 1, clock: clock) == nil)
        handOver.publish(generation: 1, state: nil)
        #expect(handOver.capture?.generation == 3, "an older nil does not clear it either")

        // g3 loses its estimate (rejected prior): the slot empties.
        handOver.publish(generation: 3, state: nil)
        #expect(handOver.capture == nil)
        #expect(handOver.prior(navigate: 3, clock: clock) == nil)
        handOver.publish(generation: 1, state: g1)
        #expect(handOver.capture?.generation == 1)
        #expect(handOver.prior(navigate: 3, clock: clock) == nil, "g1's late capture is not g3's")
    }
}

/// A bounded wait for an async condition (10 s).
@MainActor
enum NavigationRestoreAppTestsWait {
    static func until(_ condition: () async -> Bool) async -> Bool {
        await RestoreScript.wait(10, condition)
    }
}
