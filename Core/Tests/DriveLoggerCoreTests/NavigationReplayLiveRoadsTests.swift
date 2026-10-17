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

    @Test("As live with roads: LiveNavigationRun with a synchronous selector equals liveLines (the --write-sidecar loop) byte for byte, roadsSelection line included; without it (closure path) every other line is the same; the metrics replay attaches at the same input")
    func liveSelectionMatchesReplay() throws {
        let inputs = Attach.inputs()
        let (near, far) = try Self.packs()
        let given = ReplayRoadSet(try RoadNetwork(packs: [near, far]))

        // The app's loop with packs ready: a selector over the given packs.
        var run = LiveNavigationRun(sessionID: Attach.sessionID, config: Attach.config(), appBuild: "replay")
        // The replay's selector (canonical candidate order, named by content
        // hash): the order shows in the roadsSelection line's candidates.
        var selector = given.selector
        #expect(selector.candidates.map(\.name) == given.network.packs.map { NavigationSeed.hex($0.contentHash) })
        var lines = run.openingLines
        for input in inputs {
            run.ingest(input, selector: &selector) { lines.append($0) }
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
        // The closure path (no roadsSelection lines) gives every other line
        // byte for byte.
        var closureRun = LiveNavigationRun(sessionID: Attach.sessionID, config: Attach.config(), appBuild: "replay")
        var closureSelector = RoadPackSelector(candidates: selector.candidates)
        var closureLines = closureRun.openingLines
        for input in inputs {
            closureRun.ingest(input, selectRoads: { closureSelector.network(for: $0) }) { closureLines.append($0) }
        }
        let withoutSelection = replayed.filter { if case .roadsSelection = $0 { false } else { true } }
        #expect(withoutSelection.count == replayed.count - 1)
        #expect(try Attach.stripped(closureLines).map { try NavSidecar.encode($0, with: encoder) }
                == (try Attach.stripped(withoutSelection).map { try NavSidecar.encode($0, with: encoder) }))
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

    /// R32.4-1: the road scoring of withheld clean fixes reports the matched
    /// edge in the given set's numbering (the truth's), not the attached
    /// subset's. Given [near, far], the live rule attaches only near, so the
    /// engine numbers near as pack 0 while the given set may not.
    @Test("As live with roads and withheld clean fixes: each scored fix's matched edge is renumbered into the given set (near's pack by content hash), close to the fix, and judged right")
    func roadFixesRenumberedIntoGivenSet() throws {
        let inputs = Attach.inputs()
        let (near, far) = try Self.packs()
        let given = ReplayRoadSet(try RoadNetwork(packs: [near, far]))
        // Precondition: near is not pack 0 in the given set, so the attached
        // subset's numbering (near = 0) would name the far pack.
        let nearIndex = try #require(given.network.packs.firstIndex { $0.contentHash == near.contentHash })
        #expect(nearIndex != 0)

        var options = Self.options(given, attach: .live)
        options.gps = .maskAfter(seconds: 10)
        let result = NavigationReplay.run(logName: "live", inputs: inputs, options: options)
        let attached = try #require(result.attachedRoadSetHash)
        #expect(attached != given.roadSetHashHex)
        #expect(attached == (try RoadNetwork(packs: [near])).roadSetHashHex)

        let metrics = try #require(result.roadMetrics)
        // The clean fixes after 10 s (to 20 s) are withheld; each is scored
        // with the engine on the road (seed 33: nine, 11 s to 19 s).
        let scored = metrics.fixes
        #expect(scored.count == 9 && scored.allSatisfy { $0.matchedEdge != nil })
        for fix in scored {
            let matched = try #require(fix.matchedEdge)
            #expect(given.network.packs[matched.pack].contentHash == near.contentHash, "t \(fix.t) pack \(matched.pack)")
            #expect(fix.truthEdge == matched, "t \(fix.t) truth \(String(describing: fix.truthEdge)) matched \(matched)")
            let d = try #require(fix.matchedEdgeDistanceM)
            #expect(d < 10 && d < options.wrongRoadToleranceM, "t \(fix.t) distance \(d)")
            #expect(fix.verdict == .right, "t \(fix.t)")
        }
        // Verdicts: every scored fix right, none wrong or off. (The verdict
        // also accepts the same OSM way id, which the renumbering does not
        // change; the pack, truth-edge and distance checks above are the
        // ones that see the frame.)
        #expect(metrics.count(.right).fixes == scored.count && metrics.scored == scored.count)
        #expect(metrics.count(.wrong).fixes == 0 && metrics.count(.off).fixes == 0)
    }

    /// R32.1-2: an input the engine rejects as an implausible forward time
    /// jump still counts as given (`LiveNavigationRun.inputs` counts it), so
    /// the metrics replay attaches after the same number of inputs.
    @Test("A corrupt huge-t input before the attach counts as given: the metrics replay attaches where LiveNavigationRun does, as live and after k inputs")
    func rejectedTimeJumpCountsAsGiven() throws {
        let clean = Attach.inputs()
        let firstInit = try #require(clean.indices.first { k in
            var e = NavigationEngine(config: Attach.config())
            for input in clean[...k] { e.ingest(input) }
            return e.isInitialized
        })
        // The first motion row, re-stamped at 1e9 s and inserted right after
        // it: before the input that initialises the engine (and so before
        // the live attach). The very first input is always accepted, so the
        // corrupt one cannot come first.
        let j = try #require(clean.indices.first { if case .motion = clean[$0] { true } else { false } })
        #expect(j < firstInit, "first motion \(j), first initialisation \(firstInit)")
        guard case .motion(let sample, _) = clean[j] else { return }
        var inputs = clean
        inputs.insert(.motion(sample, at: MonotonicTimestamp(seconds: 1e9)), at: j + 1)
        var probe = NavigationEngine(config: Attach.config())
        for input in inputs[...j] { probe.ingest(input) }
        #expect(!probe.accepts(inputs[j + 1]))

        let (near, far) = try Self.packs()
        let given = ReplayRoadSet(try RoadNetwork(packs: [near, far]))

        /// The replay's track is the live run's estimates at each second.
        func expectTrack(_ result: ReplayResult, _ lines: [NavSidecar.Line], _ label: String) {
            let estimates = lines.compactMap { if case .estimate(let e) = $0 { e } else { nil } }
            let byT = Dictionary(uniqueKeysWithValues: estimates.map { ($0.t.seconds, $0) })
            var matched = 0
            for point in result.track {
                guard let e = byT[point.t] else { continue }
                matched += 1
                #expect(point.latitude == e.latitude && point.longitude == e.longitude, "\(label) t \(point.t)")
            }
            #expect(matched > 50, "\(label)")
        }

        // As live: the app's loop with a synchronous selector over the packs.
        var run = LiveNavigationRun(sessionID: Attach.sessionID, config: Attach.config(), appBuild: "replay")
        var selector = given.selector
        var lines: [NavSidecar.Line] = []
        for input in inputs {
            run.ingest(input, selectRoads: { selector.network(for: $0) }) { lines.append($0) }
        }
        let roads = try #require(run.roads)
        #expect(roads.afterInputs == firstInit + 2)
        #expect(run.engine.counters.inputsRejectedTimeJump == 1)
        let live = NavigationReplay.run(logName: "live", inputs: inputs, options: Self.options(given, attach: .live))
        #expect(live.counters.inputsRejectedTimeJump == 1)
        #expect(live.roadsAttachedAfterInputs == roads.afterInputs)
        #expect(live.counters == run.engine.counters)
        expectTrack(live, lines, "live")

        // After k inputs, k past the rejected one: the replay attaches at k,
        // and runs as a LiveNavigationRun attached at k. k = inputs.count:
        // after the last input.
        let set = ReplayRoadSet(try RoadNetwork(packs: [near]))
        for k in [j + 2, firstInit + 1, 2_500, 2_501, 2_502, inputs.count] {
            let app = Attach.live(inputs, network: set.network, attachAfter: k)
            #expect(app.run.roads?.afterInputs == k, "k \(k)")
            let result = NavigationReplay.run(logName: "live", inputs: inputs, options: Self.options(set, attach: .afterInputs(k)))
            #expect(result.roadsAttachedAfterInputs == k, "k \(k)")
            #expect(result.counters == app.run.engine.counters, "k \(k)")
            expectTrack(result, app.lines, "k \(k)")
        }
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
        #expect(NavigationConfig.roadOnlyKeys.count == 21 && NavigationConfig.roadOnlyKeys.allSatisfy { $0.hasPrefix("road") })
    }

    /// R32.4-6: a config hash that differs while no key differs (nothing
    /// to name: the JSON is the replay's, or could not be parsed) is still
    /// blamed, as "(none parsed)".
    @Test("R32.4-6: the config hash differs but no key differs: blamed as '(none parsed)', named as a cause")
    func configHashDiffersNoKeysParsed() throws {
        let inputs = Attach.inputs()
        let config = Attach.config()
        let replay = NavigationReplay.liveLines(inputs: inputs, sessionID: Attach.sessionID, config: config)
        var sidecar = try NavSidecar.read(NavigationLiveTests.encoded(replay))
        #expect(sidecar.header.configHash == config.hashHex)
        sidecar.header.configHash = String(repeating: "0", count: config.hashHex.count)

        let c = SidecarComparison(sidecar: sidecar, replay: replay, replayConfig: config)
        #expect(c.configHashMismatch && c.configDifferences.isEmpty && c.inertConfigDifferences.isEmpty)
        #expect(c.configBlamed, "a hash mismatch with no key parsed is blamed")
        #expect(!c.seedMismatch && c.exact)
        let report = c.report(tolerance: .default)
        #expect(report.contains("Warning       config hash differs from the sidecar's; keys: (none parsed)\n"))
        #expect(!report.contains("road-only keys") && !report.contains("Note          config hash"))

        // Not exact: the config is the only cause named.
        var short = sidecar
        short.estimates.remove(at: short.estimates.count / 2)
        let d = SidecarComparison(sidecar: short, replay: replay, replayConfig: config)
        #expect(d.configBlamed && !d.exact && d.sidecarOnly == 0 && d.replayOnly == 1)
        #expect(d.report(tolerance: .default).contains("; explained by a different seed or config\n"))
    }
}
