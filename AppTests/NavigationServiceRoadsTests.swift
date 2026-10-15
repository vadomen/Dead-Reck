import DriveLoggerCore
import Foundation
import Testing

@testable import DriveLogger

// N3.3 item 5: roads attach to a running recording, asynchronously, at an
// input boundary; the sidecar equals Core's loop with the same packs
// attached at the sidecar's afterInputs.

@Suite("Navigation service roads", .serialized)
@MainActor
struct NavigationServiceRoadsTests {
    static func header(_ n: Int) -> LogHeader {
        LogHeader(
            sessionID: UUID(uuidString: "00000000-0000-4000-8000-0000000000C\(n)")!,
            startedAt: Date(timeIntervalSince1970: 0), referenceUptimeSeconds: 100,
            app: AppIdentity(name: "DriveLogger", version: "0.0", build: "7"),
            device: DeviceIdentity(model: "test", systemName: "iOS", systemVersion: "17"))
    }

    /// Fixes at 1, 3 and 5 s with motion every 0.5 s in between.
    static func events(_ range: ClosedRange<Double>) -> [LogEvent] {
        var out: [LogEvent] = []
        var t = range.lowerBound
        while t <= range.upperBound + 1e-9 {
            if t.truncatingRemainder(dividingBy: 2) == 1 {
                out.append(NavigationServiceTests.fix(t))
            } else {
                out.append(NavigationServiceTests.motion(t))
            }
            t += 0.5
        }
        return out
    }

    func makeFeed(_ n: Int, scratch: ScratchStore) -> (RecordingNavigationFeed, NavigationTap) {
        let tap = NavigationTap()
        let recording = scratch.store.directory.appendingPathComponent("Drive_roads\(n).jsonl.gz")
        let header = Self.header(n)
        return (RecordingNavigationFeed(generation: n, header: header, clock: SessionClock(header: header),
                                        recordingURL: recording, sidecarURL: LogStore.navSidecarURL(for: recording),
                                        tap: tap), tap)
    }

