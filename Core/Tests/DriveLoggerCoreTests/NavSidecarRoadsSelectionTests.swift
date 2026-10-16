import Foundation
import Testing

@testable import DriveLoggerCore
@testable import RoadPackBuild

/// The sidecar's `roadsSelection` line (within v2, no version bump): one
/// line per road selection attempt and how it ended, built by
/// `RoadPackSelection.attempt` and `LiveNavigationRun.finishSelection`.
/// Diagnostic only: it never changes another line nor the compare verdict.
/// Synthetic packs and drive near (0, 0) only.
@Suite("Navigation sidecar roadsSelection line")
struct NavSidecarRoadsSelectionTests {
    typealias Catalog = RoadPackCatalogTests
    typealias Attach = NavigationRoadAttachTests
    typealias Live = NavigationLiveTests
    typealias Selection = NavSidecar.RoadsSelection

    /// A request centred `east`, `north` metres from (0, 0).
    static func request(_ east: Double, _ north: Double, radiusM: Double, afterInputs: Int = 17,
                        t: Double = 12.5) -> RoadSelectionRequest {
        let p = SyntheticDrive.plane.geodetic(east: east, north: north)
        return RoadSelectionRequest(latitude: p.latitude, longitude: p.longitude, radiusM: radiusM,
                                    afterInputs: afterInputs, t: MonotonicTimestamp(seconds: t))
    }

    static let scanRefusal = RoadPackSelection.Refusal(names: ["bad.roadpack"], reason: "truncated: 64 bytes missing")

    /// The packs A (around 0, 0), B (8 km east) and D (around 0, 0 on another grid).
    static func candidates(_ names: [String]) throws -> [RoadPackSelection.Candidate] {
        let data = ["a.roadpack": try Catalog.packA(), "b.roadpack": try Catalog.packB(), "d.roadpack": try Catalog.packD()]
        return try Catalog.candidates(names.map { ($0, data[$0]!) })
    }

    /// The line as JSON text, and as an object.
    static func json(_ selection: Selection) throws -> (text: String, object: [String: Any]) {
        let data = try NavSidecar.encode(.roadsSelection(selection), with: NavSidecar.makeEncoder())
        let text = String(decoding: data, as: UTF8.self)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return (text, object)
    }

    /// Every line: kind, the request's t and afterInputs, the radius only,
    /// never a position.
    static func expectCommon(_ selection: Selection, _ request: RoadSelectionRequest, recordedAfterInputs: Int,
                             _ label: String) throws {
        let (text, object) = try json(selection)
        #expect(object["kind"] as? String == "roadsSelection", "\(label)")
        #expect(object["t"] as? Int64 == request.t.nanoseconds, "\(label)")
        #expect(object["afterInputs"] as? Int == request.afterInputs, "\(label)")
        #expect(object["recordedAfterInputs"] as? Int == recordedAfterInputs, "\(label)")
        let req = try #require(object["request"] as? [String: Any], "\(label)")
        #expect(Set(req.keys) == ["radiusM"], "\(label)")
        for forbidden in ["latitude", "longitude", "\"lat", "\"lon"] {
            #expect(!text.contains(forbidden), "\(label): \(forbidden) in \(text)")
        }
        #expect(text.hasSuffix("}\n") && text.split(separator: "\n").count == 1, "\(label)")
    }

    // MARK: Outcomes

