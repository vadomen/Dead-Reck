import DriveLoggerCore
import Foundation
import Testing

@testable import DriveLogger

/// Prompt 47 (UX-7) hard constraint, app side: an OBD Navigate run (and a
/// Record run) through the app's `NavigationService` is unchanged by the
/// no-OBD mode. Deterministic simulated OBD inputs go through the service
/// exactly as the app hands them over (`RecordingNavigationFeed`, the
/// service's `consume`/`begin`/`ingest`), and the estimates are compared
/// with golden values **captured on nav-noobd-47 at cb6fe55** (the Core
/// commit of prompt 47; the app code there is that of nav-noobd 5468cd9,
/// before any app edit of prompt 47): FNV-1a 64 over every checked
/// estimate's bit patterns, plus a few readable values in metres from the
/// drive's local plane. A difference means an OBD run's estimates changed.
///
/// Sources: the demo drive's simulated car (`DemoSensorModel`: the app's
/// simulated OBD adapter, IMU and GNSS-then-network fixes, in the order the
/// demo's sequencer feeds them) with the bundled demo pack selected inline,
/// as the demo does; and a synthetic OBD drive from (0, 0) with a pin
/// (`NavigationServiceNavigateTests.drive`), as a Navigate and as a Record
/// feed. No real place, date or recording.
@Suite("Navigate OBD run golden (prompt 47, captured at cb6fe55)", .serialized)
@MainActor
struct NavigateOBDGoldenAppTests {
    /// FNV-1a 64.
    struct Hash {
        var value: UInt64 = 0xcbf2_9ce4_8422_2325
        mutating func add(_ bytes: some Sequence<UInt8>) {
            for b in bytes {
                value ^= UInt64(b)
                value = value &* 0x0000_0100_0000_01b3
            }
        }
        mutating func add(_ x: UInt64) { withUnsafeBytes(of: x.littleEndian) { add($0) } }
        mutating func add(_ x: Double) { add(x.bitPattern) }
        mutating func add(_ x: Double?) { if let x { add(1 as UInt64); add(x) } else { add(0 as UInt64) } }
        mutating func add(_ x: Bool) { add(x ? 1 as UInt64 : 0) }
        mutating func add(_ e: NavigationEstimate?) {
            guard let e else { add(0 as UInt64); return }
            add(UInt64(bitPattern: e.t.nanoseconds))
            for x in [e.east, e.north, e.latitude, e.longitude, e.headingDeg, e.headingStdDeg,
                      e.ellipse.semiMajorM, e.ellipse.semiMinorM, e.ellipse.orientationDeg, e.speedMps,
                      e.speedScaleMean, e.speedScaleStd, e.effectiveSampleSize] { add(x) }
            add(e.converged)
            add(e.stationary)
            add(e.onRoadShare)
            add(UInt64(bitPattern: Int64(e.matchedEdge?.edge ?? -1)))
            add(UInt64(bitPattern: e.matchedEdge?.osmWayID ?? -1))
        }
        mutating func add(_ s: NavigationSnapshot) {
            add(s.estimate)
            add(UInt64(s.stats.inputs))
            add(UInt64(s.stats.steps))
            add(s.gnssInUse)
            add(s.gpsSwitchedOff)
        }
    }

    static func header(_ id: UUID) -> LogHeader {
        LogHeader(
            sessionID: id, startedAt: Date(timeIntervalSince1970: 0), referenceUptimeSeconds: 100,
            app: AppIdentity(name: "DriveLogger", version: "0.0", build: "7"),
            device: DeviceIdentity(model: "test", systemName: "iOS", systemVersion: "17"))
    }

