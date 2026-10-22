import DriveLoggerCore
import Foundation
import Testing

@testable import DriveLogger

// UX-20, app side: the saved estimate's store, the navigation service's
// saves and Navigate's restore, and the Record-stop hand-over through the
// session. Synthetic positions a few kilometres from (0, 0), synthetic
// clocks and boot IDs; every store lives in its own temporary directory, so
// nothing touches the app's container. What the phone does (file
// protection while locked, a kill in the background, the boot session
// sysctl) is in docs/PLAN.md §6.

/// A restore store in a fresh temporary directory.
struct RestoreScratch {
    let directory: URL
    let store: NavigationRestoreStore

    init() {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("drivelogger-restore-\(UUID().uuidString)", isDirectory: true)
        store = NavigationRestoreStore(directory: directory)
    }

    var fileURL: URL { store.fileURL }
    var fileExists: Bool { FileManager.default.fileExists(atPath: fileURL.path) }

    func write(_ data: Data) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: fileURL)
    }

    /// The file as Core decodes it.
    func saved() throws -> NavigationRestoreState {
        try NavigationRestoreState.decode(Data(contentsOf: fileURL))
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }
}

/// Shared script pieces.
enum RestoreScript {
    typealias S = NavigationServiceNavigateTests
    static let boot = "boot-test"
    static let referenceUptime = 5_000.0
    static let wallStart = Date(timeIntervalSince1970: 1_800_000_000)

    /// A state saved `ageS` before `wallStart` at local (0, 0) + `northM`,
    /// parked, heading 60° ± 3°. Same boot unless `boot` says otherwise.
    static func state(ageS: Double, boot: String? = boot, northM: Double = 0,
                      restoreClass: NavigationRestoreClass = .parked) -> NavigationRestoreState {
        NavigationRestoreState(
            savedAt: wallStart.addingTimeInterval(-ageS), bootSessionID: boot,
            uptimeSeconds: max(0, referenceUptime - ageS), latitude: northM / 111_320, longitude: 0,
            covEE: 25, covEN: 0, covNN: 25, headingDeg: 60, headingStdDeg: 3, converged: true,
            restoreClass: restoreClass, speedMps: 0, lastOBDSpeedKmh: 0, lastOBDAgeS: 1)
    }

    /// A fresh header (unique `sessionID`: its seed).
    static func header() -> LogHeader {
        LogHeader(
            sessionID: UUID(), startedAt: wallStart, referenceUptimeSeconds: referenceUptime,
            app: AppIdentity(name: "DriveLogger", version: "0.0", build: "7"),
            device: DeviceIdentity(model: "test", systemName: "iOS", systemVersion: "17"))
    }

    /// A clock that started at `wallStart` and reads `nowS` seconds.
    static func clock(nowS: Double = 0) -> SessionClock {
        SessionClock(referenceUptimeSeconds: referenceUptime, wallClockStart: wallStart,
                     source: FixedUptimeSource(uptimeSeconds: referenceUptime + nowS))
    }

    static func feed(_ generation: Int, recordingIn directory: URL? = nil, nowS: Double = 0,
                     runEnd: NavigationRunEnd = NavigationRunEnd(), header: LogHeader = header())
        -> (RecordingNavigationFeed, NavigationTap) {
        let tap = NavigationTap()
        let output: RecordingNavigationFeed.Output
        if let directory {
            let url = directory.appendingPathComponent("Drive_restore\(generation).jsonl.gz")
            output = .recording(recordingURL: url, sidecarURL: LogStore.navSidecarURL(for: url))
        } else {
            output = .navigateOnly
        }
        return (RecordingNavigationFeed(generation: generation, header: header, clock: clock(nowS: nowS),
                                        output: output, tap: tap, runEnd: runEnd), tap)
    }

    static func service(_ store: NavigationRestoreStore?, saveInterval: Duration = .seconds(3_600),
                        boot: String? = boot) -> NavigationService {
        NavigationService(restoreStore: store, saveInterval: saveInterval, bootSessionID: { boot })
    }

    /// Standing still at local (0, 0) + `northM` for `seconds`: motion at
    /// 50 Hz, OBD 0 at 5 Hz.
    @MainActor
    static func parked(_ range: ClosedRange<Double>) -> [LogEvent] {
        var out: [LogEvent] = []
        var k = Int((range.lowerBound * 50).rounded()) + 1
        while Double(k) / 50 <= range.upperBound + 1e-9 {
            let t = Double(k) / 50
            out.append(S.motion(t))
            if k % 10 == 5 { out.append(S.obd(t, kmh: 0)) }
            k += 1
        }
        return out
    }

    /// A fix at `t` (also its own time) `northM` north of (0, 0): GNSS (speed
    /// 0, valid) or Wi-Fi (no speed, no course).
    static func fix(_ t: Double, northM: Double, wifi: Bool, accuracy: Double) -> LogEvent {
        LogEvent(timestamp: MonotonicTimestamp(seconds: t), payload: .location(LocationSample(
            latitude: northM / 111_320, longitude: 0, altitude: 0, horizontalAccuracy: accuracy,
            verticalAccuracy: -1, speed: wifi ? -1 : 0, speedAccuracy: wifi ? -1 : 0.3, course: -1,
            courseAccuracy: -1, receivedT: MonotonicTimestamp(seconds: t), ageS: 0)))
    }

    @MainActor
    static func wait(_ seconds: Double = 30, _ condition: () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(Int(seconds * 1000)))
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return await condition()
    }

    /// Records `events` into `tap` and waits until `service`'s current run
    /// has ingested `total` inputs.
    @MainActor
    static func send(_ events: [LogEvent], to tap: NavigationTap, service: NavigationService, total: Int) async -> Bool {
        for event in events { tap.record(event) }
        return await wait { await service.snapshot(at: .zero).stats.inputs == total }
    }

    /// `a − b` wrapped to (−180°, 180°].
    static func angleDifference(_ a: Double, _ b: Double) -> Double {
        var d = (a - b).truncatingRemainder(dividingBy: 360)
        if d > 180 { d -= 360 }
        if d <= -180 { d += 360 }
        return d
    }

    /// A restore scenario: the car moved while parked, the first fix's kind.
    struct Scenario: Sendable, CustomTestStringConvertible {
        var moved: Bool
        var wifi: Bool
        var testDescription: String { "\(moved ? "moved 2 km" : "not moved"), \(wifi ? "Wi-Fi" : "GNSS") fix" }
    }

    @MainActor
    static func ended(_ service: NavigationService, _ generation: Int) async -> Bool {
        await wait { await service.finished.contains { $0.generation == generation } }
    }
}

// MARK: - Store

