import DriveLoggerCore
import Foundation
import os
import Testing

@testable import DriveLogger

// UX-1: a Navigate feed (`RecordingNavigationFeed.Output.navigateOnly`) runs
// the same engine as a recording with no sidecar: nothing is written, the
// engine is fed exactly as with a sidecar (same seed, same inputs, same
// order), roads and pins behave the same. Synthetic feeds only, on (0, 0)
// offsets; the session's Navigate mode (no recording) is sensors-logging's.

@Suite("Navigation service, Navigate (no sidecar)", .serialized)
@MainActor
struct NavigationServiceNavigateTests {
    // MARK: Script

    /// A fresh header per call (unique `sessionID`, so its files can be
    /// told apart from other suites' in the shared temp directory).
    static func header(_ id: UUID = UUID()) -> LogHeader {
        LogHeader(
            sessionID: id, startedAt: Date(timeIntervalSince1970: 0), referenceUptimeSeconds: 100,
            app: AppIdentity(name: "DriveLogger", version: "0.0", build: "7"),
            device: DeviceIdentity(model: "test", systemName: "iOS", systemVersion: "17"))
    }

    /// Along the fixture pack's road from (0, 0) towards (0.002, 0.004).
    static let courseDeg = atan2(0.004, 0.002) * 180 / .pi
    static let speedMS = 10.0

    static func position(_ t: Double) -> (latitude: Double, longitude: Double) {
        let metres = speedMS * t, rad = courseDeg * .pi / 180
        return (metres * cos(rad) / 111_320, metres * sin(rad) / 111_320)
    }

    static func motion(_ t: Double, yawRate: Double = 0) -> LogEvent {
        LogEvent(timestamp: MonotonicTimestamp(seconds: t), payload: .motion(MotionSample(
            userAcceleration: .zero, gravity: Vector3(x: 0, y: 0, z: -1),
            rotationRate: Vector3(x: 0, y: 0, z: yawRate), attitude: .identity)))
    }

    static func obd(_ t: Double, kmh: Double) -> LogEvent {
        LogEvent(timestamp: MonotonicTimestamp(seconds: t), payload: .obd(OBDSample(
            pid: .vehicleSpeed, value: kmh, unit: .kilometersPerHour, ecu: "7E8")))
    }

    static func fix(_ t: Double, accuracy: Double = 8) -> LogEvent {
        let p = position(t)
        return LogEvent(timestamp: MonotonicTimestamp(seconds: t), payload: .location(LocationSample(
            latitude: p.latitude, longitude: p.longitude, altitude: 0, horizontalAccuracy: accuracy,
            verticalAccuracy: -1, speed: speedMS, speedAccuracy: 0.5, course: courseDeg, courseAccuracy: 5,
            receivedT: MonotonicTimestamp(seconds: t), ageS: 0)))
    }

    static func pin(writtenT: Double, pressedT: Double, latitude: Double, longitude: Double) -> LogEvent {
        LogEvent(timestamp: MonotonicTimestamp(seconds: writtenT), payload: .manualFix(ManualFixSample(
            latitude: latitude, longitude: longitude, pressedT: MonotonicTimestamp(seconds: pressedT), mapSpanM: 240,
            obdSpeedKmh: 36, obdSpeedT: MonotonicTimestamp(seconds: pressedT - 0.1), speedSource: "obd",
            gateSpeedKmh: 36)))
    }

    /// `seconds` of driving: motion at 50 Hz with a slight yaw, OBD speed
    /// at 5 Hz, clean fixes at 1 Hz for the first `fixesUntil` s only.
    static func drive(_ range: ClosedRange<Double>, fixesUntil: Double = 6) -> [LogEvent] {
        var out: [LogEvent] = []
        var k = Int((range.lowerBound * 50).rounded())
        while Double(k) / 50 <= range.upperBound + 1e-9 {
            let t = Double(k) / 50
            out.append(motion(t, yawRate: 0.002))
            if k % 10 == 5 { out.append(obd(t, kmh: 36)) }
            if k % 50 == 0, k > 0, t <= fixesUntil { out.append(fix(t)) }
            k += 1
        }
        return out
    }

    // MARK: Helpers

    static func feed(_ generation: Int, header: LogHeader, sidecarIn store: LogStore?)
        -> (RecordingNavigationFeed, NavigationTap) {
        let tap = NavigationTap()
        let output: RecordingNavigationFeed.Output
        if let store {
            let recording = store.directory.appendingPathComponent("Drive_navigate\(generation).jsonl.gz")
            output = .recording(recordingURL: recording, sidecarURL: LogStore.navSidecarURL(for: recording))
        } else {
            output = .navigateOnly
        }
        return (RecordingNavigationFeed(generation: generation, header: header, clock: SessionClock(header: header),
                                        output: output, tap: tap), tap)
    }

