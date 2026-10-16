import Foundation
import Testing

@testable import DriveLoggerCore
@testable import RoadPackBuild

/// `roadsSelection` repeats (within v2): an attempt is written only when it
/// is not a repeat of the last line written (`RoadsSelection.isRepeat(of:)`:
/// outcome, packs, reason, candidates incl. `covering`); repeats are counted
/// and written as one line (the last repeat's, with `repeats` and `firstT`)
/// on the next change, at an attach (before its own line and `roads`), and
/// at the end (before `unfinished`). `NavSidecar.RoadsSelectionLog`, owned
/// by `LiveNavigationRun`. Synthetic packs and drive near (0, 0) only.
@Suite("Navigation sidecar roadsSelection repeats")
struct NavSidecarRoadsSelectionRepeatsTests {
    typealias Base = NavSidecarRoadsSelectionTests
    typealias Attach = NavigationRoadAttachTests
    typealias Live = NavigationLiveTests
    typealias Selection = NavSidecar.RoadsSelection
    typealias Candidate = Selection.Candidate

    static let far = [Candidate(name: "far.roadpack", state: .verified, covering: false)]

    /// A synthetic line: request at `t` s after `inputs` inputs (recorded
    /// there), radius `radiusM`.
    static func line(_ t: Double, inputs: Int, radiusM: Double = 1414, outcome: Selection.Outcome = .noneCovering,
                     candidates: [Candidate]? = far, packs: [String]? = nil, reason: String? = nil) -> Selection {
        Selection(t: MonotonicTimestamp(seconds: t), afterInputs: inputs, recordedAfterInputs: inputs,
                  request: Selection.Request(radiusM: radiusM), candidates: candidates, outcome: outcome,
                  packs: packs, reason: reason)
    }

    static func keys(_ selection: Selection) throws -> Set<String> {
        Set(try Base.json(selection).object.keys)
    }

    // MARK: RoadsSelectionLog