@Suite("Navigation restore store (UX-20)", .serialized)
struct NavigationRestoreStoreTests {
    typealias R = RestoreScript

    @Test("Save then load round-trips through Core's bytes; Application Support/NavigationRestore/estimate.json, excluded from backup, protected until first unlock")
    func roundTrip() async throws {
        let scratch = RestoreScratch()
        defer { scratch.remove() }
        #expect(await scratch.store.load() == .none)
        let state = R.state(ageS: 60)
        scratch.store.save(state)
        #expect(await scratch.store.load() == .state(state))
        #expect(try scratch.saved() == state)
        #expect(try Data(contentsOf: scratch.fileURL) == (try state.encoded()), "Core's encoding, byte for byte")
        let values = try scratch.directory.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true)
        let attributes = try FileManager.default.attributesOfItem(atPath: scratch.fileURL.path)
        if let protection = attributes[.protectionKey] as? FileProtectionType {
            // The simulator may not report it; the phone is a §6 check.
            #expect(protection == .completeUntilFirstUserAuthentication)
        }
        #expect(NavigationRestoreStore.defaultDirectory().lastPathComponent == "NavigationRestore")
        #expect(NavigationRestoreStore.defaultDirectory().deletingLastPathComponent().lastPathComponent
                == "Application Support")
        #expect(scratch.fileURL.lastPathComponent == "estimate.json")
    }

    @Test("One serial queue: a load sees every save and delete asked before it, in order")
    func ordered() async throws {
        let scratch = RestoreScratch()
        defer { scratch.remove() }
        for age in stride(from: 100.0, through: 1.0, by: -1) { scratch.store.save(R.state(ageS: age)) }
        #expect(await scratch.store.load() == .state(R.state(ageS: 1)))
        scratch.store.delete()
        #expect(await scratch.store.load() == .none)
        scratch.store.save(R.state(ageS: 7))
        await scratch.store.drain()
        #expect(scratch.fileExists)
        #expect(scratch.store.counts.saves == 101 && scratch.store.counts.saveFailures == 0)
    }

    @Test("Corrupt, truncated, unknown-version and out-of-range files are discarded and deleted")
    func unreadableIsDeleted() async throws {
        let valid = try R.state(ageS: 60).encoded()
        let text = String(decoding: valid, as: UTF8.self)
        let cases: [(Data, String)] = [
            (Data("not json".utf8), "malformed"),
            (valid.prefix(valid.count / 2), "malformed"),
            (Data(), "malformed"),
            (Data(text.replacingOccurrences(of: "\"version\":1", with: "\"version\":2").utf8), "unsupported version 2"),
            (Data(text.replacingOccurrences(of: "\"headingDeg\":60", with: "\"headingDeg\":400").utf8),
             "invalid headingDeg"),
        ]
        for (data, reason) in cases {
            let scratch = RestoreScratch()
            defer { scratch.remove() }
            try scratch.write(data)
            #expect(await scratch.store.load() == .discarded(reason))
            #expect(!scratch.fileExists, "\(reason): deleted")
        }
    }

    @Test("The boot session ID is read (simulator: the host's kern.bootsessionuuid), stable, and within Core's 1…64 characters")
    func bootSession() {
        let id = BootSession.current
        #expect(id != nil, "the phone is a §6 check")
        #expect((1...64).contains(id?.count ?? 0))
        #expect(BootSession.current == id)
    }

    @Test("A failed write is counted and leaves nothing half-written")
    func writeFailure() async throws {
        let scratch = RestoreScratch()
        defer { scratch.remove() }
        // The directory's path is taken by a file: nothing can be written.
        try Data("x".utf8).write(to: scratch.directory)
        scratch.store.save(R.state(ageS: 1))
        await scratch.store.drain()
        #expect(scratch.store.counts.saveFailures == 1 && scratch.store.counts.saves == 0)
        #expect(await scratch.store.load() == .none)
    }
}

// MARK: - Service

@Suite("Navigation restore, service (UX-20)", .serialized)
@MainActor
struct NavigationRestoreServiceTests {
    typealias R = RestoreScript
    typealias S = NavigationServiceNavigateTests

    @Test("A saved estimate under 24 h seeds Navigate: unconfirmed with the arrow at once; the first fix confirms where the car stands and rejects it 2 km away",
          arguments: [R.Scenario(moved: false, wifi: false), R.Scenario(moved: false, wifi: true),
                      R.Scenario(moved: true, wifi: false), R.Scenario(moved: true, wifi: true)])
    func seedsAndDecides(_ scenario: R.Scenario) async throws {
        let scratch = RestoreScratch()
        defer { scratch.remove() }
        scratch.store.save(R.state(ageS: 1_200))
        let service = R.service(scratch.store)
        let (feed, tap) = R.feed(1)
        let run = service.start(feed)
        let still = R.parked(0...3)
        #expect(await R.send(still, to: tap, service: service, total: still.count))
        #expect(await service.lastRestore == .restored(ageS: 1_200))
        #expect(await service.lastRestoreGeneration == 1)
        let before = await service.snapshot(at: MonotonicTimestamp(seconds: 3))
        #expect(before.restore.status == .unconfirmed)
        #expect(abs((before.restore.ageS(at: .zero) ?? 0) - 1_200) < 1e-6)
        #expect(before.converged, "parked heading σ √(3² + 3²): the arrow at once")
        #expect(S.distanceM(before, 0, 0) < 1)
        let display = try #require(RestoreDisplay(before.restore, run: 1))
        #expect(display.status == .unconfirmed && display.reason == nil && abs(display.ageAtStartS - 1_200) < 1e-6)

        let northM = scenario.moved ? 2_000.0 : 0
        let fix = R.fix(3.01, northM: northM, wifi: scenario.wifi, accuracy: scenario.wifi ? 30 : 5)
        #expect(await R.send([fix], to: tap, service: service, total: still.count + 1))
        let after = await service.snapshot(at: MonotonicTimestamp(seconds: 3.02))
        #expect(after.restore.status == (scenario.moved ? .rejected : .confirmed), "\(scenario)")
        #expect(after.restore.reason == .fix)
        #expect(S.distanceM(after, northM / 111_320, 0) < (scenario.wifi ? 60 : 15), "\(scenario): at the fix")
        if scenario.moved {
            #expect(S.distanceM(after, 0, 0) > 1_500, "the fix wins, never the prior")
        } else {
            #expect(await service.currentCounters?.reseeds == 0)
        }
        tap.finish()
        await run.value
    }