    @Test("Each outcome (selected, noneCovering, refused by build and as known, unusableRequest, noPacks, unfinished) gives its line: candidates verified/refused with covering and reason, packs and reason where they apply, no latitude or longitude key")
    func outcomes() throws {
        let ab = try Self.candidates(["a.roadpack", "b.roadpack"])
        let refused = [Self.scanRefusal]
        let here = Self.request(0, 0, radiusM: 100)

        // selected: A covers, B does not, the scan-refused file is listed.
        let selected = RoadPackSelection.attempt(ab, refusedAtScan: refused, request: here)
        #expect(selected.outcome == .selected && selected.network?.packs.count == 1)
        let selectedLine = selected.line(recordedAfterInputs: 20)
        try Self.expectCommon(selectedLine, here, recordedAfterInputs: 20, "selected")
        #expect(selectedLine.packs == ["a.roadpack"] && selectedLine.reason == nil)
        #expect(selectedLine.candidates == [
            Selection.Candidate(name: "a.roadpack", state: .verified, covering: true),
            Selection.Candidate(name: "b.roadpack", state: .verified, covering: false),
            Selection.Candidate(name: "bad.roadpack", state: .refused, reason: Self.scanRefusal.reason),
        ])
        let (selectedText, selectedObject) = try Self.json(selectedLine)
        #expect(selectedObject["outcome"] as? String == "selected" && selectedObject["reason"] == nil)
        #expect(selectedText.contains(#"{"covering":true,"name":"a.roadpack","state":"verified"}"#))
        #expect(selectedText.contains(#"{"name":"bad.roadpack","reason":"truncated: 64 bytes missing","state":"refused"}"#))

        // noneCovering: 50 km south.
        let far = Self.request(0, -50_000, radiusM: 1000)
        let none = RoadPackSelection.attempt(ab, refusedAtScan: refused, request: far).line(recordedAfterInputs: 17)
        try Self.expectCommon(none, far, recordedAfterInputs: 17, "noneCovering")
        #expect(none.outcome == .noneCovering && none.packs == nil && none.reason == nil)
        #expect(none.candidates?.compactMap(\.covering) == [false, false])
        let (_, noneObject) = try Self.json(none)
        #expect(noneObject["packs"] == nil && noneObject["reason"] == nil && noneObject["outcome"] as? String == "noneCovering")

        // refused: A and D cannot be used together (different grids).
        let ad = try Self.candidates(["a.roadpack", "d.roadpack"])
        let mismatch = RoadPackSelection.attempt(ad, request: here)
        #expect(mismatch.network == nil)
        let mismatchLine = mismatch.line(recordedAfterInputs: 17)
        try Self.expectCommon(mismatchLine, here, recordedAfterInputs: 17, "refused")
        #expect(mismatchLine.outcome == .refused && mismatchLine.packs == ["a.roadpack", "d.roadpack"])
        #expect(mismatchLine.reason?.contains("different grids") == true)
        #expect(mismatchLine.refusal == RoadPackSelection.Refusal(names: ["a.roadpack", "d.roadpack"],
                                                                  reason: mismatchLine.reason ?? ""))

        // refused as known (the app's "already refused"): not built again.
        let known = RoadPackSelection.Refusal(names: ["a.roadpack"], reason: "refused earlier")
        let again = RoadPackSelection.attempt(ab, request: here, knownRefusals: [known])
        #expect(again.outcome == .refused && again.network == nil)
        #expect(again.packs == ["a.roadpack"] && again.reason == "refused earlier")

        // unusableRequest: a non-finite centre; covering false for each.
        var bad = here
        bad.latitude = .nan
        let unusable = RoadPackSelection.attempt(ab, refusedAtScan: refused, request: bad).line(recordedAfterInputs: 17)
        try Self.expectCommon(unusable, bad, recordedAfterInputs: 17, "unusableRequest")
        #expect(unusable.outcome == .unusableRequest && unusable.candidates?.count == 3)
        #expect(unusable.candidates?.compactMap(\.covering) == [false, false])

        // noPacks: no verified candidate (every file refused at scan, or none).
        for scan in [refused, []] {
            let noPacks = RoadPackSelection.attempt([], refusedAtScan: scan, request: here).line(recordedAfterInputs: 17)
            try Self.expectCommon(noPacks, here, recordedAfterInputs: 17, "noPacks \(scan.count)")
            #expect(noPacks.outcome == .noPacks && noPacks.packs == nil && noPacks.reason == nil)
            #expect(noPacks.candidates == scan.map { Selection.Candidate(name: $0.names[0], state: .refused, reason: $0.reason) })
            let (text, _) = try Self.json(noPacks)
            #expect(text.contains(#""candidates":["#) && text.contains(#""outcome":"noPacks""#))
        }

        // unfinished: no candidates (not known), recorded at the end.
        let unfinished = Selection(unfinished: here, recordedAfterInputs: 99)
        try Self.expectCommon(unfinished, here, recordedAfterInputs: 99, "unfinished")
        let (_, unfinishedObject) = try Self.json(unfinished)
        #expect(unfinishedObject["outcome"] as? String == "unfinished" && unfinishedObject["candidates"] == nil)
        #expect(Set(unfinishedObject.keys) == ["afterInputs", "kind", "outcome", "recordedAfterInputs", "request", "t"])
        var run = LiveNavigationRun(sessionID: Attach.sessionID, config: Attach.config(), appBuild: "t")
        for input in Attach.inputs()[..<50] { run.ingest(input) { _ in } }
        #expect(run.unfinishedSelectionLine(here) == .roadsSelection(Selection(unfinished: here, recordedAfterInputs: 50)))
    }

    @Test("finishSelection: a selected attempt attaches; its roadsSelection line comes right before the roads line; an attach the run refuses is a refused line with that reason and no roads line")
    func finishSelectionAttachAndRefusal() throws {
        let inputs = Attach.inputs()
        // Find the first request, as the app would raise it.
        var run = LiveNavigationRun(sessionID: Attach.sessionID, config: Attach.config(), appBuild: "t")
        var request: RoadSelectionRequest?
        var index = 0
        while request == nil {
            run.ingest(inputs[index]) { _ in }
            request = run.newSelectionRequest
            index += 1
        }
        let raised = try #require(request)
        // The outcome arrives some inputs later (asynchronous in the app).
        for input in inputs[index..<(index + 30)] { run.ingest(input) { _ in } }
        let atFinish = run.inputs
        #expect(atFinish == raised.afterInputs + 30)

        // The road under the drive, as a pack the run accepts.
        let way = RoadFixture.way(1, ["highway": "residential"],
                                  [RoadFixture.Node(id: 10, east: 0, north: -3000), RoadFixture.Node(id: 11, east: 0, north: 3000)])
        let good = try RoadPackSelection.Candidate(name: "road.roadpack", pack: RoadFixture.build([way]))
        var attached = run
        var lines: [NavSidecar.Line] = []
        let record = attached.finishSelection(RoadPackSelection.attempt([good], request: raised)) { lines.append($0) }
        #expect(lines.count == 2)
        guard case .roadsSelection(let line) = lines[0], case .roads(let roads) = lines[1] else {
            Issue.record("expected roadsSelection then roads: \(lines.map(\.kind))")
            return
        }
        #expect(line == record && line.outcome == .selected && line.packs == ["road.roadpack"])
        try Self.expectCommon(line, raised, recordedAfterInputs: atFinish, "selected, attached")
        #expect(roads.afterInputs == atFinish && attached.roads != nil)

        // A pack whose search radius would change the validated config: the
        // attach is refused; the line says refused with that reason.
        let narrow = try RoadPackSelection.Candidate(name: "narrow.roadpack",
                                                     pack: RoadFixture.build([way], grid: RoadFixture.grid(radiusM: 30)))
        let attempt = RoadPackSelection.attempt([narrow], request: raised)
        #expect(attempt.outcome == .selected && attempt.network != nil)
        var refusedRun = run
        lines = []
        let refused = refusedRun.finishSelection(attempt) { lines.append($0) }
        #expect(lines == [.roadsSelection(refused)] && refusedRun.roads == nil)
        #expect(refused.outcome == .refused && refused.packs == ["narrow.roadpack"])
        #expect(refused.reason == RoadAttachRefusal.configWouldChange(keys: ["roadSearchRadiusM"]).description)
        #expect(refused.candidates == [Selection.Candidate(name: "narrow.roadpack", state: .verified, covering: true)])
        try Self.expectCommon(refused, raised, recordedAfterInputs: atFinish, "attach refused")

        // The synchronous selector remembers the attach refusal: the set is
        // not built again, the next request is refused with the same reason.
        var selector = RoadPackSelector(candidates: [narrow])
        var sync = LiveNavigationRun(sessionID: Attach.sessionID, config: Attach.config(), appBuild: "t")
        var selections: [Selection] = []
        for input in inputs {
            sync.ingest(input, selector: &selector) { if case .roadsSelection(let s) = $0 { selections.append(s) } }
        }
        #expect(selections.count == selector.requests && selections.count > 1 && sync.roads == nil)
        #expect(selections.allSatisfy { $0.outcome == .refused && $0.reason == refused.reason })
        #expect(selections.allSatisfy { $0.afterInputs == $0.recordedAfterInputs })
        #expect(selector.knownRefusals == [RoadPackSelection.Refusal(names: ["narrow.roadpack"], reason: refused.reason ?? "")])
    }

    @Test("No packs: every request of a run gives a noPacks line with empty candidates; no roads line")
    func noPacksRun() throws {
        var selector = RoadPackSelector(candidates: [])
        var run = LiveNavigationRun(sessionID: Attach.sessionID, config: Attach.config(), appBuild: "t")
        var lines: [NavSidecar.Line] = []
        for input in Attach.inputs() { run.ingest(input, selector: &selector) { lines.append($0) } }
        let selections = lines.compactMap { if case .roadsSelection(let s) = $0 { s } else { nil } }
        #expect(!selections.isEmpty && selections.count == selector.requests)
        #expect(selections.allSatisfy { $0.outcome == .noPacks && $0.candidates == [] })
        #expect(!lines.contains { $0.kind == "roads" } && run.roads == nil)
        // The first attempt is the engine's first initialisation.
        #expect(selections[0].afterInputs >= 1 && selections[0].t.nanoseconds > 0)
    }

    // MARK: Reading

    @Test("Round trip through the reader: roadsSelection lines are a known kind (not counted as unknown), several allowed, non-finite radius as strings; an unknown kind is still counted; open outcome and state strings decode; a second roads line is still refused")
    func roundTrip() throws {
        let ab = try Self.candidates(["a.roadpack", "b.roadpack"])
        let here = Self.request(0, 0, radiusM: 100)
        var inf = here
        inf.radiusM = .infinity
        var nan = here
        nan.radiusM = .nan
        let selections = [
            RoadPackSelection.attempt(ab, refusedAtScan: [Self.scanRefusal], request: here).line(recordedAfterInputs: 17),
            RoadPackSelection.attempt(ab, request: inf).line(recordedAfterInputs: 18),
            Selection(unfinished: nan, recordedAfterInputs: 19),
        ]
        var lines = Live.sampleLines()
        lines.insert(.roadsSelection(selections[0]), at: 2)
        lines.insert(.roadsSelection(selections[1]), at: 4)
        lines.append(.roadsSelection(selections[2]))
        let data = try Live.encoded(lines)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains(#""request":{"radiusM":"inf"}"#) && text.contains(#""request":{"radiusM":"nan"}"#))

        let contents = try NavSidecar.read(data)
        #expect(contents.unrecognizedLines == 0 && contents.estimates.count == 3 && contents.pins.count == 2)
        #expect(contents.roadsSelections.count == 3 && contents.roads == nil)
        #expect(Array(contents.roadsSelections[0..<2]) == Array(selections[0..<2]))
        #expect(contents.roadsSelections[2].request.radiusM.isNaN && contents.roadsSelections[2].outcome == .unfinished)
        // Re-encoding the decoded lines gives the same bytes (NaN included).
        let reencoded = try Live.encoded(contents.roadsSelections.map { .roadsSelection($0) })
        #expect(String(decoding: reencoded, as: UTF8.self).split(separator: "\n")
                == text.split(separator: "\n").filter { $0.contains(#""kind":"roadsSelection""#) })

        // An unknown kind next to them is still skipped and counted.
        let future = Data(#"{"kind":"futureKind","x":1}"#.utf8) + Data([0x0A])
        let withFuture = try NavSidecar.read(data + future + (try Live.encoded([.estimate(Live.estimate(9))])))
        #expect(withFuture.unrecognizedLines == 1 && withFuture.roadsSelections.count == 3 && withFuture.estimates.count == 4)

        // Outcome and state are open string sets: a later value decodes.
        let later = #"{"afterInputs":3,"candidates":[{"name":"x","state":"quarantined"}],"kind":"roadsSelection","#
            + #""outcome":"postponed","recordedAfterInputs":4,"request":{"radiusM":12.5},"t":1000}"#
        let header = try Live.encoded([lines[0]])
        let open = try NavSidecar.read(header + Data(later.utf8) + Data([0x0A]) + (try Live.encoded([.estimate(Live.estimate(9))])))
        #expect(open.roadsSelections.first?.outcome.rawValue == "postponed")
        #expect(open.roadsSelections.first?.candidates?.first?.state.rawValue == "quarantined")
        #expect(open.unrecognizedLines == 0)

        // duplicateRoadsLine is unchanged by selection lines around it.
        let roads = NavSidecarV2Tests.roads
        let twice = lines + [.roads(roads), .roadsSelection(selections[0]), .roads(roads)]
        #expect(throws: NavSidecar.ReadError.duplicateRoadsLine(number: twice.count)) { try NavSidecar.read(Live.encoded(twice)) }
    }

    // MARK: Invariant: other lines byte-identical

    /// The far pack only (8 km east of the drive): it never covers.
    static func farSet() throws -> ReplayRoadSet {
        ReplayRoadSet(try RoadNetwork(packs: [NavigationReplayLiveRoadsTests.packs().far]))
    }

    @Test("Estimate, pin and header lines are byte-identical with and without selection lines: a run whose pack never covers vs. no roads at all")
    func otherLinesByteIdentical() throws {
        let inputs = Attach.inputs()
        let none = NavigationReplay.liveLines(inputs: inputs, sessionID: Attach.sessionID, config: Attach.config())
        let far = NavigationReplay.liveLines(inputs: inputs, sessionID: Attach.sessionID, config: Attach.config(),
                                             roads: try Self.farSet(), attach: .live)
        let selections = far.compactMap { if case .roadsSelection(let s) = $0 { s } else { nil } }
        #expect(selections.count > 1 && selections.allSatisfy { $0.outcome == .noneCovering })
        #expect(!none.contains { if case .roadsSelection = $0 { true } else { false } })
        let rest = far.filter { if case .roadsSelection = $0 { false } else { true } }
        #expect(rest.count == none.count && rest.count == far.count - selections.count)
        let encoder = NavSidecar.makeEncoder()
        #expect(try Attach.stripped(rest).map { try NavSidecar.encode($0, with: encoder) }
                == (try Attach.stripped(none).map { try NavSidecar.encode($0, with: encoder) }))
        // The pinned no-roads digest (N3.3) still holds.
        #expect(try Attach.digest(rest) == Attach.noRoadsDigest)
        // Each selection line sits where its request was raised (synchronous).
        #expect(selections.allSatisfy { $0.recordedAfterInputs == $0.afterInputs })
    }

    @Test("replay_nav names: with file names for every pack the selector names and orders candidates by file name (as the app's library); the set's identity and network ignore names")
    func replaySelectorNames() throws {
        let (near, far) = try NavigationReplayLiveRoadsTests.packs()
        let network = try RoadNetwork(packs: [near, far])
        let named = ReplayRoadSet(network, names: [near.contentHash: "z-near.roadpack", far.contentHash: "a-far.roadpack"])
        #expect(named.selector.candidates.map(\.name) == ["a-far.roadpack", "z-near.roadpack"])
        #expect(named == ReplayRoadSet(network) && named.labelSuffix == ReplayRoadSet(network).labelSuffix)
        let partly = ReplayRoadSet(network, names: [near.contentHash: "near.roadpack"])
        #expect(partly.selector.candidates.map(\.pack.contentHash) == network.packs.map(\.contentHash),
                "canonical order unless every pack is named")
        #expect(partly.selector.candidates.map(\.name).contains("near.roadpack"))
    }

    // MARK: Compare

    @Test("Compare ignores roadsSelection lines for matching and the verdict: extra lines on either side still PASS (exact); both sides are printed, repeats folded")
    func compareIgnoresSelections() throws {
        let inputs = Attach.inputs()
        let config = Attach.config()
        let replay = NavigationReplay.liveLines(inputs: inputs, sessionID: Attach.sessionID, config: config)
        let ab = try Self.candidates(["a.roadpack", "b.roadpack"])
        let extra: [NavSidecar.Line] = [
            .roadsSelection(RoadPackSelection.attempt([], refusedAtScan: [Self.scanRefusal],
                                                      request: Self.request(0, 0, radiusM: 1414, afterInputs: 40, t: 2))
                .line(recordedAfterInputs: 44)),
            .roadsSelection(RoadPackSelection.attempt(ab, request: Self.request(0, -50_000, radiusM: 900, afterInputs: 50, t: 3))
                .line(recordedAfterInputs: 50)),
            .roadsSelection(RoadPackSelection.attempt(ab, request: Self.request(0, -50_000, radiusM: 800, afterInputs: 60, t: 4))
                .line(recordedAfterInputs: 60)),
            .roadsSelection(Selection(unfinished: Self.request(0, 0, radiusM: 50, afterInputs: 70, t: 5), recordedAfterInputs: 80)),
        ]
        var withSelections = replay
        withSelections.insert(contentsOf: extra, at: 5)
        let sidecar = try NavSidecar.read(Live.encoded(withSelections))
        #expect(sidecar.roadsSelections.count == 4)

        let comparison = SidecarComparison(sidecar: sidecar, replay: replay, replayConfig: config)
        #expect(comparison.exact && comparison.passes(SidecarComparison.Tolerance(metres: 0, degrees: 0)))
        #expect(comparison.sidecarSelections.count == 4 && comparison.replaySelections.isEmpty)
        let report = comparison.report(tolerance: .default)
        #expect(report.contains("Compare       PASS (exact"), "\(report)")
        #expect(report.contains("Selection     sidecar: 4 attempt(s), not compared"))
        #expect(!report.contains("Selection     replay"))
        #expect(report.contains("t 2.0 s after 40 inputs (recorded after 44), radius 1414 m: noPacks [0 verified, 0 covering; refused: bad.roadpack (truncated: 64 bytes missing)]"), "\(report)")
        #expect(report.contains("t 3.0 s after 50 inputs, radius 900 m: noneCovering [2 verified, 0 covering] (and 1 more like it to t 4.0 s)"), "\(report)")
        #expect(report.contains("t 5.0 s after 70 inputs (recorded after 80), radius 50 m: unfinished"), "\(report)")

        // The other way round: selection lines only in the replay.
        let plain = try NavSidecar.read(Live.encoded(replay))
        let reverse = SidecarComparison(sidecar: plain, replay: withSelections, replayConfig: config)
        #expect(reverse.exact && reverse.replaySelections.count == 4 && reverse.sidecarSelections.isEmpty)
        #expect(reverse.report(tolerance: .default).contains("Selection     replay: 4 attempt(s), not compared"))
        // Same estimates as without any selection line.
        let bare = SidecarComparison(sidecar: plain, replay: replay, replayConfig: config)
        #expect(bare.estimates == comparison.estimates && bare.pins == comparison.pins)
        #expect(!bare.report(tolerance: .default).contains("Selection"))
    }
}
