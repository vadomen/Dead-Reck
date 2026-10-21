import Foundation
import Testing

@testable import DriveLoggerCore
@testable import RoadPackBuild

/// Prompt 38 item A: roads in a running session. `NavigationEngine.extendRoads`
/// (a larger covering set mid-run), the superset rule of the selection, the
/// coverage trigger (`RoadCoverageWatch`), the library-change request,
/// sidecar v3 (several `roads` lines, `trigger`) and the replay schedule and
/// injection. Synthetic drive and packs near (0, 0) only.
@Suite("Navigation roads extended mid-run (prompt 38)")
struct NavigationRoadExtendTests {
    typealias Attach = NavigationRoadAttachTests
    typealias Live = NavigationLiveTests
    typealias N = RoadFixture.Node

    // MARK: Fixtures

    /// The drive's road, x = 0 from −3000 to 3000 m (covers its bounding box).
    static func near() throws -> RoadPack {
        try RoadFixture.build([RoadFixture.way(1, ["highway": "residential"],
                                               [N(id: 10, east: 0, north: -3000), N(id: 11, east: 0, north: 3000)])])
    }

    /// A road 300 m east of the drive, with a COVR square x −1000…1000,
    /// y −200…3000: the drive (60 s north from y = −500) enters it at about
    /// 25 s and stays inside. `grid`/`radiusM` let a test make it unusable.
    static func ahead(grid: RoadGrid = RoadFixture.grid(), id: Int64 = 3) throws -> RoadPack {
        let ring = [RoadFixture.point(-1000, -200), RoadFixture.point(1000, -200),
                    RoadFixture.point(1000, 3000), RoadFixture.point(-1000, 3000)]
        return try RoadFixture.build([RoadFixture.way(id, ["highway": "residential"],
                                                      [N(id: id * 10, east: 300, north: -200),
                                                       N(id: id * 10 + 1, east: 300, north: 3000)])],
                                     grid: grid, coverage: [ring])
    }

    /// A road far from the drive (8 km east, or west with `west`).
    static func far(west: Bool = false) throws -> RoadPack {
        let x: Double = west ? -8000 : 8000
        return try RoadFixture.build([RoadFixture.way(west ? 5 : 2, ["highway": "residential"],
                                                      [N(id: west ? 50 : 20, east: x, north: -1000),
                                                       N(id: west ? 51 : 21, east: x, north: 1000)])])
    }

    static func candidate(_ name: String, _ pack: RoadPack) throws -> RoadPackSelection.Candidate {
        try RoadPackSelection.Candidate(name: name, pack: pack)
    }

    static func request(east: Double, north: Double, radiusM: Double, afterInputs: Int = 1,
                        trigger: RoadSelectionTrigger? = nil) -> RoadSelectionRequest {
        let p = SyntheticDrive.plane.geodetic(east: east, north: north)
        return RoadSelectionRequest(latitude: p.latitude, longitude: p.longitude, radiusM: radiusM,
                                    afterInputs: afterInputs, t: SyntheticDrive.ms(Double(afterInputs)), trigger: trigger)
    }

    static func roadsLines(_ lines: [NavSidecar.Line]) -> [NavSidecar.Roads] {
        lines.compactMap { if case .roads(let r) = $0 { r } else { nil } }
    }

    static func selections(_ lines: [NavSidecar.Line]) -> [NavSidecar.RoadsSelection] {
        lines.compactMap { if case .roadsSelection(let r) = $0 { r } else { nil } }
    }

    /// The live loop with a synchronous selector over `candidates`.
    static func liveWithSelector(_ candidates: [RoadPackSelection.Candidate], inputs: [NavigationInput])
        -> (run: LiveNavigationRun, lines: [NavSidecar.Line], selector: RoadPackSelector) {
        var run = LiveNavigationRun(sessionID: Attach.sessionID, config: Attach.config(), appBuild: "test")
        var selector = RoadPackSelector(candidates: candidates)
        var lines = run.openingLines
        for input in inputs { run.ingest(input, selector: &selector) { lines.append($0) } }
        lines += run.closingLines(inFlight: nil)
        return (run, lines, selector)
    }

    // MARK: Engine: extendRoads