    @Test("Saved 3 s in the future on another boot (clock skew): restored at age 0, unconfirmed (no recording ended in this process: not a hand-over)")
    func skewedClockRestoresAtAgeZero() async throws {
        let scratch = RestoreScratch()
        defer { scratch.remove() }
        scratch.store.save(R.state(ageS: -3, boot: "boot-other"))
        let service = R.service(scratch.store)
        let (feed, tap) = R.feed(1)
        let run = service.start(feed)
        let still = R.parked(0...1)
        #expect(await R.send(still, to: tap, service: service, total: still.count))
        #expect(await service.lastRestore == .restored(ageS: 0))
        #expect(await service.lastRestoreHandOver == false)
        let snapshot = await service.snapshot(at: MonotonicTimestamp(seconds: 1))
        #expect(snapshot.restore.status == .unconfirmed)
        #expect(RestoreStatus.line(RestoreDisplay(snapshot.restore, run: 1)) != nil)
        tap.finish()
        await run.value
    }

    @Test("Refused: saved 5 min in the future or 25 h ago; corrupt, truncated or unknown version. A fresh start; the file deleted",
          arguments: ["future", "old", "corrupt", "truncated", "version"])
    func refused(_ kind: String) async throws {
        let scratch = RestoreScratch()
        defer { scratch.remove() }
        let valid = try R.state(ageS: 60).encoded()
        switch kind {
        // Another boot, so only the wall clock can say how old it is.
        case "future": scratch.store.save(R.state(ageS: -300, boot: "boot-other"))
        case "old": scratch.store.save(R.state(ageS: 25 * 3600, boot: nil))
        case "corrupt": try scratch.write(Data("{\"version\":1,".utf8))
        case "truncated": try scratch.write(valid.prefix(valid.count - 5))
        default:
            try scratch.write(Data(String(decoding: valid, as: UTF8.self)
                .replacingOccurrences(of: "\"version\":1", with: "\"version\":99").utf8))
        }
        await scratch.store.drain()
        #expect(scratch.fileExists)
        let service = R.service(scratch.store)
        let (feed, tap) = R.feed(1)
        let run = service.start(feed)
        let still = R.parked(0...1)
        #expect(await R.send(still, to: tap, service: service, total: still.count))
        let snapshot = await service.snapshot(at: MonotonicTimestamp(seconds: 1))
        #expect(snapshot.restore.status == .none && snapshot.restore.savedT == nil)
        #expect(!snapshot.initialized, "fresh: nothing until a fix")
        let attempt = await service.lastRestore
        switch kind {
        case "future", "old": #expect(attempt == .refused("age outside −5 s…24 h"))
        case "version": #expect(attempt == .refused("unreadable: unsupported version 99"))
        default: #expect(attempt == .refused("unreadable: malformed"))
        }
        await scratch.store.drain()
        #expect(!scratch.fileExists, "\(kind): deleted")
        tap.finish()
        await run.value
    }

    @Test("No saved estimate: a fresh start, nothing deleted or read twice")
    func noFile() async throws {
        let scratch = RestoreScratch()
        defer { scratch.remove() }
        let service = R.service(scratch.store)
        let (feed, tap) = R.feed(1)
        let run = service.start(feed)
        #expect(await R.send(R.parked(0...0.1), to: tap, service: service, total: R.parked(0...0.1).count))
        #expect(await service.lastRestore == .noSavedState)
        #expect(await service.snapshot(at: .zero).restore.status == .none)
        #expect(scratch.store.counts.loads == 1)
        tap.finish()
        await run.value
    }

