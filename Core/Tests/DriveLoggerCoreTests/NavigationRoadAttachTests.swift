import Foundation
import Testing

@testable import DriveLoggerCore
@testable import RoadPackBuild

/// N3.3 item 1: roads attached to a running engine
/// (`NavigationEngine.attachRoads`, `LiveNavigationRun.attachRoads`) and the
/// road selection rule. Synthetic drive and packs near (0, 0) only.
@Suite("Navigation roads attached mid-run (N3.3)")
struct NavigationRoadAttachTests {
    typealias S = SyntheticDrive
    typealias N = RoadFixture.Node

    static let sessionID = UUID(uuidString: "00000000-0000-4000-8000-000000000033")!

    static func config() -> NavigationConfig { S.config(particles: 200, seed: 33) }

    /// The road the drive is on: north–south through x = 0. `radiusM`: the
    /// pack's guaranteed search radius.
    static func network(radiusM: Double = 50) throws -> RoadNetwork {
        let way = RoadFixture.way(1, ["highway": "residential"],
                                  [N(id: 10, east: 0, north: -3000), N(id: 11, east: 0, north: 3000)])
        return try RoadNetwork(packs: [RoadFixture.build([way], grid: RoadFixture.grid(radiusM: radiusM))])
    }

    /// 60 s north at 12 m/s from (0, −500) on the road; clean fixes 5 m
    /// east of the truth for the first 20 s, then none; a pin at 40 s on
    /// the truth (`pinEast` metres east of it), taken at 43 km/h.
    static func inputs(pinEast: Double = 0, pinSpan: Double = 200) -> [NavigationInput] {
        let drive = S(initialHeadingDeg: 0, initialSpeed: 12, [.straight(seconds: 60, speed: 12)])
        let clean = S.cleanFix()
        let start = (east: 0.0, north: -500.0)
        let pinAt = drive.truth(at: 40)
        let p = S.plane.geodetic(east: start.east + pinAt.east + pinEast, north: start.north + pinAt.north)
        let pin = LogEvent(timestamp: S.ms(40), payload: .manualFix(ManualFixSample(
            latitude: p.latitude, longitude: p.longitude, pressedT: S.ms(40), mapSpanM: pinSpan,
            speedSource: "obd", gateSpeedKmh: 43)))
        let events = drive.events(seed: 5, gyroNoise: 0.001, fix: { t, state, rng in
            guard t < 20, var f = clean(t, state, &rng) else { return nil }
            f.east += start.east + 5
            f.north += start.north
            return f
        }, extra: [pin])
        return S.inputs(events)
    }

    /// Lines without the timing diagnostics (not deterministic).
    static func stripped(_ lines: [NavSidecar.Line]) -> [NavSidecar.Line] {
        lines.map { line in
            switch line {
            case .estimate(var e):
                e.msPerStep = nil
                e.maxStepMs = nil
                return .estimate(e)
            case .pin(var p):
                p.prior?.msPerStep = nil
                p.prior?.maxStepMs = nil
                return .pin(p)
            default:
                return line
            }
        }
    }

    /// FNV-1a 64 of the encoded estimate and pin lines, timing removed.
    static func digest(_ lines: [NavSidecar.Line]) throws -> String {
        let encoder = NavSidecar.makeEncoder()
        var bytes = Data()
        for line in stripped(lines) {
            if case .header = line { continue }
            bytes.append(try NavSidecar.encode(line, with: encoder))
        }
        return NavigationSeed.hex(NavigationSeed.fnv1a64(bytes))
    }

    /// Runs `inputs` through a `LiveNavigationRun`, attaching `network`
    /// when `inputs` == `attachAfter`. Returns the lines and how many were
    /// emitted before the attach.
    static func live(_ inputs: [NavigationInput], network: RoadNetwork? = nil, attachAfter: Int? = nil,
                     config: NavigationConfig = config())
        -> (run: LiveNavigationRun, lines: [NavSidecar.Line], beforeAttach: Int) {
        var run = LiveNavigationRun(sessionID: sessionID, config: config, appBuild: "test")
        var lines: [NavSidecar.Line] = []
        var beforeAttach = -1
        func attachIfDue() {
            guard let network, attachAfter == run.inputs, beforeAttach < 0 else { return }
            beforeAttach = lines.count
            try? run.attachRoads(network) { lines.append($0) }
        }
        for input in inputs {
            attachIfDue()
            run.ingest(input) { lines.append($0) }
        }
        attachIfDue()
        return (run, lines, beforeAttach)
    }

    static func state(_ e: NavigationEngine) -> [[Double]] {
        [e.east, e.north, e.covEE, e.covEN, e.covNN, e.heading, e.scale, e.speedOffset, e.weight, e.logWeight]
    }

    // MARK: (a) no network: today's output

    /// Pinned on the code before N3.3 (the same fixture through the
    /// LiveNavigationRun of commit 292ef8c): 60 estimate lines and 1 pin.
    static let noRoadsDigest = "4bdd92024be69268"

