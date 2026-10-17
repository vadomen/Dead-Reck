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
            // C0…C9 as before for n < 10; n up to 63 stays a valid UUID.
            sessionID: UUID(uuidString: String(format: "00000000-0000-4000-8000-0000000000%02lX", 0xC0 + n))!,
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

    // MARK: roadsSelection lines

    /// The recording's `roadsSelection` outcomes, in file order.
    func outcomes(_ feed: RecordingNavigationFeed) throws -> [NavSidecar.RoadsSelection.Outcome] {
        try NavSidecar.read(contentsOf: feed.sidecarURL).roadsSelections.map(\.outcome)
    }

    @Test("A selected attempt writes roadsSelection, then roads, right after it")
    func selectedLine() async throws {
        let scratch = try ScratchStore()
        defer { scratch.remove() }
        let dir = try RoadPackFixture.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try RoadPackFixture.write(try RoadPackFixture.data(), named: "fixture.roadpack", in: dir)
        let service = NavigationService(library: library(dir))
        let (feed, tap) = makeFeed(6, scratch: scratch)
        let task = service.start(feed)
        for event in Self.events(1...2) { tap.record(event) }
        #expect(await waitUntil { await service.roadsStatus().inUse })
        for event in Self.events(2.5...7) { tap.record(event) }
        tap.finish()
        await task.value

        #expect(try outcomes(feed) == [.selected])
        let contents = try NavSidecar.read(contentsOf: feed.sidecarURL)
        let line = try #require(contents.roadsSelections.first)
        #expect(line.packs == ["fixture.roadpack"] && line.candidates?.first?.covering == true)
        #expect(contents.roads != nil)
        let text = try String(contentsOf: feed.sidecarURL, encoding: .utf8)
        let kinds = text.split(separator: "\n").compactMap { $0.contains("\"roadsSelection\"") ? "s" : $0.contains("\"roads\"") ? "r" : nil }
        #expect(kinds.joined() == "sr", "roadsSelection is followed by roads")
    }

    @Test("A pack that covers nowhere near the fix: noneCovering")
    func noneCoveringLine() async throws {
        let scratch = try ScratchStore()
        defer { scratch.remove() }
        let dir = try RoadPackFixture.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try RoadPackFixture.write(try RoadPackFixture.data(latShiftE7: 1_000_000), named: "far.roadpack", in: dir)
        let service = NavigationService(library: library(dir))
        let (feed, tap) = makeFeed(7, scratch: scratch)
        let task = service.start(feed)
        for event in Self.events(1...2) { tap.record(event) }
        #expect(await waitUntil { await service.selectionAttempts >= 1 })
        for event in Self.events(2.5...7) { tap.record(event) }
        tap.finish()
        await task.value

        let found = try outcomes(feed)
        #expect(found.first == .noneCovering && !found.contains(.selected))
        #expect(try NavSidecar.read(contentsOf: feed.sidecarURL).roads == nil)
    }

    @Test("A refused set writes refused; the same set refused again is not rebuilt and, being a repeat, is counted and written at the end")
    func refusedLines() async throws {
        let scratch = try ScratchStore()
        defer { scratch.remove() }
        let dir = try RoadPackFixture.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try RoadPackFixture.write(try RoadPackFixture.data(cellSizeM: 64), named: "a.roadpack", in: dir)
        try RoadPackFixture.write(try RoadPackFixture.data(cellSizeM: 128), named: "b.roadpack", in: dir)
        let service = NavigationService(library: library(dir))
        let (feed, tap) = makeFeed(8, scratch: scratch)
        let task = service.start(feed)
        for event in Self.events(1...2) { tap.record(event) }
        #expect(await waitUntil { await service.selectionAttempts >= 1 })
        for event in Self.events(2.5...4) { tap.record(event) }
        #expect(await waitUntil { await service.selectionAttempts >= 2 })
        tap.finish()
        await task.value

        let lines = try NavSidecar.read(contentsOf: feed.sidecarURL).roadsSelections
        let refused = lines.filter { $0.outcome != .unfinished }
        #expect(refused.count == 2 && refused.allSatisfy { $0.outcome == .refused })
        #expect(refused.allSatisfy { $0.packs == ["a.roadpack", "b.roadpack"] && $0.reason != nil })
        #expect(Set(refused.compactMap(\.reason)).count == 1, "the repeat carries the remembered reason")
        #expect(refused[0].repeats == nil && refused[1].isRepeat(of: refused[0]))
        let finished = try #require(await service.finished.first)
        #expect(lines.reduce(0) { $0 + $1.attempts } == finished.selectionAttempts && finished.selectionAttempts >= 2)
        #expect(lines.count == finished.selectionLines)
    }

    @Test("Identical attempts: the first line at once, the repeats as one line flushed at the end of the recording (after the last estimate, before any unfinished line)")
    func repeatsFlushedAtEnd() async throws {
        let scratch = try ScratchStore()
        defer { scratch.remove() }
        let dir = try RoadPackFixture.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let service = NavigationService(library: library(dir))
        let (feed, tap) = makeFeed(10, scratch: scratch)
        let task = service.start(feed)
        // One fix per batch, each attempt finished before the next fix.
        for event in Self.events(1...2) { tap.record(event) }
        #expect(await waitUntil { await service.selectionAttempts >= 1 })
        for event in Self.events(2.5...4) { tap.record(event) }
        #expect(await waitUntil { await service.selectionAttempts >= 2 })
        for event in Self.events(4.5...6) { tap.record(event) }
        #expect(await waitUntil { await service.selectionAttempts >= 3 })
        #expect(await service.lastAttemptOutcome == .noPacks)
        tap.finish()
        await task.value

        let lines = try NavSidecar.read(contentsOf: feed.sidecarURL).roadsSelections
        let finished = try #require(await service.finished.first)
        #expect(lines.reduce(0) { $0 + $1.attempts } == finished.selectionAttempts && finished.selectionAttempts >= 3)
        #expect(lines.count == finished.selectionLines)
        let noPacks = lines.filter { $0.outcome == .noPacks }
        #expect(noPacks.count == 2 && lines.prefix(2) == noPacks[...], "the noPacks lines come first")
        #expect(lines.dropFirst(2).allSatisfy { $0.outcome == .unfinished } && lines.count <= 3)
        let first = try #require(noPacks.first), repeats = try #require(noPacks.last)
        #expect(first.repeats == nil && first.firstT == nil)
        #expect((repeats.repeats ?? 0) >= 2 && repeats.firstT.map { $0 > first.t && $0 < repeats.t } == true)
        // The repeats line was written at the end: after every estimate.
        let text = try String(contentsOf: feed.sidecarURL, encoding: .utf8).split(separator: "\n")
        let lastEstimate = try #require(text.lastIndex { $0.contains(#""kind":"estimate""#) })
        let repeatsLine = try #require(text.firstIndex { $0.contains(#""repeats":"#) })
        #expect(repeatsLine > lastEstimate, "flushed at the end, not where the repeats happened")
    }

    @Test("R34.1-3: with a slow rescan at Start, an earlier empty scan never shows 'No road packs'; this recording's own scan decides")
    func noPacksWaitsForTheRecordingsRescan() async throws {
        let scratch = try ScratchStore()
        defer { scratch.remove() }
        let dir = try RoadPackFixture.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let packs = library(dir)
        // The launch scan finds nothing; then a pack is pushed.
        #expect(await packs.rescan().isEmpty)
        try RoadPackFixture.write(try RoadPackFixture.data(), named: "pushed.roadpack", in: dir)
        // The recording's rescan starts a second late: the window in which
        // the library still shows the launch scan, finished and idle.
        let service = NavigationService(library: packs, libraryRescan: { library in
            try? await Task.sleep(for: .seconds(1))
            return await library.rescan()
        })
        let (feed, tap) = makeFeed(20, scratch: scratch)
        let task = service.start(feed)
        #expect(await waitUntil { await service.roadsStatus().recording })
        #expect(!(await service.roadsStatus().libraryScanned))
        let stale = await packs.status()
        #expect(stale.scansCompleted == 1 && !stale.scanning && stale.packs.isEmpty,
                "the earlier scan: finished, idle, no pack (the old rule read this as scanned)")
        #expect(await RoadsWarning.current(service: service, library: packs) == nil)
        #expect(await waitUntil(5) { await service.roadsStatus().libraryScanned })
        #expect(await packs.status().packs.filter(\.verified).count == 1)
        #expect(await RoadsWarning.current(service: service, library: packs) == nil)
        tap.finish()
        await task.value
        #expect(await RoadsWarning.current(service: service, library: packs) == nil, "not recording")
        #expect(!(await service.roadsStatus().libraryScanned), "a finished recording")

        // Still empty after this recording's own scan: the line shows.
        try FileManager.default.removeItem(at: dir.appendingPathComponent("pushed.roadpack"))
        let (next, nextTap) = makeFeed(21, scratch: scratch)
        let nextTask = service.start(next)
        #expect(await waitUntil { await service.roadsStatus().recording })
        #expect(await RoadsWarning.current(service: service, library: packs) == nil, "before its rescan returns")
        #expect(await waitUntil(5) { await service.roadsStatus().libraryScanned })
        #expect(await RoadsWarning.current(service: service, library: packs) == RoadsWarning.noPacks)
        nextTap.finish()
        await nextTask.value
    }

    @Test("An empty library writes noPacks")
    func noPacksLine() async throws {
        let scratch = try ScratchStore()
        defer { scratch.remove() }
        let dir = try RoadPackFixture.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let service = NavigationService(library: library(dir))
        let (feed, tap) = makeFeed(9, scratch: scratch)
        let task = service.start(feed)
        for event in Self.events(1...2) { tap.record(event) }
        #expect(await waitUntil { await service.selectionAttempts >= 1 })
        for event in Self.events(2.5...7) { tap.record(event) }
        tap.finish()
        await task.value

        let found = try outcomes(feed)
        #expect(found.first == .noPacks && found.allSatisfy { $0 == .noPacks || $0 == .unfinished })
    }

    @Test("A recording that ends with a selection in flight writes unfinished, before the sidecar closes")
    func unfinishedLine() async throws {
        let scratch = try ScratchStore()
        defer { scratch.remove() }
        let dir = try RoadPackFixture.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try RoadPackFixture.write(try RoadPackFixture.data(), named: "fixture.roadpack", in: dir)
        let gate = DispatchSemaphore(value: 0)
        let urls = RoadPackLibrary.listing(dir)
        let slow = RoadPackLibrary(source: {
            _ = gate.wait(timeout: .now() + 20)
            gate.signal()
            return urls
        }, cacheURL: nil)
        let service = NavigationService(library: slow)
        let (feed, tap) = makeFeed(0, scratch: scratch)
        let task = service.start(feed)
        for event in Self.events(1...3) { tap.record(event) }
        tap.finish()
        await task.value
        gate.signal()
        _ = await slow.candidates()
        try await Task.sleep(for: .milliseconds(100))

        #expect(try outcomes(feed) == [.unfinished])
        #expect(try NavSidecar.read(contentsOf: feed.sidecarURL).roads == nil)
    }
}