    @Test("Record writes the saved estimate but never reads it: a fresh engine, bit-identical to a run without a store; the file is Record's at its end")
    func recordWritesNeverReads() async throws {
        let scratch = RestoreScratch()
        defer { scratch.remove() }
        let sidecars = FileManager.default.temporaryDirectory
            .appendingPathComponent("drivelogger-restore-rec-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sidecars, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sidecars) }
        let planted = R.state(ageS: 60)
        scratch.store.save(planted)
        let drive = S.drive(0...8)
        let times = [2.0, 5, 8]
        let header = R.header()

        var results: [[NavigationSnapshot]] = []
        for withStore in [true, false] {
            let service = R.service(withStore ? scratch.store : nil, saveInterval: .milliseconds(1))
            let (feed, tap) = R.feed(1, recordingIn: sidecars, nowS: 8, header: header)
            let run = service.start(feed)
            #expect(await R.send(drive, to: tap, service: service, total: drive.count))
            let snapshots = await S.snapshots(service, at: times)
            #expect(snapshots.allSatisfy { $0.restore.status == .none && $0.initialized })
            results.append(snapshots)
            tap.finish()
            await run.value
            #expect(await service.lastRestore == nil, "never asked")
            try? FileManager.default.removeItem(at: LogStore.navSidecarURL(for: feed.recordingURL!))
        }
        #expect(results[0] == results[1], "saving changes nothing in the engine")
        await scratch.store.drain()
        #expect(scratch.store.counts.loads == 0, "Record never reads")
        #expect(scratch.store.counts.saves > 2, "every save interval (1 ms here) and at the end")
        let saved = try scratch.saved()
        #expect(saved != planted)
        #expect(saved.savedAt == R.wallStart.addingTimeInterval(8), "captured at the run's last step, on its clock")
        #expect(saved.bootSessionID == R.boot && saved.uptimeSeconds == R.referenceUptime + 8)
        #expect(saved.restoreClass == .moving && saved.lastOBDSpeedKmh == 36)
    }

    @Test("Navigate saves at its end (stop), on flush (background), and every save interval; nothing before the engine has a position")
    func saveCadence() async throws {
        #expect(NavigationService().saveInterval == .seconds(5), "the decided cadence")
        let drive = S.drive(0...8)
        // At the end only.
        do {
            let scratch = RestoreScratch()
            defer { scratch.remove() }
            let service = R.service(scratch.store)
            let (feed, tap) = R.feed(1, nowS: 8)
            let run = service.start(feed)
            #expect(await R.send(drive, to: tap, service: service, total: drive.count))
            await scratch.store.drain()
            #expect(scratch.store.counts.saves == 0 && !scratch.fileExists)
            tap.finish()
            await run.value
            await scratch.store.drain()
            #expect(scratch.store.counts.saves == 1)
            #expect(try scratch.saved().savedAt == R.wallStart.addingTimeInterval(8))
        }
        // On flush: on disk when it returns.
        do {
            let scratch = RestoreScratch()
            defer { scratch.remove() }
            let service = R.service(scratch.store)
            let (feed, tap) = R.feed(1, nowS: 8)
            let run = service.start(feed)
            #expect(await R.send(drive, to: tap, service: service, total: drive.count))
            await service.flush()
            #expect(scratch.store.counts.saves == 1 && scratch.fileExists)
            tap.finish()
            await run.value
        }
        // Every interval, from the ingest path, once there is a position.
        do {
            let scratch = RestoreScratch()
            defer { scratch.remove() }
            let service = R.service(scratch.store, saveInterval: .milliseconds(30))
            let (feed, tap) = R.feed(1, nowS: 8)
            let run = service.start(feed)
            // Before the first fix (1 s): past the interval, nothing to save.
            let before = drive.filter { $0.timestamp.seconds <= 0.5 }
            #expect(await R.send(before, to: tap, service: service, total: before.count))
            try await Task.sleep(for: .milliseconds(60))
            var total = before.count
            let next = drive.filter { $0.timestamp.seconds > 0.5 && $0.timestamp.seconds <= 0.9 }
            total += next.count
            #expect(await R.send(next, to: tap, service: service, total: total))
            await scratch.store.drain()
            #expect(scratch.store.counts.saves == 0, "no position yet: nothing to save")
            for chunk in 0..<4 {
                let low = chunk == 0 ? 0.9 : Double(chunk) * 2, high = Double(chunk + 1) * 2
                let events = drive.filter { $0.timestamp.seconds > low && $0.timestamp.seconds <= high }
                total += events.count
                #expect(await R.send(events, to: tap, service: service, total: total))
                try await Task.sleep(for: .milliseconds(60))
            }
            #expect(await R.send([S.motion(8.01)], to: tap, service: service, total: total + 1))
            await scratch.store.drain()
            #expect(scratch.store.counts.saves >= 3, "\(scratch.store.counts.saves)")
            tap.finish()
            await run.value
        }
    }

    @Test("The run's end classes the estimate with the session's engine-off note: auto-stop parked, otherwise a standing stop")
    func endClassUsesRunEnd() async throws {
        for engineOff in [true, false] {
            let scratch = RestoreScratch()
            defer { scratch.remove() }
            let service = R.service(scratch.store)
            let runEnd = NavigationRunEnd()
            let (feed, tap) = R.feed(1, nowS: 4, runEnd: runEnd)
            let run = service.start(feed)
            let events = (R.parked(0...4) + [R.fix(0.51, northM: 0, wifi: false, accuracy: 5)])
                .sorted { $0.timestamp.nanoseconds < $1.timestamp.nanoseconds }
            #expect(await R.send(events, to: tap, service: service, total: events.count))
            if engineOff { runEnd.markEngineOff() }
            tap.finish()
            await run.value
            await scratch.store.drain()
            #expect(try scratch.saved().restoreClass == (engineOff ? .parked : .standingStop))
        }
    }

    /// A temporary directory for a recording feed's sidecar.
    static func sidecarDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("drivelogger-restore-rec-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("A Navigate start waits for the earlier run (Record) to end and restores from its final save")
    func waitsForEarlierRun() async throws {
        let scratch = RestoreScratch()
        defer { scratch.remove() }
        let sidecars = try Self.sidecarDirectory()
        defer { try? FileManager.default.removeItem(at: sidecars) }
        let service = R.service(scratch.store)
        let drive = S.drive(0...8)
        let (record, recordTap) = R.feed(1, recordingIn: sidecars, nowS: 8)
        let recordRun = service.start(record)
        #expect(await R.send(drive, to: recordTap, service: service, total: drive.count))
        // Navigate's feed arrives while Record's run still drains.
        let (navigate, navigateTap) = R.feed(2, nowS: 8)
        let navigateRun = service.start(navigate)
        try await Task.sleep(for: .milliseconds(100))
        #expect(await service.lastRestoreGeneration == nil, "still waiting for Record's end")
        #expect(scratch.store.counts.loads == 0)
        recordTap.finish()
        await recordRun.value
        let still = R.parked(8...8.2)
        for event in still { navigateTap.record(event) }
        #expect(await R.wait { await service.snapshot(at: .zero).stats.inputs == still.count })
        #expect(await service.lastRestoreGeneration == 2)
        #expect(await service.lastRestore == .restored(ageS: 0), "Record's save at its end (t 8)")
        #expect(await service.lastRestoreHandOver, "Record's final save: a hand-over")
        // Record converged on the drive, gap 0: confirmed at once.
        #expect(try scratch.saved().converged)
        let restore = await service.snapshot(at: MonotonicTimestamp(seconds: 8.2)).restore
        #expect(restore.status == .confirmed && restore.reason == .handOver)
        navigateTap.finish()
        await navigateRun.value
    }

    @Test("An earlier run that never ends holds Navigate's start only for the hand-over timeout")
    func handOverTimeout() async throws {
        let scratch = RestoreScratch()
        defer { scratch.remove() }
        let sidecars = try Self.sidecarDirectory()
        defer { try? FileManager.default.removeItem(at: sidecars) }
        let service = NavigationService(restoreStore: scratch.store, saveInterval: .seconds(3_600),
                                        handOverTimeout: .milliseconds(300), bootSessionID: { R.boot })
        let (stuck, stuckTap) = R.feed(1, recordingIn: sidecars, nowS: 8)
        let stuckRun = service.start(stuck)
        #expect(await R.wait { await service.currentGeneration == 1 })
        let (navigate, navigateTap) = R.feed(2, nowS: 8)
        let started = ContinuousClock.now
        let navigateRun = service.start(navigate)
        #expect(await R.wait { await service.lastRestoreGeneration == 2 })
        let waited = ContinuousClock.now - started
        #expect(waited >= .milliseconds(290) && waited < .seconds(2), "\(waited)")
        #expect(await service.lastRestore == .noSavedState)
        #expect(await service.currentGeneration == 2)
        navigateTap.finish()
        await navigateRun.value
        #expect(await service.currentGeneration == 1, "the run still draining, not none (R77.2-3)")
        stuckTap.finish()
        await stuckRun.value
        #expect(await service.currentGeneration == nil)
    }

    @Test("A Navigate start that waited never takes the map from a newer recording (R77.2-3)")
    func staleNavigateKeepsTheNewerRecordingCurrent() async throws {
        let scratch = RestoreScratch()
        defer { scratch.remove() }
        let sidecars = try Self.sidecarDirectory()
        defer { try? FileManager.default.removeItem(at: sidecars) }
        let service = NavigationService(restoreStore: scratch.store, saveInterval: .seconds(3_600),
                                        handOverTimeout: .milliseconds(300), bootSessionID: { R.boot })
        let (stuck, stuckTap) = R.feed(1, recordingIn: sidecars, nowS: 8)
        let stuckRun = service.start(stuck)
        #expect(await R.wait { await service.currentGeneration == 1 })
        // Navigate (2) waits for the stuck recording; a newer recording (3)
        // begins meanwhile.
        let (navigate, navigateTap) = R.feed(2, nowS: 8)
        let navigateRun = service.start(navigate)
        let header = R.header()
        let (record, recordTap) = R.feed(3, recordingIn: sidecars, nowS: 9, header: header)
        let recordRun = service.start(record)
        #expect(await R.wait { await service.currentGeneration == 3 })
        // Navigate's start after its hand-over timeout.
        #expect(await R.wait { await service.runsStarted == 3 })
        #expect(await service.lastRestoreGeneration == 2)
        #expect(await service.currentGeneration == 3, "the stale Navigate run's begin")
        navigateTap.finish()
        await navigateRun.value
        stuckTap.finish()
        await stuckRun.value
        #expect(await service.currentGeneration == 3, "after runs 1 and 2 ended")
        let drive = S.drive(0...9)
        #expect(await R.send(drive, to: recordTap, service: service, total: drive.count))
        let snapshot = await service.snapshot(at: MonotonicTimestamp(seconds: 9))
        #expect(snapshot.sessionID == header.sessionID, "the recording's snapshot, not idle")
        #expect(snapshot.initialized)
        await service.flush()
        #expect(try scratch.saved().savedAt == R.wallStart.addingTimeInterval(9),
                "the recording's save, at its last step (9 s)")
        recordTap.finish()
        await recordRun.value
    }

    @Test("An older run's save at its late end never replaces a newer run's")
    func olderRunNeverOverwrites() async throws {
        let scratch = RestoreScratch()
        defer { scratch.remove() }
        let sidecars = try Self.sidecarDirectory()
        defer { try? FileManager.default.removeItem(at: sidecars) }
        let service = R.service(scratch.store)
        let drive = S.drive(0...8)
        // Navigate (1) still draining when Record (2) has saved; Record's
        // last step is 9 s, Navigate's 8 s (each save is stamped there).
        let (navigate, navigateTap) = R.feed(1, nowS: 8)
        let navigateRun = service.start(navigate)
        #expect(await R.send(drive, to: navigateTap, service: service, total: drive.count))
        let (record, recordTap) = R.feed(2, recordingIn: sidecars, nowS: 9)
        let recordRun = service.start(record)
        let recordDrive = S.drive(0...9)
        #expect(await R.send(recordDrive, to: recordTap, service: service, total: recordDrive.count))
        await service.flush()
        #expect(try scratch.saved().savedAt == R.wallStart.addingTimeInterval(9), "Record's")
        navigateTap.finish()
        await navigateRun.value
        await scratch.store.drain()
        #expect(try scratch.saved().savedAt == R.wallStart.addingTimeInterval(9), "still Record's")
        #expect(scratch.store.counts.saves == 1)
        recordTap.finish()
        await recordRun.value
        await scratch.store.drain()
        #expect(scratch.store.counts.saves == 2, "Record's own end")
    }

    @Test("R77.4-4: a recording's final save is stamped at its engine's last step, not after the stop flow; Navigate grows it for the whole gap (12 s: a hand-over, but unconfirmed)")
    func finalSaveStampedAtTheLastStep() async throws {
        let scratch = RestoreScratch()
        defer { scratch.remove() }
        let sidecars = try Self.sidecarDirectory()
        defer { try? FileManager.default.removeItem(at: sidecars) }
        let service = R.service(scratch.store)
        // The drive's inputs end at 8 s; the run ends at 20 s.
        let drive = S.drive(0...8)
        let (record, recordTap) = R.feed(1, recordingIn: sidecars, nowS: 20)
        let recordRun = service.start(record)
        #expect(await R.send(drive, to: recordTap, service: service, total: drive.count))
        #expect(await service.snapshot(at: MonotonicTimestamp(seconds: 8)).converged)
        recordTap.finish()
        await recordRun.value
        await scratch.store.drain()
        let saved = try scratch.saved()
        #expect(saved.savedAt == R.wallStart.addingTimeInterval(8), "the last step, not the end (20 s)")
        #expect(saved.uptimeSeconds == R.referenceUptime + 8)
        #expect(saved.converged && saved.restoreClass == .moving)

        let (navigate, navigateTap) = R.feed(2, nowS: 20)
        let navigateRun = service.start(navigate)
        let still = R.parked(20...20.4)
        #expect(await R.send(still, to: navigateTap, service: service, total: still.count))
        #expect(await service.lastRestore == .restored(ageS: 12))
        #expect(await service.lastRestoreHandOver, "Record's final save, in this process")
        let restore = await service.snapshot(at: MonotonicTimestamp(seconds: 20.4)).restore
        #expect(restore.status == .unconfirmed && restore.reason == nil,
                "a 12 s gap is over the hand-over's 10 s: not confirmed at once")
        navigateTap.finish()
        await navigateRun.value
    }