    @Test("(a) No network: the estimate and pin lines are byte-identical to the loop before N3.3; a selector that finds nothing changes nothing")
    func noNetworkUnchanged() throws {
        let inputs = Self.inputs()
        let plain = Self.live(inputs)
        #expect(plain.lines.count == 61)
        #expect(try Self.digest(plain.lines) == Self.noRoadsDigest)
        #expect(plain.run.roads == nil && plain.run.engine.roadNetwork == nil)

        var run = LiveNavigationRun(sessionID: Self.sessionID, config: Self.config(), appBuild: "test")
        var lines: [NavSidecar.Line] = []
        var requests: [RoadSelectionRequest] = []
        for input in inputs {
            run.ingest(input, selectRoads: { requests.append($0); return nil }) { lines.append($0) }
        }
        #expect(try Self.digest(lines) == Self.noRoadsDigest)
        // One request at initialisation, then one per fix used and the pin.
        let positions = run.engine.counters.fixesUsed + run.engine.counters.manualFixes
        #expect(requests.count == positions && positions == 21)
        #expect(requests.allSatisfy { $0.radiusM.isFinite && $0.radiusM > 0 && $0.latitude.isFinite })
        #expect(requests.map(\.afterInputs) == requests.map(\.afterInputs).sorted())
        #expect(run.selectionRequest == requests.last)
    }

    /// R32.1-1: what a request holds, not only that it is finite.
    @Test("(a2) Each selection request is the estimate at the latest arrival of an engine fed the same inputs: centre, 95 % semi-major axis, afterInputs, t")
    func selectionRequestContents() throws {
        let inputs = Self.inputs()
        var run = LiveNavigationRun(sessionID: Self.sessionID, config: Self.config(), appBuild: "test")
        // Fed the same inputs in lockstep, independently of the run.
        var reference = NavigationEngine(config: Self.config())
        var requests = 0
        var initialisationChecked = false
        var pinChecked = false
        var majorDiffersFromMinor = false
        for (index, input) in inputs.enumerated() {
            let wasInitialized = reference.isInitialized
            run.ingest(input) { _ in }
            reference.ingest(input)
            guard let request = run.newSelectionRequest else { continue }
            requests += 1
            let t = try #require(reference.latestArrival)
            let expected = try #require(reference.estimate(at: t))
            #expect(request.latitude == expected.latitude, "input \(index)")
            #expect(request.longitude == expected.longitude, "input \(index)")
            #expect(request.radiusM == expected.ellipse.semiMajorM, "input \(index)")
            #expect(request.afterInputs == index + 1 && request.afterInputs == run.inputs, "input \(index)")
            #expect(request.t == input.arrival && request.t == t, "input \(index)")
            if expected.ellipse.semiMajorM != expected.ellipse.semiMinorM { majorDiffersFromMinor = true }
            if !wasInitialized {
                // The initialisation request comes first.
                #expect(requests == 1)
                initialisationChecked = true
            }
            if case .manualFix = input { pinChecked = true }
        }
        #expect(initialisationChecked && pinChecked && requests == 21)
        // Otherwise semi-major and semi-minor could not be told apart.
        #expect(majorDiffersFromMinor)
    }

    // MARK: (b) attach after k inputs

