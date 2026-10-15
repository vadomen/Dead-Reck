import Foundation
import Testing

@testable import DriveLoggerCore
@testable import RoadPackBuild

/// N3.3 item 4: `replay_nav --as-live --roads`, `--write-sidecar` with
/// roads, `--compare` against a sidecar's roads line, and N3-CMPHASH (road
/// keys inert without roads). Synthetic drive and packs near (0, 0) only.
@Suite("Replay as live with roads, and compare (N3.3)")
struct NavigationReplayLiveRoadsTests {
    typealias Attach = NavigationRoadAttachTests
    typealias N = RoadFixture.Node

    /// The drive's road (x = 0) and a far road (8 km east), as two packs
    /// on one grid, no COVR: each covers its bounding box.
    static func packs() throws -> (near: RoadPack, far: RoadPack) {
        let near = try RoadFixture.build([RoadFixture.way(1, ["highway": "residential"],
                                                           [N(id: 10, east: 0, north: -3000), N(id: 11, east: 0, north: 3000)])])
        let far = try RoadFixture.build([RoadFixture.way(2, ["highway": "residential"],
                                                          [N(id: 20, east: 8000, north: -1000), N(id: 21, east: 8000, north: 1000)])])
        return (near, far)
    }

    static func options(_ roads: ReplayRoadSet, attach: ReplayRoadAttach) -> ReplayOptions {
        var options = ReplayOptions(gps: .use, config: Attach.config())
        options.asLive = true
        options.fileOrder = true
        options.roads = roads
        options.roadAttach = attach
        return options
    }

    @Test("As live with roads: LiveNavigationRun with a synchronous selector equals liveLines (the --write-sidecar loop) byte for byte; the metrics replay attaches at the same input")
    func liveSelectionMatchesReplay() throws {
        let inputs = Attach.inputs()
        let (near, far) = try Self.packs()
        let given = ReplayRoadSet(try RoadNetwork(packs: [near, far]))

        // The app's loop with packs ready: a selector over the given packs.
        var run = LiveNavigationRun(sessionID: Attach.sessionID, config: Attach.config(), appBuild: "replay")
        var selector = RoadPackSelector(candidates: try [near, far].map {
            try RoadPackSelection.Candidate(name: NavigationSeed.hex($0.contentHash), pack: $0)
        })
        var lines = run.openingLines
        for input in inputs {
            run.ingest(input, selectRoads: { selector.network(for: $0) }) { lines.append($0) }
        }
        let roads = try #require(run.roads)
        // Only the pack under the car is selected, at the first request.
        #expect(roads.network.packs.map(\.contentHash) == [near.contentHash])
        #expect(selector.requests == 1)

        let replayed = NavigationReplay.liveLines(inputs: inputs, sessionID: Attach.sessionID, config: Attach.config(),
                                                  roads: given, attach: .live)
        #expect(try Attach.digest(replayed) == (try Attach.digest(lines)))
        let encoder = NavSidecar.makeEncoder()
        let a = try Attach.stripped(lines).map { try NavSidecar.encode($0, with: encoder) }
        let b = try Attach.stripped(replayed).map { try NavSidecar.encode($0, with: encoder) }
        #expect(a == b)
        #expect(replayed.contains { if case .roads(let r) = $0 { r.afterInputs == roads.afterInputs } else { false } })

        // The metrics replay attaches the same set after the same input.
        let result = NavigationReplay.run(logName: "live", inputs: inputs, options: Self.options(given, attach: .live))
        #expect(result.roadsAttachedAfterInputs == roads.afterInputs)
        #expect(result.attachedRoadSetHash == roads.network.roadSetHashHex)
        #expect(result.roadSetHash == given.roadSetHashHex && result.mode == "use-as-live-" + given.labelSuffix)
        #expect(result.counters.roadUpdates == run.engine.counters.roadUpdates && result.counters.roadUpdates > 0)
        // Matched edges are renumbered into the given set (the truth's).
        #expect(!result.matchedEdges.isEmpty)
        #expect(result.matchedEdges.allSatisfy { given.network.packs[$0.edge.pack].contentHash == near.contentHash })
        // The replay's track is the live run's estimates at each second.
        let estimates = replayed.compactMap { if case .estimate(let e) = $0 { e } else { nil } }
        let byT = Dictionary(uniqueKeysWithValues: estimates.map { ($0.t.seconds, $0) })
        var matched = 0
        for point in result.track {
            guard let e = byT[point.t] else { continue }
            matched += 1
            #expect(point.latitude == e.latitude && point.longitude == e.longitude, "t \(point.t)")
        }
        #expect(matched > 50)
        let metrics = ReplayMetrics(result)
        #expect(metrics.roadsAttachedAfterInputs == roads.afterInputs)
        let decoded = try JSONDecoder().decode(ReplayMetrics.self, from: JSONEncoder().encode(metrics))
        #expect(decoded.attachedRoadSetHash == roads.network.roadSetHashHex)

        // From the start (N3.2 replays): no attach recorded, rows unchanged.
        let fromStart = NavigationReplay.run(logName: "live", inputs: inputs, options: Self.options(given, attach: .fromStart))
        #expect(fromStart.roadsAttachedAfterInputs == nil && fromStart.attachedRoadSetHash == nil)
    }