    @Test("R77.4-3: a run that drives (OBD) with no estimate deletes the saved one; an older run's late end cannot write it back; Navigate then starts fresh")
    func drivingWithoutAnEstimateInvalidatesTheSave() async throws {
        let scratch = RestoreScratch()
        defer { scratch.remove() }
        let sidecars = try Self.sidecarDirectory()
        defer { try? FileManager.default.removeItem(at: sidecars) }
        scratch.store.save(R.state(ageS: 60, restoreClass: .standingStop))
        let service = R.service(scratch.store)
        // An older recording with an estimate from its first input (a fix
        // at 0 s, before the first OBD reply), still draining.
        let (older, olderTap) = R.feed(1, recordingIn: sidecars, nowS: 8)
        let olderRun = service.start(older)
        let drive = [S.fix(0)] + S.drive(0...8)
        #expect(await R.send(drive, to: olderTap, service: service, total: drive.count))
        await scratch.store.drain()
        #expect(scratch.fileExists, "drove with an estimate: kept (no save yet, interval 1 h)")
        #expect(await service.savesInvalidated == 0)
        // A newer recording drives with no fix and no pin.
        let (blind, blindTap) = R.feed(2, recordingIn: sidecars, nowS: 8)
        let blindRun = service.start(blind)
        let noFixes = S.drive(0...8, fixesUntil: -1)
        #expect(await R.send(noFixes, to: blindTap, service: service, total: noFixes.count))
        #expect(await !service.snapshot(at: MonotonicTimestamp(seconds: 8)).initialized)
        await scratch.store.drain()
        #expect(!scratch.fileExists, "deleted once the car drove")
        #expect(await service.savesInvalidated == 1)
        olderTap.finish()
        await olderRun.value
        await scratch.store.drain()
        #expect(!scratch.fileExists, "the older run's end save is refused")
        blindTap.finish()
        await blindRun.value
        await scratch.store.drain()
        #expect(!scratch.fileExists && scratch.store.counts.saves == 1, "only the planted save was ever written")
        #expect(await service.savesInvalidated == 1, "once per run")

        let (navigate, navigateTap) = R.feed(3, nowS: 8)
        let navigateRun = service.start(navigate)
        let still = R.parked(8...8.2)
        #expect(await R.send(still, to: navigateTap, service: service, total: still.count))
        #expect(await service.lastRestore == .noSavedState)
        #expect(await service.snapshot(at: MonotonicTimestamp(seconds: 8.2)).restore.status == .none)
        navigateTap.finish()
        await navigateRun.value
    }