    @Test("Identical attempts: the first is written at once, the rest give nothing until flush, which writes ONE line: the last repeat's fields, repeats = their count, firstT = the first repeat's t")
    func identicalAttempts() throws {
        var log = NavSidecar.RoadsSelectionLog()
        let attempts = (0..<5).map { Self.line(Double(10 + $0), inputs: 100 + 10 * $0, radiusM: 1000 + Double($0)) }
        #expect(log.record(attempts[0]) == [attempts[0]], "the first attempt is written at once")
        for attempt in attempts[1...] { #expect(log.record(attempt).isEmpty) }
        #expect(log.attempts == 5 && log.lines == 1)
        let pending = log.flush()
        let flushed = try #require(pending)
        var expected = attempts[4]
        expected.repeats = 4
        expected.firstT = attempts[1].t
        #expect(flushed == expected)
        #expect(flushed.t == attempts[4].t && flushed.afterInputs == 140 && flushed.recordedAfterInputs == 140)
        #expect(flushed.request.radiusM == 1004, "the last repeat's radius; the others are dropped")
        #expect(flushed.attempts == 4 && log.attempts == 5 && log.lines == 2)
        let left = log.flush()
        #expect(left == nil, "nothing left to flush")
        // On disk: the two optional keys, nothing else new.
        let (text, object) = try Base.json(flushed)
        #expect(object["repeats"] as? Int == 4 && object["firstT"] as? Int64 == attempts[1].t.nanoseconds)
        #expect(try Self.keys(flushed) == (try Self.keys(attempts[4])).union(["firstT", "repeats"]))
        #expect(text.contains(#""firstT":11000000000,"#) && text.contains(#""repeats":4,"#), "\(text)")
    }

    @Test("A single attempt has no repeat keys; nothing to flush after it")
    func singleAttempt() throws {
        var log = NavSidecar.RoadsSelectionLog()
        let only = Self.line(3, inputs: 30)
        #expect(log.record(only) == [only])
        #expect(log.flush() == nil)
        #expect(only.repeats == nil && only.firstT == nil && only.attempts == 1)
        let keys = try Self.keys(only)
        #expect(!keys.contains("repeats") && !keys.contains("firstT"))
        #expect(log.attempts == 1 && log.lines == 1)
    }

    @Test("Exactly two identical attempts: two plain lines, the second written at the flush, neither with repeat keys")
    func twoIdenticalAttempts() throws {
        var log = NavSidecar.RoadsSelectionLog()
        let a = Self.line(3, inputs: 30), b = Self.line(4, inputs: 40, radiusM: 900)
        #expect(log.record(a) == [a])
        #expect(log.record(b).isEmpty)
        let pending = log.flush()
        let flushed = try #require(pending)
        #expect(flushed == b && flushed.repeats == nil && flushed.firstT == nil)
        #expect(!(try Self.keys(flushed)).contains("repeats"))
        #expect(log.attempts == 2 && log.lines == 2)
    }

    @Test("A change of outcome flushes the repeats before the changed attempt; a change straight after a written line flushes nothing")
    func outcomeChangeFlushes() {
        var log = NavSidecar.RoadsSelectionLog()
        let none = (0..<3).map { Self.line(Double($0), inputs: 10 * $0) }
        let noPacks = Self.line(5, inputs: 50, outcome: .noPacks, candidates: [])
        #expect(log.record(none[0]) == [none[0]])
        #expect(log.record(none[1]).isEmpty && log.record(none[2]).isEmpty)
        var folded = none[2]
        folded.repeats = 2
        folded.firstT = none[1].t
        #expect(log.record(noPacks) == [folded, noPacks])
        // Back to noneCovering at once: noPacks had no repeats pending.
        let again = Self.line(6, inputs: 60)
        #expect(log.record(again) == [again])
        #expect(log.lastWritten == again && log.pending == nil)
        #expect(log.attempts == 5 && log.lines == 4)
    }

    @Test("A change of candidates flushes: a pack becomes covering but is refused; a new file appears; a file is refused at the scan")
    func candidatesChangeFlushes() {
        let notCovering = Self.far
        let covering = [Candidate(name: "far.roadpack", state: .verified, covering: true)]
        let twoFiles = notCovering + [Candidate(name: "new.roadpack", state: .verified, covering: false)]
        let scanRefused = notCovering + [Candidate(name: "bad.roadpack", state: .refused, reason: "truncated")]
        let changes: [(String, Selection)] = [
            ("covering, refused", Self.line(9, inputs: 90, outcome: .refused, candidates: covering,
                                             packs: ["far.roadpack"], reason: "different grids")),
            ("a new file", Self.line(9, inputs: 90, candidates: twoFiles)),
            ("refused at scan", Self.line(9, inputs: 90, candidates: scanRefused)),
        ]
        for (label, changed) in changes {
            var log = NavSidecar.RoadsSelectionLog()
            let same = (0..<3).map { Self.line(Double($0), inputs: 10 * $0, candidates: notCovering) }
            _ = log.record(same[0])
            _ = log.record(same[1])
            _ = log.record(same[2])
            let out = log.record(changed)
            #expect(out.count == 2 && out[0].repeats == 2 && out[0].t == same[2].t && out[1] == changed, "\(label)")
            #expect(!changed.isRepeat(of: same[0]), "\(label)")
        }
    }

    @Test("R33.1-2: two refusals of the same packs and reason with different candidates are not the same attempt: written as two lines, and not folded by --compare")
    func refusalsWithDifferentCandidatesNotFolded() {
        let a = Self.line(1, inputs: 10, outcome: .refused,
                          candidates: [Candidate(name: "a.roadpack", state: .verified, covering: true),
                                       Candidate(name: "b.roadpack", state: .verified, covering: true)],
                          packs: ["a.roadpack", "b.roadpack"], reason: "different grids")
        let b = Self.line(2, inputs: 20, outcome: .refused,
                          candidates: [Candidate(name: "a.roadpack", state: .verified, covering: true),
                                       Candidate(name: "b.roadpack", state: .verified, covering: true),
                                       Candidate(name: "c.roadpack", state: .verified, covering: false)],
                          packs: ["a.roadpack", "b.roadpack"], reason: "different grids")
        #expect(!b.isRepeat(of: a) && !a.isRepeat(of: b))
        var log = NavSidecar.RoadsSelectionLog()
        #expect(log.record(a) == [a] && log.record(b) == [b])
        let rows = SidecarComparison.selectionRows([a, b])
        #expect(rows.count == 2 && rows.allSatisfy { !$0.contains("more like it") }, "\(rows)")
        // The same refusal with the same candidates is folded.
        var c = b
        c.t = MonotonicTimestamp(seconds: 3)
        let folded = SidecarComparison.selectionRows([a, b, c])
        #expect(folded.count == 2 && folded[1].hasSuffix("(and 1 more like it to t 3.0 s)"), "\(folded)")
    }

    @Test("alwaysWrite (an attach) writes a repeat too, after the pending repeats")
    func alwaysWrite() {
        var log = NavSidecar.RoadsSelectionLog()
        let a = (0..<4).map { Self.line(Double($0), inputs: 10 * $0) }
        _ = log.record(a[0])
        _ = log.record(a[1])
        _ = log.record(a[2])
        var folded = a[2]
        folded.repeats = 2
        folded.firstT = a[1].t
        #expect(log.record(a[3], alwaysWrite: true) == [folded, a[3]])
        #expect(log.pending == nil && log.lastWritten == a[3])
    }

    // MARK: LiveNavigationRun

    /// A run that has seen 50 inputs, and a request at `t` s.
    static func run() -> LiveNavigationRun {
        var run = LiveNavigationRun(sessionID: Attach.sessionID, config: Attach.config(), appBuild: "t")
        for input in Attach.inputs()[..<50] { run.ingest(input) { _ in } }
        return run
    }

    static func farAttempt(_ t: Double) throws -> RoadSelectionAttempt {
        RoadPackSelection.attempt(try Base.candidates(["b.roadpack"]),
                                  request: Base.request(0, 0, radiusM: 100, afterInputs: Int(t), t: t))
    }

    @Test("finishSelection: an attach flushes the repeats first; the order is the repeats' line, the selected line, then roads")
    func attachFlushesInOrder() throws {
        var run = Self.run()
        var lines: [NavSidecar.Line] = []
        for t in [10.0, 11, 12, 13] { run.finishSelection(try Self.farAttempt(t)) { lines.append($0) } }
        #expect(lines.count == 1, "the first attempt only; the next three are repeats")
        let way = RoadFixture.way(1, ["highway": "residential"],
                                  [RoadFixture.Node(id: 10, east: 0, north: -3000), RoadFixture.Node(id: 11, east: 0, north: 3000)])
        let good = try RoadPackSelection.Candidate(name: "road.roadpack", pack: RoadFixture.build([way]))
        let selected = RoadPackSelection.attempt([good], request: Base.request(0, 0, radiusM: 100, afterInputs: 14, t: 14))
        let record = run.finishSelection(selected) { lines.append($0) }
        #expect(lines.map(\.kind) == ["roadsSelection", "roadsSelection", "roadsSelection", "roads"])
        guard case .roadsSelection(let first) = lines[0], case .roadsSelection(let repeats) = lines[1],
              case .roadsSelection(let attached) = lines[2] else { return }
        #expect(first.repeats == nil && first.t == MonotonicTimestamp(seconds: 10))
        #expect(repeats.repeats == 3 && repeats.firstT == MonotonicTimestamp(seconds: 11)
                && repeats.t == MonotonicTimestamp(seconds: 13) && repeats.outcome == .noneCovering)
        #expect(attached == record && attached.outcome == .selected && attached.repeats == nil && run.roads != nil)
        #expect(run.selectionLog.attempts == 5 && run.selectionLog.lines == 3)
        // Nothing is left for the end.
        #expect(run.closingLines().isEmpty)
    }