    @Test("Compare with a v2 sidecar's roads line: the same packs at its afterInputs give PASS (exact); the metrics replay attaches there too")
    func compareAtAfterInputs() throws {
        let inputs = Attach.inputs()
        let (near, _) = try Self.packs()
        let set = ReplayRoadSet(try RoadNetwork(packs: [near]))
        // The app attached late (its packs were not ready at the request).
        let k = 2_500
        let app = Attach.live(inputs, network: set.network, attachAfter: k)
        let header = LiveNavigationRun(sessionID: Attach.sessionID, config: Attach.config(), appBuild: "app").header
        let sidecar = try NavSidecar.read(NavigationLiveTests.encoded([.header(header)] + app.lines))
        #expect(sidecar.roads?.afterInputs == k)

        let afterK = ReplayRoadAttach.afterInputs(k)
        let replay = NavigationReplay.liveLines(inputs: inputs, sessionID: Attach.sessionID, config: Attach.config(),
                                                roads: set, attach: afterK)
        let same = SidecarComparison(sidecar: sidecar, replay: replay, replayConfig: Attach.config(),
                                     givenRoadSetHash: set.roadSetHashHex)
        #expect(same.exact && same.roadsMismatch == nil, "\(same.report(tolerance: .default))")
        #expect(same.report(tolerance: .default).contains("PASS (exact"))
        let result = NavigationReplay.run(logName: "live", inputs: inputs, options: Self.options(set, attach: afterK))
        #expect(result.roadsAttachedAfterInputs == k)

        // The live rule instead of the sidecar's attach point: not the app's run.
        let live = NavigationReplay.liveLines(inputs: inputs, sessionID: Attach.sessionID, config: Attach.config(),
                                              roads: set, attach: .live)
        let early = SidecarComparison(sidecar: sidecar, replay: live, replayConfig: Attach.config(),
                                      givenRoadSetHash: set.roadSetHashHex)
        #expect(!early.exact && early.roadsMismatch?.contains("the roads line differs") == true)
    }