    @Test("R77.4-3: a run with no estimate that never drives (OBD 0) keeps the saved estimate")
    func standingWithoutAnEstimateKeepsTheSave() async throws {
        let scratch = RestoreScratch()
        defer { scratch.remove() }
        let sidecars = try Self.sidecarDirectory()
        defer { try? FileManager.default.removeItem(at: sidecars) }
        let planted = R.state(ageS: 60, restoreClass: .standingStop)
        scratch.store.save(planted)
        let service = R.service(scratch.store)
        let (record, recordTap) = R.feed(1, recordingIn: sidecars, nowS: 8)
        let recordRun = service.start(record)
        let standing = R.parked(0...8)
        #expect(await R.send(standing, to: recordTap, service: service, total: standing.count))
        recordTap.finish()
        await recordRun.value
        await scratch.store.drain()
        #expect(try scratch.saved() == planted)
        #expect(await service.savesInvalidated == 0)
    }

    @Test("Without a store nothing is read or written; the demo's service has none")
    func noStoreNoFile() async throws {
        let service = NavigationService()
        #expect(service.restoreStore == nil)
        let rig = NavigateRig(store: RecordingSessionNavigateTests.absentStore())
        let demo = DemoDriveController(session: rig.session, link: rig.link, packURL: nil)
        #expect(demo.navigation.restoreStore == nil, "the demo grid never replaces the drive's estimate")
        let (feed, tap) = R.feed(1, nowS: 8)
        let run = service.start(feed)
        let drive = S.drive(0...3)
        #expect(await R.send(drive, to: tap, service: service, total: drive.count))
        await service.flush()
        #expect(await service.lastRestore == nil)
        #expect(await service.snapshot(at: .zero).restore.status == .none)
        tap.finish()
        await run.value
    }
}

// MARK: - Session

/// Drives a `NavigateRig` on one script clock across runs: each run's
/// session clock starts at its own script time (`runStart`), the car's
/// track (`NavigationServiceNavigateTests.position`) is the script's.
@MainActor
final class ScriptDriver {
    typealias S = NavigationServiceNavigateTests
    let rig: NavigateRig
    private var seq = 1_000
    /// Navigation inputs sent since the last `reset`.
    private(set) var sent = 0

    init(_ rig: NavigateRig) { self.rig = rig }

    func reset() { sent = 0 }

    /// A fix on the track at script `t`, stamped on the run's clock.
    static func trackFix(_ t: Double, runStart: Double) -> LogEvent {
        let p = S.position(t), st = t - runStart
        return LogEvent(timestamp: MonotonicTimestamp(seconds: st), payload: .location(LocationSample(
            latitude: p.latitude, longitude: p.longitude, altitude: 0, horizontalAccuracy: 5, verticalAccuracy: -1,
            speed: S.speedMS, speedAccuracy: 0.5, course: S.courseDeg, courseAccuracy: 5,
            receivedT: MonotonicTimestamp(seconds: st), ageS: 0)))
    }

    /// A Wi-Fi fix on the track at script `t` (65 m, no speed, no course).
    static func wifiTrackFix(_ t: Double, runStart: Double) -> LogEvent {
        let p = S.position(t), st = t - runStart
        return LogEvent(timestamp: MonotonicTimestamp(seconds: st), payload: .location(LocationSample(
            latitude: p.latitude, longitude: p.longitude, altitude: 0, horizontalAccuracy: 65, verticalAccuracy: -1,
            speed: -1, speedAccuracy: -1, course: -1, courseAccuracy: -1,
            receivedT: MonotonicTimestamp(seconds: st), ageS: 0)))
    }

    /// 0.2 s from script `t0`, as `NavigateRig.step` but on the run's clock:
    /// motion at 50 Hz, one OBD poll over the link, a fix on whole script
    /// seconds while `fixes`. Parked: speed 0, no yaw, fixes at (0, 0).
    /// `wifi`: the fix is a Wi-Fi fix of the track (65 m, no speed or
    /// course) instead of a GNSS one.
    func step(_ t0: Double, runStart: Double, fixes: Bool = true, parked: Bool = false, wifi: Bool = false) async {
        let st = t0 - runStart
        let yaw = parked ? 0 : 0.002
        var first = (0..<5).map { S.motion(st + Double($0) * 0.02, yawRate: yaw) }
        if fixes, abs(t0 - t0.rounded()) < 1e-9 {
            first.insert(parked ? RestoreScript.fix(st, northM: 0, wifi: false, accuracy: 5)
                                : wifi ? Self.wifiTrackFix(t0, runStart: runStart)
                                : Self.trackFix(t0, runStart: runStart), at: 0)
        }
        rig.uptime.set(NavigateRig.base + t0 + 0.09)
        rig.source.emit(first)
        await rig.send(InitScript.poll(seq: seq, speed: parked ? 0 : 36, at: NavigateRig.base + t0 + 0.09))
        seq += 1
        let second = (5..<10).map { S.motion(st + Double($0) * 0.02, yawRate: yaw) }
        rig.uptime.set(NavigateRig.base + t0 + 0.2)
        rig.source.emit(second)
        sent += first.count + 1 + second.count
    }

    func drive(_ range: Range<Double>, runStart: Double, fixes: Bool = true, parked: Bool = false) async {
        var t = range.lowerBound
        while t < range.upperBound - 1e-9 {
            await step(t, runStart: runStart, fixes: fixes, parked: parked)
            t = ((t + 0.2) * 5).rounded() / 5
        }
    }
}

@Suite("Navigation restore, session (UX-20)", .serialized)
@MainActor
struct NavigationRestoreSessionTests {
    typealias R = RestoreScript
    typealias S = NavigationServiceNavigateTests

    /// Waits until the service follows `generation` and has ingested `count` inputs of it.
    static func ingested(_ service: NavigationService, _ generation: Int, _ count: Int) async -> Bool {
        await R.wait {
            guard await service.currentGeneration == generation else { return false }
            return await service.snapshot(at: .zero).stats.inputs == count
        }
    }