    func waitUntil(_ seconds: Double = 60, _ condition: () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(Int(seconds * 1000)))
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await condition()
    }

    /// Waits until the service's current run has ingested `count` inputs.
    func ingested(_ service: NavigationService, _ count: Int) async -> Bool {
        await waitUntil { await service.snapshot(at: .zero).stats.inputs == count }
    }

    /// The snapshot without its wall-clock timings (the only fields two
    /// runs of the same inputs may differ in).
    static func deterministic(_ snapshot: NavigationSnapshot) -> NavigationSnapshot {
        var s = snapshot
        s.stats.msPerStep = 0
        s.stats.maxMsPerStep = 0
        s.stats.maxIngestMs = 0
        return s
    }

    /// The current run's snapshots at `times`, timings removed.
    static func snapshots(_ service: NavigationService, at times: [Double]) async -> [NavigationSnapshot] {
        var out: [NavigationSnapshot] = []
        for t in times { out.append(deterministic(await service.snapshot(at: MonotonicTimestamp(seconds: t)))) }
        return out
    }

    static func distanceM(_ snapshot: NavigationSnapshot, _ latitude: Double, _ longitude: Double) -> Double {
        guard let lat = snapshot.latitude, let lon = snapshot.longitude else { return .infinity }
        let north = (lat - latitude) * 111_320, east = (lon - longitude) * 111_320 * cos(latitude * .pi / 180)
        return (north * north + east * east).squareRoot()
    }

    func library(_ dir: URL) -> RoadPackLibrary {
        RoadPackLibrary(source: RoadPackLibrary.directorySource(dir), cacheURL: nil)
    }

    /// A library whose every scan waits for `gate` (and passes it on), so
    /// the test decides at which input roads attach.
    func gatedLibrary(_ dir: URL, gate: DispatchSemaphore) -> RoadPackLibrary {
        let urls = RoadPackLibrary.listing(dir)
        return RoadPackLibrary(source: {
            _ = gate.wait(timeout: .now() + 20)
            gate.signal()
            return urls
        }, cacheURL: nil)
    }

    // MARK: No file

    /// Every path under `root` (recursive), relative to it.
    nonisolated static func listing(_ root: URL) -> Set<String> {
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return [] }
        var out = Set<String>()
        let prefix = root.resolvingSymlinksInPath().path
        for case let url as URL in walker {
            out.insert(String(url.resolvingSymlinksInPath().path.dropFirst(prefix.count)))
        }
        return out
    }

    /// The app's file system as far as this run could touch it: Documents
    /// and Application Support must not change at all (no test writes
    /// there); anywhere in the container (temp included, where other suites
    /// write concurrently) no new file may name this run's `sessionID`.
    struct Footprint {
        static let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        let documents = listing(.documentsDirectory)
        let support = listing(.applicationSupportDirectory)
        let all = listing(home)

        /// What changed since `self` that this run could have written.
        func writtenSince(sessionID: UUID) -> [String] {
            var found: [String] = []
            let now = Footprint()
            found += now.documents.subtracting(documents).map { "Documents" + $0 }
            found += now.support.subtracting(support).map { "Application Support" + $0 }
            let id = Data(sessionID.uuidString.utf8), lower = Data(sessionID.uuidString.lowercased().utf8)
            for path in now.all.subtracting(all) {
                let url = Self.home.appendingPathComponent(path)
                guard let data = try? Data(contentsOf: url), data.count < 50_000_000 else { continue }
                if data.range(of: id) != nil || data.range(of: lower) != nil { found.append(path) }
            }
            return found
        }
    }

    // MARK: Tests

    @Test("A Navigate feed writes nothing: no file or directory, estimates all the same, Finished has no sidecar")
    func navigateWritesNothing() async throws {
        let dir = try RoadPackFixture.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try RoadPackFixture.write(try RoadPackFixture.data(), named: "fixture.roadpack", in: dir)
        let header = Self.header()
        let before = Footprint()
        let service = NavigationService(flushInterval: .milliseconds(1), library: library(dir))
        let (feed, tap) = Self.feed(1, header: header, sidecarIn: nil)
        #expect(feed.output == .navigateOnly && feed.sidecarURL == nil && feed.recordingURL == nil)
        let task = service.start(feed)
        let events = Self.drive(0...8)
        for event in events { tap.record(event) }
        #expect(await ingested(service, events.count))
        #expect(await waitUntil { await service.roadsStatus().libraryScanned })
        let live = await service.snapshot(at: MonotonicTimestamp(seconds: 8))
        #expect(live.initialized && live.sessionID == header.sessionID)
        await service.flush()   // nothing to flush, nothing to create
        tap.finish()
        await task.value

        let finished = try #require(await service.finished.first)
        #expect(finished.sidecarURL == nil)
        #expect(finished.sidecarBytes == 0 && finished.sidecarLinesLost == 0)
        #expect(finished.sidecarFailure == nil, "no sidecar is not a failure")
        #expect(finished.inputs == events.count && finished.estimates >= 7)
        #expect(finished.sessionID == header.sessionID)
        #expect(before.writtenSince(sessionID: header.sessionID) == [])
    }

    @Test("Navigate and Record runs of the same inputs and header give bit-identical estimates; the sidecar is Core's loop")
    func navigateEqualsRecord() async throws {
        let scratch = try ScratchStore()
        defer { scratch.remove() }
        let header = Self.header()
        let events = Self.drive(0...12)
            + [Self.pin(writtenT: 12.05, pressedT: 11.5, latitude: Self.position(11.6).latitude,
                        longitude: Self.position(11.6).longitude)]
            + Self.drive(12.1...16)
        let times = [16, 16.5, 19]

        var results: [(snapshots: [NavigationSnapshot], finished: NavigationService.Finished)] = []
        for (generation, store) in [(1, scratch.store), (2, nil)] as [(Int, LogStore?)] {
            let service = NavigationService()
            let (feed, tap) = Self.feed(generation, header: header, sidecarIn: store)
            let task = service.start(feed)
            for event in events { tap.record(event) }
            #expect(await ingested(service, events.count))
            let snapshots = await Self.snapshots(service, at: times)
            tap.finish()
            await task.value
            results.append((snapshots, try #require(await service.finished.first)))
        }
        let (record, navigate) = (results[0], results[1])
        #expect(record.snapshots.allSatisfy { $0.initialized && $0.estimate != nil })
        #expect(navigate.snapshots == record.snapshots)
        #expect(navigate.finished.inputs == record.finished.inputs)
        #expect(navigate.finished.estimates == record.finished.estimates && record.finished.estimates >= 15)
        #expect(navigate.finished.sidecarURL == nil && record.finished.sidecarURL != nil)

        // The recording's sidecar is what Core's loop gives on these inputs,
        // pin included: the shared path is the replayable one.
        let sidecar = try #require(record.finished.sidecarURL)
        let (comparison, contents) = try await Task.detached {
            try NavigationServiceRoadsTests.compare(sidecarURL: sidecar, header: header, events: events, packs: [])
        }.value
        #expect(comparison.exact, "\(comparison.report(tolerance: .default))")
        #expect(contents.estimates.count == navigate.finished.estimates && contents.pins.count == 1)
    }

    @Test("A pin without a sidecar resets the position exactly as with one")
    func pinResetsWithoutSidecar() async throws {
        let scratch = try ScratchStore()
        defer { scratch.remove() }
        let header = Self.header()
        // Fixes for 6 s, then 30 s on OBD with a yaw the gyro reports but
        // the car never made: hundreds of metres off by the pin.
        var early = Self.drive(0...6)
        var t = 6.02
        while t <= 36 {
            early.append(Self.motion(t, yawRate: 0.05))
            if Int((t * 50).rounded()) % 10 == 5 { early.append(Self.obd(t, kmh: 36)) }
            t = ((t + 0.02) * 50).rounded() / 50
        }
        // The driver's "I'm here", well outside the cloud (~470 m north of
        // the drifted estimate's truth): no particle is compatible, so the
        // engine resets rather than updates.
        let truth = (latitude: Self.position(35.5).latitude + 0.004, longitude: Self.position(35.5).longitude)
        let late = [Self.pin(writtenT: 36.05, pressedT: 35.5, latitude: truth.latitude, longitude: truth.longitude)]
            + (1...25).map { Self.motion(36.05 + Double($0) * 0.02) }

        var runs: [(before: NavigationSnapshot, after: NavigationSnapshot, pins: Int?)] = []
        for (generation, store) in [(1, scratch.store), (2, nil)] as [(Int, LogStore?)] {
            let service = NavigationService()
            let (feed, tap) = Self.feed(generation, header: header, sidecarIn: store)
            let task = service.start(feed)
            for event in early { tap.record(event) }
            #expect(await ingested(service, early.count))
            let before = Self.deterministic(await service.snapshot(at: MonotonicTimestamp(seconds: 36)))
            for event in late { tap.record(event) }
            #expect(await ingested(service, early.count + late.count))
            let after = Self.deterministic(await service.snapshot(at: MonotonicTimestamp(seconds: 36.6)))
            tap.finish()
            await task.value
            let pins = try feed.sidecarURL.map { try NavSidecar.read(contentsOf: $0).pins.count }
            runs.append((before, after, pins))
        }
        let (record, navigate) = (runs[0], runs[1])
        #expect(Self.distanceM(record.before, truth.latitude, truth.longitude) > 300, "far from the pin before it")
        // About 11 m driven between the tap and 36.6 s, plus the pin's own spread.
        #expect(Self.distanceM(record.after, truth.latitude, truth.longitude) < 40,
                "reset to the pin: \(Self.distanceM(record.after, truth.latitude, truth.longitude)) m")
        #expect(navigate.before == record.before)
        #expect(navigate.after == record.after)
        #expect(record.pins == 1 && navigate.pins == nil, "the pin's sidecar line goes nowhere in Navigate")
    }

    @Test("Roads attach mid-run without a sidecar, at the same input and with the same result as with one")
    func roadsAttachWithoutSidecar() async throws {
        let scratch = try ScratchStore()
        defer { scratch.remove() }
        let dir = try RoadPackFixture.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let pack = try RoadPackFixture.write(try RoadPackFixture.data(), named: "fixture.roadpack", in: dir)
        let header = Self.header()
        let early = Self.drive(0...2), late = Self.drive(2.02...10)
        let times = [10, 10.5, 12]
        let before = Footprint()

        struct Result {
            var status: NavigationService.RoadsStatus
            var snapshots: [NavigationSnapshot]
            var finished: NavigationService.Finished
            var roadPacksRows: [String]
        }
        var results: [Result] = []
        for (generation, store) in [(1, scratch.store), (2, nil)] as [(Int, LogStore?)] {
            let gate = DispatchSemaphore(value: 0)
            let service = NavigationService(library: gatedLibrary(dir, gate: gate))
            let made = Self.feed(generation, header: header, sidecarIn: store)
            var feed = made.0
            let tap = made.1
            let rows = RowCollector()
            feed.recordRoadPacks = { rows.add($0) }
            let task = service.start(feed)
            for event in early { tap.record(event) }
            #expect(await ingested(service, early.count))
            #expect(await waitUntil { await service.roadsStatus().selectionPending }, "a request waits on the scan")
            #expect(!(await service.roadsStatus().libraryScanned))
            gate.signal()
            #expect(await waitUntil { await service.roadsStatus().inUse })
            let status = await service.roadsStatus()
            for event in late { tap.record(event) }
            #expect(await ingested(service, early.count + late.count))
            let snapshots = await Self.snapshots(service, at: times)
            tap.finish()
            await task.value
            results.append(Result(status: status, snapshots: snapshots,
                                  finished: try #require(await service.finished.first), roadPacksRows: rows.rows))
        }
        let (record, navigate) = (results[0], results[1])
        #expect(navigate.status.active && navigate.status.libraryScanned)
        #expect(navigate.status == record.status)
        #expect(navigate.status.packNames == ["fixture.roadpack"])
        #expect(navigate.snapshots == record.snapshots)
        #expect(navigate.snapshots.allSatisfy { $0.estimate?.onRoadShare != nil })
        #expect(navigate.finished.roadPackNames == record.finished.roadPackNames)
        #expect(navigate.finished.roadsActiveAtS == record.finished.roadsActiveAtS)
        #expect(navigate.finished.roadSetHashPrefix == record.finished.roadSetHashPrefix)
        #expect(navigate.finished.selectionAttempts == record.finished.selectionAttempts)
        #expect(navigate.finished.sidecarURL == nil && navigate.finished.sidecarFailure == nil)
        // The service reports the scan whatever the run; Navigate's session
        // passes a no-op there (no recording, no row).
        #expect(navigate.roadPacksRows == record.roadPacksRows && navigate.roadPacksRows.count == 1)

        let sidecar = try #require(record.finished.sidecarURL)
        let (comparison, contents) = try await Task.detached {
            try NavigationServiceRoadsTests.compare(sidecarURL: sidecar, header: header, events: early + late,
                                                    packs: [pack])
        }.value
        #expect(contents.roads?.afterInputs == early.count, "attached where the gate opened")
        #expect(comparison.exact, "\(comparison.report(tolerance: .default))")
        // Only the recording's own scratch directory got files.
        let written = before.writtenSince(sessionID: header.sessionID)
        #expect(written.allSatisfy { $0.contains(scratch.store.directory.lastPathComponent) }, "\(written)")
        #expect(written.count == 1, "the recording run's sidecar only: \(written)")
    }
}

/// Collects `recordRoadPacks` calls from the service's task.
final class RowCollector: Sendable {
    private let stored = OSAllocatedUnfairLock<[String]>(initialState: [])

    func add(_ row: String) { stored.withLock { $0.append(row) } }
    var rows: [String] { stored.withLock { $0 } }
}