    @Test("(b) Attach after k inputs: every line before the attach is the no-roads run's; the engine state there too")
    func attachAfterK() throws {
        let inputs = Self.inputs()
        let net = try Self.network()
        let plain = Self.stripped(Self.live(inputs).lines)
        let firstInit = try #require(inputs.indices.first { k in
            var e = NavigationEngine(config: Self.config())
            for input in inputs[...k] { e.ingest(input) }
            return e.isInitialized
        })
        for k in [1, firstInit + 1, firstInit + 700, 3_000, inputs.count - 1] {
            let attached = Self.live(inputs, network: net, attachAfter: k)
            let lines = Self.stripped(attached.lines)
            #expect(attached.beforeAttach >= 0)
            #expect(Array(lines[..<attached.beforeAttach]) == Array(plain[..<attached.beforeAttach]), "k \(k)")
            let roads = try #require(attached.run.roads)
            #expect(roads.afterInputs == k)
            #expect(roads.t == inputs[k - 1].arrival)
            #expect(attached.run.engine.roadNetwork === net)

            // The engine at the attach is the no-roads engine.
            var a = NavigationEngine(config: Self.config())
            for input in inputs[..<k] { a.ingest(input) }
            var b = a
            try b.attachRoads(net)
            #expect(Self.state(a) == Self.state(b))
            #expect(a.estimate(at: inputs[k - 1].arrival) == b.estimate(at: inputs[k - 1].arrival))
        }
    }

    // MARK: (c) from the start = attach at 0

    @Test("(c) Roads from the start equal an attach before the first input: engine and live run, bit for bit")
    func fromStartEqualsAttachAtZero() throws {
        let inputs = Self.inputs()
        let net = try Self.network()
        var a = NavigationEngine(config: Self.config(), roads: net)
        var b = NavigationEngine(config: Self.config())
        try b.attachRoads(net)
        for input in inputs {
            a.ingest(input)
            b.ingest(input)
        }
        #expect(Self.state(a) == Self.state(b))
        #expect(a.roadEdge == b.roadEdge && a.roadLevel == b.roadLevel && a.offRoadM == b.offRoadM)
        #expect(a.counters == b.counters && a.counters.roadUpdates > 0)

        var fromStart = LiveNavigationRun(sessionID: Self.sessionID, config: Self.config(), appBuild: "test", roads: net)
        var lines: [NavSidecar.Line] = []
        for input in inputs { fromStart.ingest(input) { lines.append($0) } }
        let atZero = Self.live(inputs, network: net, attachAfter: 0)
        // The roads line: after the header at init, emitted by the attach.
        #expect(Self.stripped(fromStart.openingLines + lines) == Self.stripped([.header(atZero.run.header)] + atZero.lines))
        #expect(fromStart.roads?.afterInputs == 0 && fromStart.roads?.t == nil)
        #expect(atZero.run.roads?.afterInputs == 0 && atZero.run.roads?.t == nil)
        #expect(fromStart.header == atZero.run.header)
        #expect(fromStart.selectionRequest == nil && fromStart.newSelectionRequest == nil)
    }

    // MARK: (d) refusal

    @Test("(d) A pack that would change the validated config is refused: the run goes on without roads, output unchanged")
    func refusalKeepsNoRoads() throws {
        let inputs = Self.inputs()
        let narrow = try Self.network(radiusM: 30)
        var engine = NavigationEngine(config: Self.config())
        for input in inputs[..<2_000] { engine.ingest(input) }
        let before = engine
        #expect(throws: RoadAttachRefusal.configWouldChange(keys: ["roadSearchRadiusM"])) { try engine.attachRoads(narrow) }
        #expect(engine.roadNetwork == nil && Self.state(engine) == Self.state(before))

        let refused = Self.live(inputs, network: narrow, attachAfter: 2_000)
        #expect(try Self.digest(refused.lines) == Self.noRoadsDigest)
        #expect(refused.run.roads == nil)
        #expect(refused.run.roadsRefusal == .configWouldChange(keys: ["roadSearchRadiusM"]))
        #expect(refused.run.roadsRefusal?.description.contains("roadSearchRadiusM") == true)
        let atInit = LiveNavigationRun(sessionID: Self.sessionID, config: Self.config(), appBuild: "test", roads: narrow)
        #expect(atInit.roads == nil && atInit.roadsRefusal != nil)

        // A second network is refused too: the first stays.
        let net = try Self.network()
        var twice = NavigationEngine(config: Self.config())
        try twice.attachRoads(net)
        #expect(throws: RoadAttachRefusal.alreadyAttached) { try twice.attachRoads(try Self.network()) }
        #expect(twice.roadNetwork === net)
    }

    // MARK: (e) a manual reset keeps the network

    @Test("(e) A manual-fix reset of the cloud keeps the network and raises no new selection request")
    func manualResetKeepsNetwork() throws {
        // The pin is 3 km east of the cloud: no particle is compatible.
        let inputs = Self.inputs(pinEast: 3_000, pinSpan: 100)
        let net = try Self.network()
        var run = LiveNavigationRun(sessionID: Self.sessionID, config: Self.config(), appBuild: "test")
        var asked = 0
        var requestsAfterAttach = 0
        for input in inputs {
            run.ingest(input, selectRoads: { _ in asked += 1; return net }) { _ in }
            if run.roads != nil, run.newSelectionRequest != nil || run.selectionRequest != nil { requestsAfterAttach += 1 }
        }
        #expect(run.engine.counters.manualResets == 1)
        #expect(asked == 1 && requestsAfterAttach == 0)
        #expect(run.engine.roadNetwork === net)
        let roads = try #require(run.roads)
        // Attached right after the input that initialised the engine.
        var e = NavigationEngine(config: Self.config())
        for input in inputs[..<roads.afterInputs] { e.ingest(input) }
        #expect(e.isInitialized)
        var f = NavigationEngine(config: Self.config())
        for input in inputs[..<(roads.afterInputs - 1)] { f.ingest(input) }
        #expect(!f.isInitialized)
    }

    // MARK: (f) roads matter

    @Test("(f) Sanity: with roads the run differs from no roads and ends closer to the road the car is on")
    func roadsMatter() throws {
        let inputs = Self.inputs()
        let net = try Self.network()
        let plain = Self.live(inputs)
        let roads = Self.live(inputs, network: net, attachAfter: 1)
        #expect(try Self.digest(roads.lines) != Self.noRoadsDigest)
        #expect(roads.run.engine.counters.roadUpdates > 0)
        let end = try #require(inputs.last?.arrival)
        func east(_ run: LiveNavigationRun) throws -> Double {
            let e = try #require(run.engine.estimate(at: end))
            return S.plane.enu(latitude: e.latitude, longitude: e.longitude).east
        }
        let with = try east(roads.run), without = try east(plain.run)
        #expect(abs(with) < abs(without), "with roads \(with) m, without \(without) m")
    }
}