    @Test("Compare refuses an exact verdict without the same packs: no packs given, another road set, packs given for a no-roads sidecar")
    func compareRoadsMismatch() throws {
        let inputs = Attach.inputs()
        let (near, far) = try Self.packs()
        let set = ReplayRoadSet(try RoadNetwork(packs: [near]))
        let other = ReplayRoadSet(try RoadNetwork(packs: [near, far]))
        let config = Attach.config()
        let withRoads = NavigationReplay.liveLines(inputs: inputs, sessionID: Attach.sessionID, config: config,
                                                   roads: set, attach: .live)
        let sidecar = try NavSidecar.read(NavigationLiveTests.encoded(withRoads))
        let k = try #require(sidecar.roads?.afterInputs)

        // Sidecar with roads, replay without packs.
        let bare = NavigationReplay.liveLines(inputs: inputs, sessionID: Attach.sessionID, config: config)
        let none = SidecarComparison(sidecar: sidecar, replay: bare, replayConfig: config)
        #expect(!none.exact && none.roadsMismatch?.contains("no packs were given") == true)
        #expect(!none.report(tolerance: .default).contains("PASS (exact"))

        // Another road set at the sidecar's afterInputs: same lines here (the
        // far pack is never near), still no exact verdict, hashes named.
        let otherLines = NavigationReplay.liveLines(inputs: inputs, sessionID: Attach.sessionID, config: config,
                                                    roads: other, attach: .afterInputs(k))
        let mismatch = SidecarComparison(sidecar: sidecar, replay: otherLines, replayConfig: config,
                                         givenRoadSetHash: other.roadSetHashHex)
        #expect(!mismatch.exact && mismatch.passes(.default))
        let report = mismatch.report(tolerance: .default)
        #expect(report.contains(set.roadSetHashHex) && report.contains(other.roadSetHashHex))
        #expect(report.contains("PASS within tolerance") && !report.contains("PASS (exact"))
        #expect(report.contains("a different road set"))

        // A sidecar without roads (v1 or v2), packs given: one side only.
        let plainLines = NavigationReplay.liveLines(inputs: inputs, sessionID: Attach.sessionID, config: config)
        let plain = try NavSidecar.read(NavigationLiveTests.encoded(plainLines))
        let given = SidecarComparison(sidecar: plain, replay: withRoads, replayConfig: config,
                                      givenRoadSetHash: set.roadSetHashHex)
        #expect(!given.exact && given.roadsMismatch?.contains("the sidecar used no roads") == true)
        #expect(!given.report(tolerance: .default).contains("PASS (exact"))
        // ...even when the given packs were never attached (identical lines).
        let unused = SidecarComparison(sidecar: plain, replay: plainLines, replayConfig: config,
                                       givenRoadSetHash: set.roadSetHashHex)
        #expect(unused.linesIdentical && !unused.exact && unused.passes(.default))
    }

    @Test("N3-CMPHASH: without roads on either side a road-only config difference is named inert, not blamed; with roads it is blamed")
    func roadKeysInertWithoutRoads() throws {
        let inputs = Attach.inputs()
        var old = Attach.config()
        old.roadCorrelationM = 30
        let sidecarLines = NavigationReplay.liveLines(inputs: inputs, sessionID: Attach.sessionID, config: old)
        let sidecar = try NavSidecar.read(NavigationLiveTests.encoded(sidecarLines))
        let config = Attach.config()
        let replay = NavigationReplay.liveLines(inputs: inputs, sessionID: Attach.sessionID, config: config)
        let c = SidecarComparison(sidecar: sidecar, replay: replay, replayConfig: config)
        #expect(c.configHashMismatch && c.configDifferences == ["roadCorrelationM"])
        #expect(c.inertConfigDifferences == ["roadCorrelationM"] && !c.configBlamed)
        #expect(c.exact)
        let report = c.report(tolerance: .default)
        #expect(report.contains("inert") && !report.contains("Warning       config hash"))
        #expect(report.contains("PASS (exact"))

        // A non-road key is still blamed, the road key named inert beside it.
        var other = old
        other.headingNoiseDegPerSqrtS += 0.01
        let otherSidecar = try NavSidecar.read(NavigationLiveTests.encoded(
            NavigationReplay.liveLines(inputs: inputs, sessionID: Attach.sessionID, config: other)))
        let d = SidecarComparison(sidecar: otherSidecar, replay: replay, replayConfig: config)
        #expect(d.configBlamed && d.blamedConfigDifferences == ["headingNoiseDegPerSqrtS"])
        #expect(d.report(tolerance: .default).contains("a different seed or config"))

        // With roads in use the road key is a cause.
        let (near, _) = try Self.packs()
        let set = ReplayRoadSet(try RoadNetwork(packs: [near]))
        let roadSidecar = try NavSidecar.read(NavigationLiveTests.encoded(
            NavigationReplay.liveLines(inputs: inputs, sessionID: Attach.sessionID, config: old, roads: set, attach: .live)))
        let roadReplay = NavigationReplay.liveLines(inputs: inputs, sessionID: Attach.sessionID, config: config,
                                                    roads: set, attach: .afterInputs(try #require(roadSidecar.roads?.afterInputs)))
        let e = SidecarComparison(sidecar: roadSidecar, replay: roadReplay, replayConfig: config,
                                  givenRoadSetHash: set.roadSetHashHex)
        #expect(e.inertConfigDifferences.isEmpty && e.configBlamed && !e.exact)
        #expect(NavigationConfig.roadOnlyKeys.count == 18 && NavigationConfig.roadOnlyKeys.allSatisfy { $0.hasPrefix("road") })
    }
}