    @Test("Navigate → Record → Stop: Navigate resumes from the estimate Record's engine saved at Stop: converged kept, heading σ continuous, no reseed; converged and 0.3 s gap (0.2 s after Stop): confirmed at once as a hand-over, no Restored line")
    func recordStopHandOver() async throws {
        let scratch = try ScratchStore()
        defer { scratch.remove() }
        let restore = RestoreScratch()
        defer { restore.remove() }
        let service = R.service(restore.store)
        let rig = NavigateRig(store: scratch.store, service: service)
        let driver = ScriptDriver(rig)
        await rig.connect(speed: 36)
        rig.session.enableNavigate(RecordingSessionNavigateTests.quick)
        let first = try #require(rig.session.navigateGeneration)
        await driver.drive(0..<3, runStart: 0)
        #expect(await Self.ingested(service, first, driver.sent))

        // Record: its own fresh engine; Navigate's end saved, Record never reads.
        try await rig.session.start(mount: "", vehicle: "", allowWithoutOBD: false, calibration: .zero)
        let record = try #require(rig.session.currentGeneration)
        #expect(await R.ended(service, first))
        await restore.store.drain()
        #expect(restore.fileExists, "Navigate's estimate saved at its end")
        driver.reset()
        await driver.drive(3..<15, runStart: 3)
        #expect(await Self.ingested(service, record, driver.sent))
        let loadsBefore = restore.store.counts.loads
        let recordAtStop = await service.snapshot(at: MonotonicTimestamp(seconds: 12))
        #expect(recordAtStop.restore.status == .none, "Record starts fresh")
        #expect(recordAtStop.converged)
        let sigmaAtStop = try #require(recordAtStop.headingStdDeg)
        let headingAtStop = try #require(recordAtStop.headingDeg)

        // Stop at script 15 s; Navigate resumes on a clock starting there.
        let stopCalled = ContinuousClock.now
        await rig.session.stop()
        let second = try #require(rig.session.navigateGeneration)
        #expect(await R.wait { await service.lastRestoreGeneration == second })
        let handOver = ContinuousClock.now - stopCalled
        #expect(handOver < .seconds(2), "Stop to Navigate restored: \(handOver)")
        print("UX-20 hand-over: Stop called → Navigate restored in \(handOver)")
        #expect(restore.store.counts.loads == loadsBefore + 1, "read once, by Navigate")
        guard case .restored(let ageS) = await service.lastRestore else {
            Issue.record("not restored: \(String(describing: await service.lastRestore))")
            return
        }
        // Stamped at Record's last engine step (script 14.9 s: inputs to
        // 14.98 s), not when Stop's flow saved it (15 s): R77.4-4.
        #expect(abs(ageS - 0.1) < 0.005, "Record's final save at its last step: \(ageS)")
        #expect(await service.lastRestoreHandOver, "Record's own final save, in this process")
        #expect(try restore.saved().restoreClass == .moving)
        #expect(try restore.saved().converged)

        // The first Navigate input 0.2 s after Stop (the scripted gap), 0.3 s
        // after the save.
        let afterStopS = 0.2, gapS = afterStopS + ageS
        driver.reset()
        await driver.step(15 + afterStopS, runStart: 15)
        #expect(await Self.ingested(service, second, driver.sent))
        let resumed = await service.snapshot(at: MonotonicTimestamp(seconds: afterStopS + 0.18))
        #expect(resumed.restore.status == .confirmed && resumed.restore.reason == .handOver)
        #expect(RestoreStatus.line(RestoreDisplay(resumed.restore, run: second)) == nil, "no Restored line")
        #expect(resumed.converged, "converged carries over: no calibrating-heading phase")
        let sigma = try #require(resumed.headingStdDeg)
        let turn = NavigationRestoreModel.movingHeadingRateDegPerS * gapS
        let grown = (sigmaAtStop * sigmaAtStop + turn * turn).squareRoot()
        #expect(abs(sigma - grown) < 0.5, "heading σ continuous: \(sigma) vs \(grown) grown from \(sigmaAtStop)")
        #expect(abs(R.angleDifference(try #require(resumed.headingDeg), headingAtStop)) < 2)
        let truth = S.position(15 + afterStopS + 0.18)
        #expect(S.distanceM(resumed, truth.latitude, truth.longitude) < 15)
        print("UX-20 hand-over: heading σ at Stop \(sigmaAtStop)°, after a \(gapS) s gap \(sigma)° (grown \(grown)°)")

        // The next fix (script 16 s): still the hand-over's confirmation, never reseeded.
        await driver.drive((15 + afterStopS + 0.2)..<16.4, runStart: 15)
        #expect(await Self.ingested(service, second, driver.sent))
        let confirmed = await service.snapshot(at: MonotonicTimestamp(seconds: 1.38))
        #expect(confirmed.restore.status == .confirmed && confirmed.restore.reason == .handOver)
        #expect(confirmed.converged)
        #expect(await service.currentCounters?.reseeds == 0)
        rig.session.disableNavigate()
        #expect(await R.ended(service, second))
    }

    @Test("Navigate → Record → Stop with Record not converged at Stop (one Wi-Fi fix): a hand-over, but unconfirmed with the Restored line until a fix")
    func recordStopHandOverUnconverged() async throws {
        let scratch = try ScratchStore()
        defer { scratch.remove() }
        let restore = RestoreScratch()
        defer { restore.remove() }
        let service = R.service(restore.store)
        let rig = NavigateRig(store: scratch.store, service: service)
        let driver = ScriptDriver(rig)
        await rig.connect(speed: 36)
        rig.session.enableNavigate(RecordingSessionNavigateTests.quick)
        let first = try #require(rig.session.navigateGeneration)
        await driver.drive(0..<3, runStart: 0)
        #expect(await Self.ingested(service, first, driver.sent))

        // Record: one Wi-Fi fix (no heading), then none: never converged.
        try await rig.session.start(mount: "", vehicle: "", allowWithoutOBD: false, calibration: .zero)
        let record = try #require(rig.session.currentGeneration)
        #expect(await R.ended(service, first))
        driver.reset()
        await driver.step(3, runStart: 3, wifi: true)
        await driver.drive(3.2..<15, runStart: 3, fixes: false)
        #expect(await Self.ingested(service, record, driver.sent))
        let recordAtStop = await service.snapshot(at: MonotonicTimestamp(seconds: 12))
        #expect(recordAtStop.initialized && !recordAtStop.converged)

        await rig.session.stop()
        let second = try #require(rig.session.navigateGeneration)
        #expect(await R.wait { await service.lastRestoreGeneration == second })
        guard case .restored = await service.lastRestore else {
            Issue.record("not restored: \(String(describing: await service.lastRestore))")
            return
        }
        #expect(await service.lastRestoreHandOver)
        #expect(try restore.saved().converged == false)

        driver.reset()
        await driver.step(15.2, runStart: 15, fixes: false)
        #expect(await Self.ingested(service, second, driver.sent))
        let resumed = await service.snapshot(at: MonotonicTimestamp(seconds: 0.38))
        #expect(resumed.restore.status == .unconfirmed && resumed.restore.reason == nil)
        let line = RestoreStatus.line(RestoreDisplay(resumed.restore, run: second))
        #expect(line != nil, "the Restored line shows")
        rig.session.disableNavigate()
        #expect(await R.ended(service, second))
    }