    func waitUntil(_ seconds: Double = 10, _ condition: () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(Int(seconds * 1000)))
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await condition()
    }

    func library(_ dir: URL) -> RoadPackLibrary {
        RoadPackLibrary(source: RoadPackLibrary.directorySource(dir), cacheURL: nil)
    }

    /// Core's loop over `events` (a 2000-particle replay, slow in Debug)
    /// compared with the sidecar, off the main actor so it doesn't stall the
    /// main-actor work of tests running alongside (R32.2-1).
    func comparison(feed: RecordingNavigationFeed, events: [LogEvent], packs: [URL]) async throws
        -> (SidecarComparison, NavSidecar.Contents) {
        let sidecarURL = feed.sidecarURL
        let header = feed.header
        return try await Task.detached {
            try Self.compare(sidecarURL: sidecarURL, header: header, events: events, packs: packs)
        }.value
    }

    nonisolated static func compare(sidecarURL: URL, header: LogHeader, events: [LogEvent], packs: [URL]) throws
        -> (SidecarComparison, NavSidecar.Contents) {
        let contents = try NavSidecar.read(contentsOf: sidecarURL)
        let config = NavigationConfig(seed: NavigationSeed.derive(header: header))
        let inputs = events.compactMap { NavigationInput($0) }
        var roads: ReplayRoadSet?
        var attach = ReplayRoadAttach.live
        if !packs.isEmpty {
            roads = ReplayRoadSet(try RoadNetwork(packs: packs.map { try RoadPack(contentsOf: $0) }))
        }
        if let live = contents.roads { attach = .afterInputs(live.afterInputs) }
        let lines = NavigationReplay.liveLines(inputs: inputs, sessionID: header.sessionID, config: config,
                                               appBuild: header.app.build, roads: roads,
                                               attach: roads == nil ? .live : attach)
        return (SidecarComparison(sidecar: contents, replay: lines, replayConfig: config,
                                  givenRoadSetHash: roads?.roadSetHashHex), contents)
    }

    @Test("A covering pack attaches mid-recording; the sidecar equals Core's loop with the pack attached at afterInputs")
    func coveringPackAttaches() async throws {
        let scratch = try ScratchStore()
        defer { scratch.remove() }
        let dir = try RoadPackFixture.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let pack = try RoadPackFixture.write(try RoadPackFixture.data(), named: "fixture.roadpack", in: dir)
        let service = NavigationService(library: library(dir))
        let (feed, tap) = makeFeed(1, scratch: scratch)
        let task = service.start(feed)

        let early = Self.events(1...2)
        for event in early { tap.record(event) }
        // Not blocked on loading: the inputs are consumed whether or not the pack is ready.
        #expect(await waitUntil { await service.roadsStatus().inUse })
        let status = await service.roadsStatus()
        #expect(status.packNames == ["fixture.roadpack"] && status.recording)
        #expect(status.packHashPrefixes.first?.count == 8 && status.roadSetHashPrefix?.count == 8)
        let late = Self.events(2.5...7)
        for event in late { tap.record(event) }
        tap.finish()
        await task.value

        let (comparison, contents) = try await comparison(feed: feed, events: early + late, packs: [pack])
        let roads = try #require(contents.roads, "the sidecar has a roads line")
        #expect(roads.afterInputs >= 1 && roads.afterInputs <= early.count + late.count)
        #expect(roads.roads.count == 1 && roads.roadSetHash.hasPrefix(status.roadSetHashPrefix ?? "?"))
        #expect(comparison.exact, "\(comparison.report(tolerance: .default))")
        let finished = try #require(await service.finished.first)
        #expect(finished.roadPackNames == ["fixture.roadpack"] && finished.roadsActiveAtS != nil)
        #expect(await service.roadsStatus().inUse == true, "the last finished recording's roads stay readable")
    }

    @Test("No packs: the sidecar is the no-roads loop's, with no roads line")
    func noPacks() async throws {
        let scratch = try ScratchStore()
        defer { scratch.remove() }
        let dir = try RoadPackFixture.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let service = NavigationService(library: library(dir))
        let (feed, tap) = makeFeed(2, scratch: scratch)
        let task = service.start(feed)
        let events = Self.events(1...7)
        for event in events { tap.record(event) }
        tap.finish()
        await task.value

        let (comparison, contents) = try await comparison(feed: feed, events: events, packs: [])
        #expect(contents.roads == nil)
        #expect(comparison.exact, "\(comparison.report(tolerance: .default))")
        #expect(await service.roadsStatus().inUse == false)
    }

    @Test("Corrupt and truncated packs are refused; the run continues without roads")
    func badPacks() async throws {
        let scratch = try ScratchStore()
        defer { scratch.remove() }
        let dir = try RoadPackFixture.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let good = try RoadPackFixture.data()
        try RoadPackFixture.write(good.prefix(good.count / 2), named: "truncated.roadpack", in: dir)
        var corrupt = good
        corrupt[corrupt.count - 16] ^= 0xFF
        try RoadPackFixture.write(corrupt, named: "corrupt.roadpack", in: dir)
        let lib = library(dir)
        let service = NavigationService(library: lib)
        let (feed, tap) = makeFeed(3, scratch: scratch)
        let task = service.start(feed)
        let events = Self.events(1...7)
        for event in events { tap.record(event) }
        tap.finish()
        await task.value

        let packs = await lib.status().packs
        #expect(packs.count == 2 && packs.allSatisfy { !$0.verified && $0.refusal != nil })
        let (comparison, contents) = try await comparison(feed: feed, events: events, packs: [])
        #expect(contents.roads == nil)
        #expect(comparison.exact, "\(comparison.report(tolerance: .default))")
    }

    @Test("Covering packs that cannot be combined: the reason is recorded, the run goes on without roads")
    func refusedSet() async throws {
        let scratch = try ScratchStore()
        defer { scratch.remove() }
        let dir = try RoadPackFixture.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try RoadPackFixture.write(try RoadPackFixture.data(cellSizeM: 64), named: "a.roadpack", in: dir)
        try RoadPackFixture.write(try RoadPackFixture.data(cellSizeM: 128), named: "b.roadpack", in: dir)
        let service = NavigationService(library: library(dir))
        let (feed, tap) = makeFeed(4, scratch: scratch)
        let task = service.start(feed)
        let events = Self.events(1...7)
        for event in Self.events(1...2) { tap.record(event) }
        #expect(await waitUntil { await service.roadsStatus().refusal != nil })
        for event in Self.events(2.5...7) { tap.record(event) }
        tap.finish()
        await task.value

        let (comparison, contents) = try await comparison(feed: feed, events: events, packs: [])
        #expect(contents.roads == nil)
        #expect(comparison.exact, "\(comparison.report(tolerance: .default))")
        let finished = try #require(await service.finished.first)
        #expect(finished.roadsRefusal?.contains("a.roadpack") == true)
    }

    @Test("A selection finishing after its recording ended is dropped")
    func lateResultDropped() async throws {
        let scratch = try ScratchStore()
        defer { scratch.remove() }
        let dir = try RoadPackFixture.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try RoadPackFixture.write(try RoadPackFixture.data(), named: "fixture.roadpack", in: dir)
        let gate = DispatchSemaphore(value: 0)
        let urls = RoadPackLibrary.listing(dir)
        // Each scan passes the gate on, so a second scan never waits out the timeout.
        let slow = RoadPackLibrary(source: {
            _ = gate.wait(timeout: .now() + 20)
            gate.signal()
            return urls
        }, cacheURL: nil)
        let service = NavigationService(library: slow)
        let (feed, tap) = makeFeed(5, scratch: scratch)
        let task = service.start(feed)
        let events = Self.events(1...3)
        for event in events { tap.record(event) }
        tap.finish()
        await task.value
        gate.signal()
        _ = await slow.candidates()
        try await Task.sleep(for: .milliseconds(100))

        let (_, contents) = try await comparison(feed: feed, events: events, packs: [])
        #expect(contents.roads == nil)
        #expect(await service.finished.first?.roadPackNames == [])
    }
}
