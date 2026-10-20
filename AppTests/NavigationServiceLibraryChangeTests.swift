import DriveLoggerCore
import Foundation
import Testing

@testable import DriveLogger

// Prompt 38 item A: a pack installed while a run is going is offered to it
// at once (a `libraryChanged` request): a run without roads attaches it, a
// run with roads extends them; the map's roads warning follows the run's
// roads; the sidecar (v3, several `roads` lines) compares exact with Core's
// loop following those lines. Synthetic packs near (0, 0) only.

@Suite("Navigation service: library changes during a run (prompt 38)", .serialized)
@MainActor
struct NavigationServiceLibraryChangeTests {
    typealias Roads = NavigationServiceRoadsTests

    let helper = NavigationServiceRoadsTests()

    @Test("No roads (noneCovering, warning shown); a covering pack installed mid-run attaches with no new input (libraryChanged), the warning clears, and the sidecar compares exact")
    func installAttachesToRunWithoutRoads() async throws {
        let scratch = try ScratchStore()
        defer { scratch.remove() }
        let dir = try RoadPackFixture.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try RoadPackFixture.write(try RoadPackFixture.data(latShiftE7: 1_000_000), named: "far.roadpack", in: dir)
        let library = helper.library(dir)
        let service = NavigationService(library: library)
        let (feed, tap) = helper.makeFeed(40, scratch: scratch)
        let task = service.start(feed)
        let early = Roads.events(1...2)
        for event in early { tap.record(event) }
        #expect(await helper.waitUntil {
            let attempts = await service.selectionAttempts, syncs = await service.librarySyncs
            return attempts >= 1 && syncs >= 1
        })
        #expect(await service.roadsStatus().lastOutcome == .noneCovering)
        #expect(await RoadsWarning.current(service: service, library: library) == RoadsWarning.noneCovering)

        // The download: a covering pack lands and the library rescans.
        let covering = try RoadPackFixture.write(try RoadPackFixture.data(), named: "near.roadpack", in: dir)
        await library.rescan()
        let inputs = await service.snapshot().stats.inputs
        #expect(await helper.waitUntil { await service.roadsStatus().inUse }, "attached with no new input")
        #expect(await service.snapshot().stats.inputs == inputs)
        #expect(await service.libraryChangesOffered == 1)
        #expect(await service.roadsStatus().packNames == ["near.roadpack"])
        #expect(await RoadsWarning.current(service: service, library: library) == nil, "the banner follows the run's roads")
        #expect(await RoadsWarning.attributionCurrent(service: service))

        let late = Roads.events(2.5...6)
        for event in late { tap.record(event) }
        tap.finish()
        await task.value

        let (comparison, contents) = try await helper.comparison(feed: feed, events: early + late, packs: [covering])
        #expect(contents.header.sidecarVersion == 3 && contents.roads.count == 1)
        #expect(contents.roads.first?.afterInputs == inputs)
        let selected = try #require(contents.roadsSelections.first { $0.outcome == .selected })
        #expect(selected.trigger == .libraryChanged && selected.packs == ["near.roadpack"])
        #expect(comparison.exact, "\(comparison.report(tolerance: .default))")
    }

    @Test("Roads attached; a second covering pack installed mid-run extends the set (two roads lines, the second the whole set), Diagnostics shows it, and the sidecar compares exact with both packs given")
    func installExtendsAttachedRoads() async throws {
        let scratch = try ScratchStore()
        defer { scratch.remove() }
        let dir = try RoadPackFixture.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = try RoadPackFixture.write(try RoadPackFixture.data(), named: "a.roadpack", in: dir)
        let library = helper.library(dir)
        let service = NavigationService(library: library)
        let (feed, tap) = helper.makeFeed(41, scratch: scratch)
        let task = service.start(feed)
        let early = Roads.events(1...2)
        for event in early { tap.record(event) }
        #expect(await helper.waitUntil {
            let inUse = await service.roadsStatus().inUse, syncs = await service.librarySyncs
            return inUse && syncs >= 1
        })
        #expect(await service.roadsStatus().packNames == ["a.roadpack"])

        // Same grid, other content: the two combine.
        let second = try RoadPackFixture.write(try RoadPackFixture.data(osmTimestamp: 1_700_000_001), named: "b.roadpack",
                                               in: dir)
        await library.rescan()
        #expect(await helper.waitUntil { await service.roadsStatus().packNames.count == 2 })
        let status = await service.roadsStatus()
        #expect(status.packNames == ["a.roadpack", "b.roadpack"] && status.packHashPrefixes.count == 2)
        #expect(status.extendedAtSessionS != nil && status.activeAtSessionS != nil)
        #expect(RoadsDiagnosticsText.usage(status).hasPrefix("a.roadpack, b.roadpack from ")
                && RoadsDiagnosticsText.usage(status).contains(", extended at "))

        let late = Roads.events(2.5...6)
        for event in late { tap.record(event) }
        tap.finish()
        await task.value

        let (comparison, contents) = try await helper.comparison(feed: feed, events: early + late, packs: [first, second])
        #expect(contents.roads.count == 2)
        #expect(contents.roads.map { $0.roads.count } == [1, 2])
        #expect(contents.roads[0].afterInputs <= contents.roads[1].afterInputs)
        #expect(contents.roadsSelections.last { $0.outcome == .selected }?.trigger == .libraryChanged)
        #expect(comparison.exact, "\(comparison.report(tolerance: .default))")
        let finished = try #require(await service.finished.last)
        #expect(finished.roadPackNames == ["a.roadpack", "b.roadpack"] && finished.roadsExtendedAtS != nil)
    }

    @Test("A library change that adds nothing covering: one noNewPacks attempt, the run keeps its roads and the sidecar its single roads line")
    func changeWithNothingNew() async throws {
        let scratch = try ScratchStore()
        defer { scratch.remove() }
        let dir = try RoadPackFixture.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = try RoadPackFixture.write(try RoadPackFixture.data(), named: "a.roadpack", in: dir)
        let library = helper.library(dir)
        let service = NavigationService(library: library)
        let (feed, tap) = helper.makeFeed(42, scratch: scratch)
        let task = service.start(feed)
        let events = Roads.events(1...4)
        for event in Roads.events(1...2) { tap.record(event) }
        #expect(await helper.waitUntil {
            let inUse = await service.roadsStatus().inUse, syncs = await service.librarySyncs
            return inUse && syncs >= 1
        })
        let attempts = await service.selectionAttempts
        try RoadPackFixture.write(try RoadPackFixture.data(latShiftE7: 1_000_000), named: "far.roadpack", in: dir)
        await library.rescan()
        #expect(await helper.waitUntil { await service.selectionAttempts > attempts })
        #expect(await service.lastAttemptOutcome == .noNewPacks)
        #expect(await service.roadsStatus().packNames == ["a.roadpack"])
        for event in Roads.events(2.5...4) { tap.record(event) }
        tap.finish()
        await task.value
        let (comparison, contents) = try await helper.comparison(feed: feed, events: events, packs: [first])
        #expect(contents.roads.count == 1)
        #expect(comparison.exact, "\(comparison.report(tolerance: .default))")
    }

    @Test("Diagnostics: a pack pending removal that the running run has attached reads 'in use until restart'; one it has not, or after the run, the plain pending text")
    func inUseUntilRestart() {
        func pack(_ name: String) -> RoadPackLibrary.PackStatus {
            RoadPackLibrary.PackStatus(name: name, verified: false, refusal: RoadPackLibrary.removalPendingText, sizeBytes: 1,
                                       osmTimestamp: 0, hashPrefix: "00000000", cacheHit: false, verifySeconds: nil,
                                       packName: "x", pendingRemoval: true)
        }
        let status = RoadPackLibrary.Status(packs: [pack("a.roadpack"), pack("b.roadpack")])
        var roads = NavigationService.RoadsStatus(active: true, packNames: ["a.roadpack"])
        let marked = RoadsDiagnosticsModel.markInUse(status, roads: roads)
        #expect(marked.packs.map(\.inUseUntilRestart) == [true, false])
        #expect(RoadsDiagnosticsText.state(marked.packs[0]) == RoadsDiagnosticsText.inUseUntilRestart)
        #expect(RoadsDiagnosticsText.state(marked.packs[1]) == "Removal pending (after restart)")
        roads.active = false
        #expect(RoadsDiagnosticsModel.markInUse(status, roads: roads).packs.allSatisfy { !$0.inUseUntilRestart })
    }
}