    @Test("closingLines at stop: the repeats' line, then unfinished; without a selection in flight, the repeats' line only; nothing pending, nothing")
    func stopFlushesBeforeUnfinished() throws {
        var run = Self.run()
        var lines: [NavSidecar.Line] = []
        for t in [10.0, 11, 12] { run.finishSelection(try Self.farAttempt(t)) { lines.append($0) } }
        let inFlight = Base.request(0, 0, radiusM: 70, afterInputs: 49, t: 20)
        let closing = run.closingLines(inFlight: inFlight)
        guard closing.count == 2, case .roadsSelection(let repeats) = closing[0],
              case .roadsSelection(let unfinished) = closing[1] else {
            Issue.record("expected the repeats line, then unfinished: \(closing.map(\.kind))")
            return
        }
        #expect(repeats.repeats == 2 && repeats.firstT == MonotonicTimestamp(seconds: 11) && repeats.t == MonotonicTimestamp(seconds: 12))
        #expect(unfinished == Selection(unfinished: inFlight, recordedAfterInputs: 50) && unfinished.repeats == nil)
        #expect(run.selectionLog.attempts == 4 && run.selectionLog.lines == 3)

        var plain = Self.run()
        for t in [10.0, 11, 12] { plain.finishSelection(try Self.farAttempt(t)) { _ in } }
        let flushed = plain.closingLines()
        #expect(flushed.count == 1 && flushed.first.map { if case .roadsSelection(let s) = $0 { s.repeats == 2 } else { false } } == true)

        var one = Self.run()
        one.finishSelection(try Self.farAttempt(10)) { _ in }
        #expect(one.closingLines().isEmpty)
        #expect(one.closingLines(inFlight: inFlight).map(\.kind) == ["roadsSelection"])
    }

    @Test("runLive (--write-sidecar, --compare's reference) ends with the repeats' line; its attempt count is the selector's requests")
    func runLiveFlushesAtEnd() throws {
        var lines: [NavSidecar.Line] = []
        let set = try Base.farSet()
        let run = NavigationReplay.runLive(inputs: Attach.inputs(), sessionID: Attach.sessionID, config: Attach.config(),
                                           roads: set, attach: .live) { lines.append($0) }
        let selections = lines.compactMap { if case .roadsSelection(let s) = $0 { s } else { nil } }
        var selector = set.selector
        var check = LiveNavigationRun(sessionID: Attach.sessionID, config: Attach.config(), appBuild: "replay")
        for input in Attach.inputs() { check.ingest(input, selector: &selector) { _ in } }
        #expect(run.selectionLog.attempts == selector.requests && selector.requests > 2)
        #expect(selections.count == run.selectionLog.lines && selections.count == 2)
        #expect(selections.reduce(0) { $0 + $1.attempts } == selector.requests)
        #expect(lines.last == .roadsSelection(selections[1]) && selections[1].repeats == selector.requests - 1)
    }