    @Test("R77.4-3: Navigate saved (standing) → Record with GPS off, no pin, 2 km by OBD → Stop: Navigate does not restore the pre-recording save; a fresh start")
    func blindRecordingInvalidatesNavigateSave() async throws {
        let scratch = try ScratchStore()
        defer { scratch.remove() }
        let restore = RestoreScratch()
        defer { restore.remove() }
        let service = R.service(restore.store)
        let rig = NavigateRig(store: scratch.store, service: service)
        let driver = ScriptDriver(rig)
        await rig.connect(speed: 0)
        rig.session.enableNavigate(RecordingSessionNavigateTests.quick)
        let first = try #require(rig.session.navigateGeneration)
        await driver.drive(0..<4, runStart: 0, parked: true)
        #expect(await Self.ingested(service, first, driver.sent))

        try await rig.session.start(mount: "", vehicle: "", allowWithoutOBD: false, calibration: .zero)
        let record = try #require(rig.session.currentGeneration)
        #expect(await R.ended(service, first))
        await restore.store.drain()
        #expect(try restore.saved().restoreClass == .standingStop, "Navigate's save at its end: a 50 m class")
        // 200 s at 36 km/h (OBD), no fix, no pin.
        driver.reset()
        await driver.drive(4..<204, runStart: 4, fixes: false)
        #expect(await Self.ingested(service, record, driver.sent))
        #expect(await !service.snapshot(at: MonotonicTimestamp(seconds: 199)).initialized)
        await restore.store.drain()
        #expect(!restore.fileExists, "the car drove with no estimate: the save is deleted")

        await rig.session.stop()
        let second = try #require(rig.session.navigateGeneration)
        #expect(await R.wait { await service.lastRestoreGeneration == second })
        #expect(await service.lastRestore == .noSavedState)
        #expect(await service.lastRestoreHandOver == false)
        driver.reset()
        await driver.step(204.2, runStart: 204, fixes: false)
        #expect(await Self.ingested(service, second, driver.sent))
        let fresh = await service.snapshot(at: MonotonicTimestamp(seconds: 0.38))
        #expect(fresh.restore.status == .none && !fresh.initialized, "not the drive's start point")
        rig.session.disableNavigate()
        #expect(await R.ended(service, second))
    }

    @Test("Navigate after Navigate (no recording between): never a hand-over")
    func navigateAfterNavigateIsNoHandOver() async throws {
        let restore = RestoreScratch()
        defer { restore.remove() }
        let service = R.service(restore.store)
        let rig = NavigateRig(store: RecordingSessionNavigateTests.absentStore(), service: service)
        let driver = ScriptDriver(rig)
        await rig.connect(speed: 36)
        rig.session.enableNavigate(RecordingSessionNavigateTests.quick)
        let first = try #require(rig.session.navigateGeneration)
        await driver.drive(0..<3, runStart: 0)
        #expect(await Self.ingested(service, first, driver.sent))
        rig.session.disableNavigate()
        #expect(await R.ended(service, first))
        rig.session.enableNavigate(RecordingSessionNavigateTests.quick)
        let second = try #require(rig.session.navigateGeneration)
        #expect(await R.wait { await service.lastRestoreGeneration == second })
        guard case .restored = await service.lastRestore else {
            Issue.record("not restored: \(String(describing: await service.lastRestore))")
            return
        }
        #expect(await service.lastRestoreHandOver == false)
        driver.reset()
        await driver.step(3.2, runStart: 3, fixes: false)
        #expect(await Self.ingested(service, second, driver.sent))
        #expect(await service.snapshot(at: MonotonicTimestamp(seconds: 0.38)).restore.status == .unconfirmed)
        rig.session.disableNavigate()
        #expect(await R.ended(service, second))
    }

    @Test("Navigate's auto-stop saves the estimate as parked (engine off); stopping Navigate otherwise saves a standing stop", arguments: [true, false])
    func autoStopSavesParked(_ autoStop: Bool) async throws {
        let restore = RestoreScratch()
        defer { restore.remove() }
        let service = R.service(restore.store)
        let rig = NavigateRig(store: RecordingSessionNavigateTests.absentStore(), service: service)
        let driver = ScriptDriver(rig)
        await rig.connect(speed: 0)
        rig.session.enableNavigate(NavigateConfiguration(stillCalibration: .zero, autoStopAfter: .milliseconds(300)))
        let generation = try #require(rig.session.navigateGeneration)
        await driver.drive(0..<4, runStart: 0, parked: true)
        #expect(await Self.ingested(service, generation, driver.sent))
        if autoStop {
            rig.link.state = .idle
            #expect(await eventually(5) { rig.session.navigateState == .off })
        } else {
            rig.session.disableNavigate()
        }
        #expect(await R.ended(service, generation))
        await restore.store.drain()
        let saved = try restore.saved()
        #expect(saved.restoreClass == (autoStop ? .parked : .standingStop))
        #expect(saved.lastOBDSpeedKmh == 0)
    }

    @Test("Navigate on background saves the estimate (onFlush in a background task) before the app may be killed")
    func backgroundSaves() async throws {
        let restore = RestoreScratch()
        defer { restore.remove() }
        let service = R.service(restore.store)
        let rig = NavigateRig(store: RecordingSessionNavigateTests.absentStore(), service: service)
        rig.session.onFlush = { await service.flush() }
        let driver = ScriptDriver(rig)
        await rig.connect(speed: 36)
        rig.session.enableNavigate(RecordingSessionNavigateTests.quick)
        let generation = try #require(rig.session.navigateGeneration)
        await driver.drive(0..<3, runStart: 0)
        #expect(await Self.ingested(service, generation, driver.sent))
        await restore.store.drain()
        #expect(!restore.fileExists, "no save yet (interval 1 h)")
        rig.session.handleScenePhase(.background)
        #expect(await R.wait(10) { restore.fileExists })
        #expect(rig.session.navigateGeneration == generation, "background ends nothing")
        rig.session.handleScenePhase(.active)
        rig.session.disableNavigate()
        #expect(await R.ended(service, generation))
    }
}