    static func until(_ seconds: Double = 120, _ condition: () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(Int(seconds * 1000)))
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await condition()
    }

    // MARK: Golden values (captured at cb6fe55; never edit to make a change pass)

    static let demoHash: UInt64 = 0x5c4579ec67f62188
    static let demoEast90 = -203.6660613804924
    static let demoNorth90 = 791.3316915852772
    static let demoSemiMajor90 = 25.72350956331775
    static let demoEstimates = 90
    static let syntheticNavigateHash: UInt64 = 0x73d2ea00a69d2de2
    static let syntheticRecordHash: UInt64 = 0x73d2ea00a69d2de2
    static let syntheticEast19 = 154.47987981150405
    static let syntheticNorth19 = 79.17885978508563

    @Test("Demo car (simulated OBD, IMU, GNSS then network fixes, demo pack inline): an OBD Navigate run's estimates at 20/45/70/90 s equal the golden captured at cb6fe55")
    func demoOBDNavigateRunIsUnchanged() async throws {
        let url = try #require(DemoRoadPack.url(in: .main))
        let pack = try DemoRoadPack.open(at: url)
        let model = DemoSensorModel(drive: try DemoDrive(pack: pack))
        let candidates = [try RoadPackSelection.Candidate(name: url.lastPathComponent, pack: pack)]
        let service = NavigationService(library: nil, restoreStore: nil)
        await service.useInlineRoads(candidates)
        let header = Self.header(DemoSensorModel.sessionID)
        let tap = NavigationTap(bufferLimit: 1 << 18)
        let task = service.start(RecordingNavigationFeed(
            generation: 1, header: header, clock: SessionClock(header: header), output: .navigateOnly, tap: tap))
        let inputs = model.canonicalInputs(until: 90)
        var hash = Hash()
        var fed = 0
        var last: NavigationSnapshot?
        for checkpoint in [20.0, 45, 70, 90] {
            let end = MonotonicTimestamp(seconds: checkpoint)
            while fed < inputs.count, inputs[fed].timestamp <= end {
                tap.record(inputs[fed].event)
                fed += 1
            }
            let count = fed
            #expect(await Self.until { await service.snapshot(at: .zero).stats.inputs == count })
            let snapshot = await service.snapshot(at: end)
            hash.add(snapshot)
            last = snapshot
        }
        tap.finish()
        await task.value
        let finished = try #require(await service.finished.first)
        let estimate = try #require(last?.estimate)
        #expect(finished.roadPackNames == [url.lastPathComponent])
        // R85.1-3: an OBD Navigate feed's engine runs the OBD config.
        #expect(finished.configHash == NavigationConfig(seed: NavigationSeed.derive(header: header)).hashHex)
        #expect(hash.value == Self.demoHash, "hash 0x\(String(hash.value, radix: 16))")
        #expect(finished.estimates == Self.demoEstimates, "estimates \(finished.estimates)")
        #expect(estimate.east == Self.demoEast90, "east \(estimate.east)")
        #expect(estimate.north == Self.demoNorth90, "north \(estimate.north)")
        #expect(estimate.ellipse.semiMajorM == Self.demoSemiMajor90, "semiMajor \(estimate.ellipse.semiMajorM)")
    }

    @Test("Synthetic OBD drive with a pin, as a Navigate feed and as a Record feed: estimates at 16/16.5/19 s equal the golden captured at cb6fe55")
    func syntheticOBDRunsAreUnchanged() async throws {
        let scratch = try ScratchStore()
        defer { scratch.remove() }
        typealias N = NavigationServiceNavigateTests
        let header = Self.header(try #require(UUID(uuidString: "00000000-0000-4000-8000-000000000047")))
        let events = N.drive(0...12)
            + [N.pin(writtenT: 12.05, pressedT: 11.5, latitude: N.position(11.6).latitude,
                     longitude: N.position(11.6).longitude)]
            + N.drive(12.1...16)
        var hashes: [UInt64] = []
        var lastEstimates: [NavigationEstimate] = []
        for (generation, store) in [(1, nil), (2, scratch.store)] as [(Int, LogStore?)] {
            let service = NavigationService()
            let (feed, tap) = N.feed(generation, header: header, sidecarIn: store)
            let task = service.start(feed)
            for event in events { tap.record(event) }
            #expect(await Self.until { await service.snapshot(at: .zero).stats.inputs == events.count })
            var hash = Hash()
            var last: NavigationSnapshot?
            for t in [16, 16.5, 19] {
                let snapshot = await service.snapshot(at: MonotonicTimestamp(seconds: t))
                hash.add(snapshot)
                last = snapshot
            }
            tap.finish()
            await task.value
            // R85.1-3: the Navigate feed's and the Record feed's engines
            // both run the OBD config.
            let finished = try #require(await service.finished.first)
            #expect(!feed.noOBD && finished.configHash == NavigationConfig(seed: NavigationSeed.derive(header: header)).hashHex,
                    "generation \(generation)")
            hashes.append(hash.value)
            lastEstimates.append(try #require(last?.estimate))
        }
        #expect(hashes[0] == Self.syntheticNavigateHash, "navigate 0x\(String(hashes[0], radix: 16))")
        #expect(hashes[1] == Self.syntheticRecordHash, "record 0x\(String(hashes[1], radix: 16))")
        #expect(lastEstimates[0].east == Self.syntheticEast19, "east \(lastEstimates[0].east)")
        #expect(lastEstimates[0].north == Self.syntheticNorth19, "north \(lastEstimates[0].north)")
    }
}