    @Test("extendRoads preconditions: no network (notAttached), the same set or a set missing an attached pack (notSuperset); each leaves the engine unchanged")
    func extendPreconditions() throws {
        let (near, far) = (try Self.near(), try Self.far())
        let inputs = Attach.inputs()
        var engine = NavigationEngine(config: Attach.config())
        for input in inputs.prefix(400) { engine.ingest(input) }
        #expect(throws: RoadAttachRefusal.notAttached) { try engine.extendRoads(try RoadNetwork(packs: [near, far])) }
        #expect(engine.roadNetwork == nil)

        let attached = try RoadNetwork(packs: [near])
        try engine.attachRoads(attached)
        let before = Attach.state(engine)
        #expect(throws: RoadAttachRefusal.notSuperset(missing: [])) { try engine.extendRoads(try RoadNetwork(packs: [near])) }
        #expect(throws: RoadAttachRefusal.notSuperset(missing: [NavigationSeed.hex(near.contentHash)])) {
            try engine.extendRoads(try RoadNetwork(packs: [far]))
        }
        // A pack whose guaranteed radius would change the config is on
        // another grid, so it cannot join the attached network at all.
        let narrow = try Self.ahead(grid: RoadFixture.grid(radiusM: 20))
        #expect(throws: (any Error).self) { _ = try RoadNetwork(packs: [near, narrow]) }
        #expect(engine.roadNetwork === attached && Attach.state(engine) == before)
        #expect(engine.roadNetwork?.packs.count == 1)
    }

    @Test("extendRoads with a strict superset of the same open packs: the network is replaced, road state cleared as attachRoads clears it, particles, weights and headings untouched, and the run is deterministic")
    func extendClearsRoadStateOnly() throws {
        let (near, ahead) = (try Self.near(), try Self.ahead())
        let inputs = Attach.inputs()
        var engine = NavigationEngine(config: Attach.config(), roads: try RoadNetwork(packs: [near]))
        for input in inputs.prefix(1_500) { engine.ingest(input) }
        #expect(engine.roadEdge.contains { $0 != RoadMatcher.noEdge }, "on the road before the extension")
        let before = Attach.state(engine)
        let larger = try RoadNetwork(packs: [near, ahead])
        try engine.extendRoads(larger)
        #expect(engine.roadNetwork === larger)
        #expect(Attach.state(engine) == before, "particles, covariances, headings, weights untouched")
        #expect(engine.roadEdge.allSatisfy { $0 == RoadMatcher.noEdge })
        #expect(engine.roadLevel.allSatisfy { $0 == RoadGeometry.unknownLevel })
        #expect(engine.offRoadM.allSatisfy { $0 == 0 } && engine.roadDistanceM == 0)
        let t = try #require(engine.latestArrival)
        #expect(engine.estimate(at: t)?.onRoadShare == nil && engine.estimate(at: t)?.matchedEdge == nil)

        // Determinism: the same extension at the same input, bit for bit.
        func run() throws -> String {
            var live = LiveNavigationRun(sessionID: Attach.sessionID, config: Attach.config(), appBuild: "t",
                                         roads: try RoadNetwork(packs: [near]))
            var lines = live.openingLines
            for (i, input) in inputs.enumerated() {
                if i == 1_500 { try live.extendRoads(try RoadNetwork(packs: [near, ahead])) { lines.append($0) } }
                live.ingest(input) { lines.append($0) }
            }
            #expect(Self.roadsLines(lines).map(\.afterInputs) == [0, 1_500])
            return try Attach.digest(lines)
        }
        #expect(try run() == (try run()))
    }

    @Test("extendRoads with roadFixPinCheck on: every ring fix's coverage and road distances and every source's road shift are cleared, so the next road check queries the larger network afresh (R75.1-1)")
    func extendClearsFixPinRoadCache() throws {
        typealias P = NavigationFixPinTests
        let drive = P.lDrive(eastS: 60)
        let net = try P.roads(drive)
        let inputs = P.inputs(drive, pins: [(30.03, 0, 0)])
        var engine = P.run(inputs, config: P.config(roads: 1), roads: net).engine
        let ring = engine.fixPin[0].ring
        #expect(engine.counters.fixPinRoadRechecks >= 5, "the road check ran while down-weighted")
        #expect(ring.filter { $0.covered != nil }.count >= 10, "coverage cached (fixes since the last check not yet)")
        #expect(ring.contains { $0.roadA != nil && $0.roadB != nil }, "road distances cached")
        let shift = try #require(engine.fixPin[0].offset)
        #expect(engine.fixPin[0].roadShift.map { !$0.east.isNaN && !$0.north.isNaN } == true)

        try engine.extendRoads(try RoadNetwork(packs: net.packs + [try Self.far()]))
        #expect(engine.fixPin.count == FixPinSource.Kind.allCases.count)
        for source in engine.fixPin {
            #expect(source.ring.allSatisfy { $0.covered == nil && $0.roadA == nil && $0.roadB == nil })
            #expect(source.roadShift.map { $0.east.isNaN && $0.north.isNaN } == true)
        }
        #expect(engine.fixPin[0].ring.count == ring.count, "the fixes themselves stay")

        // The next check queries every covered fix again (A and B), and
        // gives what a cleared cache gives.
        let plane = try #require(engine.tangentPlane)
        let queries = engine.counters.fixPinRoadDistanceQueries
        let next = engine.roadFixPinComparison(.accessory, shiftEast: shift.east, shiftNorth: shift.north, plane: plane)
        #expect(next.fixes >= 10)
        #expect(engine.counters.fixPinRoadDistanceQueries - queries == 2 * next.fixes)
    }

    @Test("extendRoads draws no random number: with only far packs (no road near any particle) the run extended mid-way gives the no-roads run's positions, headings and ellipses bit for bit")
    func extendDrawsNothing() throws {
        let inputs = Attach.inputs()
        let plain = Attach.live(inputs).lines
        var run = LiveNavigationRun(sessionID: Attach.sessionID, config: Attach.config(), appBuild: "t",
                                    roads: try RoadNetwork(packs: [try Self.far()]))
        var lines: [NavSidecar.Line] = []
        for (i, input) in inputs.enumerated() {
            if i == 1_200 { try run.extendRoads(try RoadNetwork(packs: [try Self.far(), try Self.far(west: true)])) { _ in } }
            run.ingest(input) { lines.append($0) }
        }
        #expect(run.engine.counters.roadUpdates == 0 && run.engine.counters.roadUpdatesNoRoad > 0)
        func positions(_ lines: [NavSidecar.Line]) -> [NavSidecar.Estimate] {
            lines.compactMap {
                guard case .estimate(var e) = $0 else { return nil }
                e.msPerStep = nil
                e.maxStepMs = nil
                e.onRoadShare = nil
                return e
            }
        }
        let a = positions(plain), b = positions(lines)
        #expect(a.count == 60 && a.count == b.count)
        #expect(zip(a, b).allSatisfy { x, y in
            x.latitude.bitPattern == y.latitude.bitPattern && x.longitude.bitPattern == y.longitude.bitPattern
                && x.headingDeg.bitPattern == y.headingDeg.bitPattern && x.semiMajorM.bitPattern == y.semiMajorM.bitPattern
        })
    }

    // MARK: Selection: the superset rule

    @Test("Selection with roads attached: every covering pack attached → noNewPacks; a new covering pack → selected, the attached open instances kept plus it; a newer version of an attached pack only → notSuperset (waits for the next start); an attached pack no longer covering stays")
    func supersetRule() throws {
        let (near, ahead, far) = (try Self.near(), try Self.ahead(), try Self.far())
        let attached = try RoadNetwork(packs: [near])
        let names = ["near-" + NavigationSeed.hex(near.contentHash) + ".roadpack"]
        let aheadName = "ahead-" + NavigationSeed.hex(ahead.contentHash) + ".roadpack"
        let candidates = [try Self.candidate(names[0], near), try Self.candidate(aheadName, ahead),
                          try Self.candidate("far.roadpack", far)]

        // At the start (y = −500, 50 m): only near covers.
        let start = Self.request(east: 0, north: -500, radiusM: 50)
        let none = RoadPackSelection.attempt(candidates, request: start, attached: attached, attachedNames: names)
        #expect(none.outcome == .noNewPacks && none.network == nil && none.packs == names)

        // Inside ahead's coverage: extended to near + ahead, near's instance kept.
        let inside = Self.request(east: 0, north: 100, radiusM: 50)
        let grown = RoadPackSelection.attempt(candidates, request: inside, attached: attached, attachedNames: names)
        #expect(grown.outcome == .selected && grown.packs == names + [aheadName])
        let network = try #require(grown.network)
        #expect(Set(network.packs.map(\.contentHash)) == [near.contentHash, ahead.contentHash])
        #expect(network.packs.contains { $0 === near }, "the attached open pack, not a second mapping")
        #expect(!network.packs.contains { $0 === candidates[0].pack } || candidates[0].pack === near)

        // A newer version of the attached pack (same pack name, another hash)
        // covering, nothing else new: notSuperset, nothing built.
        let newer = try RoadFixture.build([RoadFixture.way(1, ["highway": "residential"],
                                                           [N(id: 10, east: 0, north: -3000), N(id: 11, east: 1, north: 3000)])])
        #expect(newer.contentHash != near.contentHash)
        let newerName = "near-" + NavigationSeed.hex(newer.contentHash) + ".roadpack"
        let update = RoadPackSelection.attempt([try Self.candidate(newerName, newer), candidates[2]], request: start,
                                               attached: attached, attachedNames: names)
        #expect(update.outcome == .notSuperset && update.network == nil && update.packs == [newerName])
        // ... and with a new pack beside it, the new pack extends the set,
        // the newer version still waits.
        let both = RoadPackSelection.attempt([try Self.candidate(newerName, newer), candidates[1]], request: inside,
                                             attached: attached, attachedNames: names)
        #expect(both.outcome == .selected && both.packs == names + [aheadName])

        // The attached pack gone from the candidates (removed during the run):
        // a new covering pack still extends the attached set, never replaces it.
        let removed = RoadPackSelection.attempt([candidates[1]], request: inside, attached: attached, attachedNames: names)
        #expect(removed.outcome == .selected)
        #expect(Set(try #require(removed.network).packs.map(\.contentHash)) == [near.contentHash, ahead.contentHash])

        // Without names (a network given at init): the hex hashes stand in.
        let unnamed = RoadPackSelection.attempt(candidates, request: start, attached: attached)
        #expect(unnamed.outcome == .noNewPacks && unnamed.packs == [NavigationSeed.hex(near.contentHash)])
    }

    @Test("finishSelection with roads attached: an attempt whose network is not a strict superset is recorded as notSuperset with the refusal's reason, and the run keeps its roads (no roads line)")
    func finishNotSuperset() throws {
        let (near, far) = (try Self.near(), try Self.far())
        var run = LiveNavigationRun(sessionID: Attach.sessionID, config: Attach.config(), appBuild: "t",
                                    roads: try RoadNetwork(packs: [near]))
        for input in Attach.inputs().prefix(300) { run.ingest(input) { _ in } }
        let other = try RoadNetwork(packs: [far])
        let attempt = RoadSelectionAttempt(request: Self.request(east: 0, north: 0, radiusM: 50, afterInputs: 300),
                                           candidates: [], outcome: .selected, network: other, packs: ["far"], reason: nil)
        var lines: [NavSidecar.Line] = []
        let record = run.finishSelection(attempt) { lines.append($0) }
        #expect(record.outcome == .notSuperset && record.refusal == nil)
        #expect(record.reason == RoadAttachRefusal.notSuperset(missing: [NavigationSeed.hex(near.contentHash)]).description)
        #expect(Self.roadsLines(lines).isEmpty && run.attachments.count == 1)
        #expect(run.roads?.network.packs.map(\.contentHash) == [near.contentHash])
        #expect(run.roadsRefusal == .notSuperset(missing: [NavigationSeed.hex(near.contentHash)]))
    }

    // MARK: The coverage trigger

    @Test("Coverage entered: the drive starts on near only; when the estimate's circle enters ahead's coverage one coverageEntered request extends the set (two roads lines, increasing afterInputs, superset); checks stop once every watched pack is attached")
    func coverageEnteredExtends() throws {
        let (near, ahead, far) = (try Self.near(), try Self.ahead(), try Self.far())
        let candidates = [try Self.candidate("ahead.roadpack", ahead), try Self.candidate("far.roadpack", far),
                          try Self.candidate("near.roadpack", near)]
        let inputs = Attach.inputs()
        let (run, lines, selector) = Self.liveWithSelector(candidates, inputs: inputs)
        let roads = Self.roadsLines(lines)
        #expect(roads.count == 2, "\(Self.selections(lines).map(\.summary))")
        #expect(roads.map { $0.roads.count } == [1, 2])
        #expect(roads[0].afterInputs < roads[1].afterInputs)
        #expect(Set(roads[0].roads.map(\.contentHash)).isStrictSubset(of: Set(roads[1].roads.map(\.contentHash))))
        let selections = Self.selections(lines)
        #expect(selections.map(\.trigger) == [nil, .coverageEntered])
        #expect(selections.map(\.outcome) == [.selected, .selected])
        #expect(selections[1].packs == ["near.roadpack", "ahead.roadpack"])
        #expect(run.roadPackNames == ["near.roadpack", "ahead.roadpack"])
        #expect(selector.requests == 2)
        // The far pack stays watched (never attached): checks go on at most
        // once per second; without it they would stop at the extension.
        let seconds = Int(inputs.last!.arrival.seconds.rounded(.up)) + 1
        #expect(run.selectionRule.watch.checks > 0 && run.selectionRule.watch.checks <= seconds)

        // Watching only packs that end up attached: no check after the last attach.
        let (twoRun, twoLines, _) = Self.liveWithSelector(Array(candidates[0...0]) + [candidates[2]], inputs: inputs)
        #expect(Self.roadsLines(twoLines).count == 2)
        let checksAtEnd = twoRun.selectionRule.watch.checks
        let extendedAt = Self.roadsLines(twoLines)[1].t!.seconds
        #expect(checksAtEnd <= Int(extendedAt.rounded(.up)) + 1, "no check after every watched pack is attached")

        // The same lines bit for bit in the --write-sidecar loop.
        let given = ReplayRoadSet(try RoadNetwork(packs: [near, ahead, far]),
                                  names: [near.contentHash: "near.roadpack", ahead.contentHash: "ahead.roadpack",
                                          far.contentHash: "far.roadpack"])
        let replayed = NavigationReplay.liveLines(inputs: inputs, sessionID: Attach.sessionID, config: Attach.config(),
                                                  roads: given, attach: .live)
        let encoder = NavSidecar.makeEncoder()
        func body(_ lines: [NavSidecar.Line]) throws -> [Data] {
            try Attach.stripped(lines).dropFirst().map { try NavSidecar.encode($0, with: encoder) }  // header: appBuild differs
        }
        #expect(try body(replayed) == (try body(lines)))
        // ... and the metrics replay extends after the same input.
        var options = ReplayOptions(gps: .use, config: Attach.config())
        options.asLive = true
        options.fileOrder = true
        options.roads = given
        options.roadAttach = .live
        let result = NavigationReplay.run(logName: "x", inputs: inputs, options: options)
        #expect(result.roadsAttachedAfterInputs == roads[0].afterInputs)
        #expect(result.roadsExtendedAfterInputs == [roads[1].afterInputs])
        #expect(result.attachedRoadSetHash == roads[1].roadSetHash)
        #expect(ReplayMetrics(result).roadsExtendedAfterInputs == [roads[1].afterInputs])
    }

    @Test("Coverage entered is edge-triggered: a covering pack whose set is refused (another grid) raises one coverageEntered attempt while the circle stays inside, not one per second")
    func coverageEnteredOnce() throws {
        let near = try Self.near()
        let otherGrid = try Self.ahead(grid: RoadFixture.grid(cellSizeM: 128))
        let candidates = [try Self.candidate("ahead.roadpack", otherGrid), try Self.candidate("near.roadpack", near)]
        let (run, lines, _) = Self.liveWithSelector(candidates, inputs: Attach.inputs())
        #expect(Self.roadsLines(lines).count == 1)
        let entered = Self.selections(lines).filter { $0.trigger == .coverageEntered }
        #expect(entered.reduce(0) { $0 + $1.attempts } == 1)
        #expect(entered.first?.outcome == .refused)
        #expect(run.selectionLog.attempts == 2)
        #expect(run.selectionRule.watch.checks > 10, "checked every second while inside")
    }

    @Test("RoadCoverageWatch.check: entering raises, staying does not, leaving does not, entering again raises; the bounding-box precheck never skips a circle the exact test accepts")
    func watchEdges() throws {
        let ahead = try Self.ahead()
        var watch = RoadCoverageWatch()
        let pack = RoadCoverageWatch.Pack(try Self.candidate("ahead", ahead))
        watch.setPacks([pack])
        let path: [(north: Double, entered: Bool)] = [(-800, false), (-400, false), (-180, true), (100, false),
                                                      (2_000, false), (3_500, false), (2_900, true), (2_950, false)]
        for step in path {
            #expect(watch.check(Self.request(east: 0, north: step.north, radiusM: 50), among: [pack]) == step.entered,
                    "north \(step.north)")
        }
        // Precheck conservative: for circles around the square at every
        // bearing and distance, mayIntersect holds wherever intersects does.
        for bearing in stride(from: 0.0, to: 360, by: 15) {
            for distance in stride(from: 0.0, to: 4_000, by: 125) {
                for radius in [10.0, 300, 1_414] {
                    let b = bearing * .pi / 180
                    let r = Self.request(east: distance * sin(b), north: 1_400 + distance * cos(b), radiusM: radius)
                    let exact = pack.coverage.intersects(latitude: r.latitude, longitude: r.longitude, radiusM: radius)
                    if exact {
                        #expect(pack.mayIntersect(latitude: r.latitude, longitude: r.longitude, radiusM: radius))
                    }
                }
            }
        }
    }

    @Test("Packs first watched after initialisation (the app's first library sync after the first request): those the circle already intersects count as seen, no coverageEntered for them; a pack entered later still raises one")
    func watchSetAfterInitialisation() throws {
        let (near, ahead) = (try Self.near(), try Self.ahead())
        let packs = [RoadCoverageWatch.Pack(try Self.candidate("near", near)),
                     RoadCoverageWatch.Pack(try Self.candidate("ahead", ahead))]
        var run = LiveNavigationRun(sessionID: Attach.sessionID, config: Attach.config(), appBuild: "t")
        var triggers: [RoadSelectionTrigger?] = []
        for (i, input) in Attach.inputs().enumerated() {
            if i == 300 {
                #expect(run.engine.isInitialized)
                run.setWatchedPacks(packs)
                #expect(run.selectionRule.watch.inside == [near.contentHash])
            }
            run.ingest(input) { _ in }
            if let request = run.newSelectionRequest { triggers.append(request.trigger) }
        }
        // Without roads every fix used raises an N3.3 request (trigger nil);
        // near is never "entered", ahead once.
        #expect(triggers.filter { $0 == .coverageEntered }.count == 1)
        #expect(triggers.contains(nil))
    }

    @Test("No watched pack, or every one attached: the coverage trigger computes nothing (the acceptance replays' path, roads from the start)")
    func watchIdle() throws {
        let near = try Self.near()
        var run = LiveNavigationRun(sessionID: Attach.sessionID, config: Attach.config(), appBuild: "t",
                                    roads: try RoadNetwork(packs: [near]))
        run.setWatchedPacks([RoadCoverageWatch.Pack(try Self.candidate("near", near))])
        var requests = 0
        for input in Attach.inputs() {
            run.ingest(input) { _ in }
            if run.newSelectionRequest != nil { requests += 1 }
        }
        #expect(requests == 0 && run.selectionRule.watch.checks == 0)
    }

    // MARK: Library change

    @Test("libraryChanged: before initialisation no request; after it, a libraryChanged request at once (afterInputs = inputs, the estimate at the latest arrival), the new packs watched and primed (no coverageEntered right after)")
    func libraryChangedRequest() throws {
        let (near, ahead) = (try Self.near(), try Self.ahead())
        var run = LiveNavigationRun(sessionID: Attach.sessionID, config: Attach.config(), appBuild: "t")
        let packs = [RoadCoverageWatch.Pack(try Self.candidate("near", near)),
                     RoadCoverageWatch.Pack(try Self.candidate("ahead", ahead))]
        #expect(run.libraryChanged(packs) == nil)
        let inputs = Attach.inputs()
        for input in inputs.prefix(3_000) { run.ingest(input) { _ in } }
        let raised = run.libraryChanged(packs)
        let request = try #require(raised)
        #expect(request.trigger == .libraryChanged && request.afterInputs == 3_000 && run.newSelectionRequest == request)
        let t = try #require(run.engine.latestArrival)
        let estimate = try #require(run.engine.estimate(at: t))
        #expect(request.t == t && request.latitude == estimate.latitude && request.radiusM == estimate.ellipse.semiMajorM)
        #expect(run.selectionRule.watch.packs.count == 2)
        #expect(run.selectionRule.watch.inside.contains(near.contentHash))
    }

    // MARK: Sidecar v3

    static func roadsLine(_ hashes: [String], afterInputs: Int) -> NavSidecar.Roads {
        NavSidecar.Roads(t: SyntheticDrive.ms(Double(afterInputs)), afterInputs: afterInputs,
                         roads: hashes.map { NavSidecar.Roads.Pack(contentHash: $0, formatVersion: 1, osmTimestamp: 0,
                                                                    gridID: "0123456789abcdef") },
                         roadSetHash: "00000000000000ff")
    }

    @Test("Sidecar v3: several roads lines (increasing afterInputs, each a strict superset) and a roadsSelection trigger round-trip; trigger omitted when nil; a v3 line that is not a superset, or goes back in afterInputs, is refused; a frozen v2 file still reads")
    func sidecarV3() throws {
        var lines = Live.sampleLines()
        let first = Self.roadsLine(["00000000000000a1"], afterInputs: 10)
        let second = Self.roadsLine(["00000000000000a1", "00000000000000b2"], afterInputs: 900)
        let entered = NavSidecar.RoadsSelection(t: SyntheticDrive.ms(9), afterInputs: 900, recordedAfterInputs: 900,
                                                request: .init(radiusM: 30), candidates: [], outcome: .selected,
                                                packs: ["a", "b"], trigger: .coverageEntered)
        let plain = NavSidecar.RoadsSelection(t: SyntheticDrive.ms(1), afterInputs: 10, recordedAfterInputs: 10,
                                              request: .init(radiusM: 30), candidates: [], outcome: .selected, packs: ["a"])
        lines.insert(contentsOf: [.roadsSelection(plain), .roads(first)], at: 2)
        lines.append(contentsOf: [.roadsSelection(entered), .roads(second)])
        let data = try Live.encoded(lines)
        let contents = try NavSidecar.read(data)
        #expect(contents.header.sidecarVersion == 3)
        #expect(contents.roads == [first, second])
        #expect(contents.roadsSelections == [plain, entered])
        let text = String(decoding: data, as: UTF8.self).split(separator: "\n")
        #expect(text.filter { $0.contains("\"trigger\"") }.count == 1)
        #expect(text.contains { $0.contains("\"trigger\":\"coverageEntered\"") })
        #expect(entered.summary.contains("(coverageEntered): selected") && !plain.summary.contains("("))
        #expect(!entered.isRepeat(of: NavSidecar.RoadsSelection(t: entered.t, afterInputs: 1, recordedAfterInputs: 1,
                                                                 request: .init(radiusM: 1), candidates: [],
                                                                 outcome: .selected, packs: ["a", "b"])))

        // Back in afterInputs and shrunk: the afterInputs check comes first.
        let backAndShrunk = Live.sampleLines() + [.roads(second), .roads(first)]
        #expect(throws: NavSidecar.ReadError.invalidRoadsLine(number: 8, reason: "afterInputs 10 is before the previous line's 900")) {
            try NavSidecar.read(Live.encoded(backAndShrunk))
        }
        // afterInputs non-decreasing, packs not a strict superset (R75.1-2):
        // the same set (later, or at the same afterInputs), a disjoint set, a
        // shrunk set.
        let notSuperset = NavSidecar.ReadError.invalidRoadsLine(
            number: 8, reason: "its packs are not a strict superset of the previous line's")
        let cases: [(String, NavSidecar.Roads, NavSidecar.Roads)] = [
            ("same set", first, Self.roadsLine(["00000000000000a1"], afterInputs: 900)),
            ("same set, same afterInputs", Self.roadsLine(["00000000000000a1"], afterInputs: 900),
             Self.roadsLine(["00000000000000a1"], afterInputs: 900)),
            ("disjoint", first, Self.roadsLine(["00000000000000b2"], afterInputs: 900)),
            ("shrunk", Self.roadsLine(["00000000000000a1", "00000000000000b2"], afterInputs: 10),
             Self.roadsLine(["00000000000000a1"], afterInputs: 900)),
        ]
        for (label, a, b) in cases {
            #expect(throws: notSuperset, "\(label)") {
                try NavSidecar.read(Live.encoded(Live.sampleLines() + [.roads(a), .roads(b)]))
            }
        }
        let backwards = Live.sampleLines() + [.roads(Self.roadsLine(["00000000000000a1"], afterInputs: 950)), .roads(second)]
        #expect(throws: NavSidecar.ReadError.invalidRoadsLine(number: 8, reason: "afterInputs 900 is before the previous line's 950")) {
            try NavSidecar.read(Live.encoded(backwards))
        }
        // The same afterInputs twice is allowed (two attempts finished between two inputs).
        let same = Live.sampleLines() + [.roads(Self.roadsLine(["00000000000000a1"], afterInputs: 900)), .roads(second)]
        #expect(try NavSidecar.read(Live.encoded(same)).roads.count == 2)

        // A v2 file as the app wrote it (one roads line) still reads.
        let v2 = """
            {"appBuild":"1","configHash":"0123456789abcdef","configJSON":"{}","kind":"header",\
            "seed":7,"sessionID":"3F2504E0-4F89-41D3-9A0C-0305E82C3301","sidecarVersion":2}
            {"afterInputs":9,"kind":"roads","roadSetHash":"9d21d4bba507904d","roads":[{"contentHash":"00000000000000a1",\
            "formatVersion":1,"gridID":"e23a18f7e04746f0","osmTimestamp":1}],"t":55652875}
            {"afterInputs":5,"candidates":[{"covering":true,"name":"a.roadpack","state":"verified"}],\
            "kind":"roadsSelection","outcome":"selected","packs":["a.roadpack"],"recordedAfterInputs":9,\
            "request":{"radiusM":2437.5},"t":43955667}

            """
        let old = try NavSidecar.read(Data(v2.utf8))
        #expect(old.header.sidecarVersion == 2 && old.roads.count == 1 && old.roads[0].afterInputs == 9)
        #expect(old.roadsSelections.count == 1 && old.roadsSelections[0].trigger == nil)
    }

    // MARK: Replay: schedule, injection, compare

    @Test("Replay schedule: runLive and the metrics replay follow two roads lines (attach, then extend from the same open packs); compare against them is exact with the union given (extra packs fine), and not exact with a pack missing")
    func replaySchedule() throws {
        let (near, ahead, far) = (try Self.near(), try Self.ahead(), try Self.far())
        let given = ReplayRoadSet(try RoadNetwork(packs: [near, ahead, far]))
        let inputs = Attach.inputs()
        let points = [ReplayRoadAttachPoint(afterInputs: 200, contentHashes: [near.contentHash]),
                      ReplayRoadAttachPoint(afterInputs: 2_000, contentHashes: [near.contentHash, ahead.contentHash])]
        let lines = NavigationReplay.liveLines(inputs: inputs, sessionID: Attach.sessionID, config: Attach.config(),
                                               roads: given, attach: .schedule(points))
        let roads = Self.roadsLines(lines)
        #expect(roads.map(\.afterInputs) == [200, 2_000])
        #expect(roads.map { $0.roads.count } == [1, 2])

        // The same as a run attaching and extending by hand.
        var run = LiveNavigationRun(sessionID: Attach.sessionID, config: Attach.config(), appBuild: "replay")
        var manual = run.openingLines
        let first = try RoadNetwork(packs: [near])
        for (i, input) in inputs.enumerated() {
            if i == 200 { try run.attachRoads(first) { manual.append($0) } }
            if i == 2_000 { try run.extendRoads(try RoadNetwork(packs: [near, ahead])) { manual.append($0) } }
            run.ingest(input) { manual.append($0) }
        }
        #expect(try Attach.digest(manual) == (try Attach.digest(lines)))
        #expect(Self.roadsLines(manual) == roads)

        // The metrics replay attaches and extends after the same inputs.
        var options = ReplayOptions(gps: .use, config: Attach.config())
        options.roads = given
        options.roadAttach = .schedule(points)
        let result = NavigationReplay.run(logName: "x", inputs: inputs, options: options)
        #expect(result.roadsAttachedAfterInputs == 200 && result.roadsExtendedAfterInputs == [2_000])
        #expect(result.mode.hasSuffix("-attach-sidecar"))

        // Compare: a sidecar with these lines, read back, against the replay.
        let sidecar = try NavSidecar.read(Live.encoded(lines))
        let back = sidecar.roads.compactMap(ReplayRoadAttachPoint.init)
        #expect(back == points)
        let replayed = NavigationReplay.liveLines(inputs: inputs, sessionID: Attach.sessionID, config: Attach.config(),
                                                  roads: given, attach: .schedule(back))
        let hashes = Set(given.network.packs.map { NavigationSeed.hex($0.contentHash) })
        let exact = SidecarComparison(sidecar: sidecar, replay: replayed, replayConfig: Attach.config(),
                                      givenRoadSetHash: given.roadSetHashHex, givenPackHashes: hashes)
        #expect(exact.exact && exact.roadsMismatch == nil, "\(exact.report(tolerance: .default))")
        #expect(exact.report(tolerance: .default).contains("then roadSetHash"))

        // A sidecar pack not given: not exact, named.
        let partial = ReplayRoadSet(try RoadNetwork(packs: [near, far]))
        let missingLines = NavigationReplay.liveLines(inputs: inputs, sessionID: Attach.sessionID, config: Attach.config(),
                                                      roads: partial, attach: .schedule(back))
        let missing = SidecarComparison(sidecar: sidecar, replay: missingLines, replayConfig: Attach.config(),
                                        givenRoadSetHash: partial.roadSetHashHex,
                                        givenPackHashes: Set(partial.network.packs.map { NavigationSeed.hex($0.contentHash) }))
        #expect(!missing.exact && missing.roadsMismatch?.contains("not given") == true)
    }

    @Test("Replay injection: a pack held back until an input arrives as a library change (libraryChanged request, extension at once) in runLive and the metrics replay alike; the written v3 sidecar compares exact when replayed by its schedule (P4)")
    func replayInjection() throws {
        let (near, ahead) = (try Self.near(), try Self.ahead())
        let given = ReplayRoadSet(try RoadNetwork(packs: [near, ahead]),
                                  names: [near.contentHash: "near.roadpack", ahead.contentHash: "ahead.roadpack"])
        let inputs = Attach.inputs()
        // Before the car reaches ahead's coverage the pack is not there; it
        // arrives at 10 s, while the circle is still outside it, so the
        // extension comes from the coverage trigger later; at 40 s, inside,
        // the library change itself extends.
        for (at, trigger) in [(10.0, RoadSelectionTrigger.coverageEntered), (40.0, .libraryChanged)] {
            let injection = ReplayRoadInjection(when: .time(seconds: at), contentHashes: [ahead.contentHash])
            let lines = NavigationReplay.liveLines(inputs: inputs, sessionID: Attach.sessionID, config: Attach.config(),
                                                   roads: given, attach: .live, injections: [injection])
            let roads = Self.roadsLines(lines)
            #expect(roads.count == 2, "at \(at)")
            #expect(Self.selections(lines).last { $0.outcome == .selected }?.trigger == trigger, "at \(at)")
            let extendedAt = try #require(roads.last?.afterInputs)
            let firstAfter = try #require(inputs.firstIndex { $0.arrival.seconds >= at })
            if trigger == .libraryChanged { #expect(extendedAt == firstAfter) } else { #expect(extendedAt > firstAfter) }

            var options = ReplayOptions(gps: .use, config: Attach.config())
            options.asLive = true
            options.fileOrder = true
            options.roads = given
            options.roadAttach = .live
            options.roadInjections = [injection]
            let result = NavigationReplay.run(logName: "x", inputs: inputs, options: options)
            #expect(result.roadsAttachedAfterInputs == roads[0].afterInputs, "at \(at)")
            #expect(result.roadsExtendedAfterInputs == [extendedAt], "at \(at)")
            #expect(result.mode.contains("-inject-") && result.mode.hasSuffix("-at-\(Int(at))s"))

            // P4: the written sidecar, replayed by its roads lines, is exact.
            let sidecar = try NavSidecar.read(Live.encoded(lines))
            #expect(sidecar.header.sidecarVersion == 3 && sidecar.roads.count == 2)
            let replayed = NavigationReplay.liveLines(
                inputs: inputs, sessionID: Attach.sessionID, config: Attach.config(), roads: given,
                attach: .schedule(sidecar.roads.compactMap(ReplayRoadAttachPoint.init)))
            let comparison = SidecarComparison(
                sidecar: sidecar, replay: replayed, replayConfig: Attach.config(), givenRoadSetHash: given.roadSetHashHex,
                givenPackHashes: Set(given.network.packs.map { NavigationSeed.hex($0.contentHash) }))
            #expect(comparison.exact, "\(comparison.report(tolerance: .default))")
        }
    }
}