    // MARK: Reading

    @Test("Decoding: a line with repeats and firstT decodes; one without still does (nil); an unknown key is ignored, as by a v2 reader that predates repeats")
    func decoding() throws {
        let header = try Live.encoded([Live.sampleLines()[0]])
        let tail = try Live.encoded([.estimate(Live.estimate(9))])
        let with = #"{"afterInputs":40,"candidates":[{"covering":false,"name":"far.roadpack","state":"verified"}],"#
            + #""firstT":2000000000,"kind":"roadsSelection","outcome":"noneCovering","recordedAfterInputs":40,"#
            + #""repeats":7,"request":{"radiusM":800},"t":9000000000}"#
        let without = #"{"afterInputs":3,"candidates":[],"kind":"roadsSelection","outcome":"noPacks","#
            + #""recordedAfterInputs":4,"request":{"radiusM":12.5},"t":1000}"#
        let unknown = #"{"afterInputs":3,"candidates":[],"futureKey":{"x":[1,2]},"kind":"roadsSelection","#
            + #""outcome":"noPacks","recordedAfterInputs":4,"request":{"radiusM":12.5},"t":1000}"#
        let body = [with, without, unknown].map { Data($0.utf8) + Data([0x0A]) }.reduce(Data(), +)
        let contents = try NavSidecar.read(header + body + tail)
        #expect(contents.unrecognizedLines == 0 && contents.roadsSelections.count == 3 && !contents.truncatedLastLine)
        let (a, b, c) = (contents.roadsSelections[0], contents.roadsSelections[1], contents.roadsSelections[2])
        #expect(a.repeats == 7 && a.firstT == MonotonicTimestamp(seconds: 2) && a.attempts == 7)
        #expect(b.repeats == nil && b.firstT == nil && b.attempts == 1)
        #expect(c == b, "the unknown key is ignored")
        // Re-encoding gives the same bytes for the known keys.
        let text = String(decoding: try NavSidecar.encode(.roadsSelection(a), with: NavSidecar.makeEncoder()), as: UTF8.self)
        #expect(text == with + "\n")
    }

    // MARK: Compare

    @Test("Compare: a repeats line shows its count and t range; folding gives the same row for an old one-line-per-attempt sidecar and a new one; the Selection header counts attempts and lines")
    func compareRows() throws {
        let old = (0..<5).map { Self.line(Double(2 + $0), inputs: 20 + $0, radiusM: 900 - Double($0)) }
        var log = NavSidecar.RoadsSelectionLog()
        var new: [Selection] = []
        for attempt in old { new += log.record(attempt) }
        new += log.flush().map { [$0] } ?? []
        #expect(new.count == 2)
        #expect(new[1].summary == "t 6.0 s after 24 inputs, radius 896 m: noneCovering [1 verified, 0 covering] (×4, t 3.0–6.0 s)")
        let oldRows = SidecarComparison.selectionRows(old)
        let newRows = SidecarComparison.selectionRows(new)
        #expect(oldRows == newRows && newRows.count == 1, "\(oldRows) vs \(newRows)")
        #expect(newRows[0].hasSuffix("radius 900 m: noneCovering [1 verified, 0 covering] (and 4 more like it to t 6.0 s)"),
                "\(newRows)")
        // A repeats line on its own (not after its first line) shows ×N.
        #expect(SidecarComparison.selectionRows([new[1]])[0].hasSuffix("(×4, t 3.0–6.0 s)"))

        let inputs = Attach.inputs()
        let config = Attach.config()
        let replay = NavigationReplay.liveLines(inputs: inputs, sessionID: Attach.sessionID, config: config)
        var sidecarLines = replay
        sidecarLines.insert(contentsOf: new.map { .roadsSelection($0) }, at: 5)
        let comparison = SidecarComparison(sidecar: try NavSidecar.read(Live.encoded(sidecarLines)), replay: replay,
                                           replayConfig: config)
        #expect(comparison.exact)
        let report = comparison.report(tolerance: .default)
        #expect(report.contains("Selection     sidecar: 5 attempt(s) in 2 line(s), not compared"), "\(report)")
        #expect(report.contains("(and 4 more like it to t 6.0 s)"), "\(report)")
    }
}
