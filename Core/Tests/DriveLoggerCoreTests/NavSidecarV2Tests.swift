import Foundation
import Testing

@testable import DriveLoggerCore

/// N3.3 item 2: sidecar v2 — the `roads` line, `Estimate.onRoadShare`, and
/// readers of v1 and v2. Synthetic values near (0, 0) only.
@Suite("Navigation sidecar v2 (N3.3)")
struct NavSidecarV2Tests {
    typealias Live = NavigationLiveTests
    typealias Attach = NavigationRoadAttachTests

    static let roads = NavSidecar.Roads(
        t: MonotonicTimestamp(nanoseconds: 12_345_678_901), afterInputs: 4_321,
        roads: [NavSidecar.Roads.Pack(contentHash: "00000000000000a1", formatVersion: 1, osmTimestamp: 1_700_000_000,
                                      gridID: "0123456789abcdef"),
                NavSidecar.Roads.Pack(contentHash: "00000000000000b2", formatVersion: 1, osmTimestamp: 0,
                                      gridID: "0123456789abcdef")],
        roadSetHash: "fedcba9876543210")

    static func lines(roads: NavSidecar.Roads?) -> [NavSidecar.Line] {
        var all = Live.sampleLines()
        var onRoad = Live.estimate(5)
        onRoad.onRoadShare = 0.734_000_000_000_1
        all.append(.estimate(onRoad))
        if let roads { all.insert(.roads(roads), at: 3) }
        return all
    }

    @Test("v2 round trip through a file: with a roads line (t present and absent) and without one; onRoadShare present and absent")
    func roundTrip() throws {
        let scratch = try ScratchDirectory()
        defer { scratch.remove() }
        var atStart = Self.roads
        atStart.t = nil
        atStart.afterInputs = 0
        for roads in [Self.roads, atStart, nil] {
            let lines = Self.lines(roads: roads)
            let writer = try NavSidecarWriter(url: scratch.file("drive.nav.jsonl"))
            for line in lines { writer.append(line) }
            writer.close()
            let data = try Data(contentsOf: writer.url)
            #expect(data == (try Live.encoded(lines)))
            let contents = try NavSidecar.read(data)
            #expect(contents.header.sidecarVersion == 3 && NavSidecar.version == 3)
            #expect(contents.roads == (roads.map { [$0] } ?? []))
            #expect(contents.estimates.count == 4 && contents.unrecognizedLines == 0)
            #expect(contents.estimates[0].onRoadShare == nil)
            #expect(contents.estimates[3].onRoadShare?.bitPattern == 0.734_000_000_000_1.bitPattern)
            let text = String(decoding: data, as: UTF8.self).split(separator: "\n")
            #expect(text.filter { $0.contains("onRoadShare") }.count == 1, "omitted when nil")
            if let roads {
                let line = try #require(text.first { $0.contains("\"kind\":\"roads\"") })
                #expect(line.contains("\"roadSetHash\":\"\(roads.roadSetHash)\""))
                #expect(line.contains("\"contentHash\":\"00000000000000a1\""))
                #expect(line.contains("\"afterInputs\":\(roads.afterInputs)"))
                #expect(line.contains("\"t\":") == (roads.t != nil))
            }
        }
    }

    @Test("A no-roads estimate line is byte-identical to a v1 line; a v1 file still reads")
    func v1Compatibility() throws {
        // Frozen v1 lines, in the shape v1 writers produced.
        let v1 = """
            {"appBuild":"1","configHash":"0123456789abcdef","configJSON":"{}","kind":"header",\
            "seed":7,"sessionID":"3F2504E0-4F89-41D3-9A0C-0305E82C3301","sidecarVersion":1}
            {"converged":true,"droppedInputs":0,"headingDeg":90,"headingStdDeg":2,"kind":"estimate",\
            "latitude":0.001,"longitude":0.002,"maxStepMs":4.5,"msPerStep":2.8,"orientationDeg":10,\
            "semiMajorM":12,"semiMinorM":6,"speedScale":1,"t":1000000000}

            """
        let contents = try NavSidecar.read(Data(v1.utf8))
        #expect(contents.header.sidecarVersion == 1 && contents.roads.isEmpty)
        let estimate = try #require(contents.estimates.first)
        #expect(estimate.onRoadShare == nil)
        let reencoded = try NavSidecar.encode(.estimate(estimate), with: NavSidecar.makeEncoder())
        #expect(String(decoding: reencoded, as: UTF8.self) == String(v1.split(separator: "\n")[1]) + "\n")
    }

    /// `lines` with the header's version set to `version`.
    static func versioned(_ lines: [NavSidecar.Line], _ version: Int) -> [NavSidecar.Line] {
        var lines = lines
        if case .header(var header) = lines[0] {
            header.sidecarVersion = version
            lines[0] = .header(header)
        }
        return lines
    }

    @Test("A reader that knows only v1 refuses v2, one that knows v2 refuses v3; this reader refuses v4; a second roads line is refused in v2")
    func versionsRefused() throws {
        let v2 = try Live.encoded(Self.versioned(Self.lines(roads: Self.roads), 2))
        #expect(throws: NavSidecar.ReadError.unsupportedVersion(2)) { try NavSidecar.read(v2, maxVersion: 1) }
        #expect(try NavSidecar.read(v2, maxVersion: 2).roads == [Self.roads])
        #expect(try NavSidecar.read(v2).roads == [Self.roads])
        let v3 = try Live.encoded(Self.lines(roads: Self.roads))
        #expect(throws: NavSidecar.ReadError.unsupportedVersion(3)) { try NavSidecar.read(v3, maxVersion: 2) }
        let v4 = Self.versioned(Self.lines(roads: nil), 4)
        #expect(throws: NavSidecar.ReadError.unsupportedVersion(4)) { try NavSidecar.read(Live.encoded(v4)) }
        let twice = Self.versioned(Self.lines(roads: Self.roads) + [.roads(Self.roads), .estimate(Live.estimate(9))], 2)
        #expect(throws: NavSidecar.ReadError.duplicateRoadsLine(number: 9)) { try NavSidecar.read(Live.encoded(twice)) }
    }

    @Test("The live run writes v2: roads at init follow the header; a mid-run attach emits the roads line at its boundary; onRoadShare appears")
    func liveRunWritesRoadsLine() throws {
        let inputs = Attach.inputs()
        let net = try Attach.network()
        let fromStart = LiveNavigationRun(sessionID: Attach.sessionID, config: Attach.config(), appBuild: "t", roads: net)
        #expect(fromStart.openingLines.count == 2)
        guard case .roads(let atInit) = fromStart.openingLines[1] else { Issue.record("no roads line"); return }
        #expect(atInit.afterInputs == 0 && atInit.t == nil)
        #expect(atInit.roadSetHash == net.roadSetHashHex)
        #expect(atInit.roads == net.packs.map(NavSidecar.Roads.Pack.init))
        #expect(atInit.roads[0].contentHash == NavigationSeed.hex(net.packs[0].contentHash))
        #expect(LiveNavigationRun(sessionID: Attach.sessionID, config: Attach.config(), appBuild: "t").openingLines.count == 1)

        let k = 1_500
        let attached = Attach.live(inputs, network: net, attachAfter: k)
        let line = attached.lines[attached.beforeAttach]
        guard case .roads(let mid) = line else { Issue.record("no roads line at the attach"); return }
        #expect(mid.afterInputs == k && mid.t == inputs[k - 1].arrival)
        #expect(attached.lines.filter { if case .roads = $0 { true } else { false } }.count == 1)
        let shares = attached.lines.compactMap { if case .estimate(let e) = $0 { e.onRoadShare } else { nil } }
        #expect(!shares.isEmpty && shares.allSatisfy { $0 >= 0 && $0 <= 1 })
        let before = attached.lines[..<attached.beforeAttach].compactMap { if case .estimate(let e) = $0 { e } else { nil } }
        #expect(before.allSatisfy { $0.onRoadShare == nil })
        // The written file reads back with its roads line.
        let data = try Live.encoded(fromStart.openingLines + attached.lines.filter { if case .roads = $0 { false } else { true } })
        #expect(try NavSidecar.read(data).roads == [atInit])
    }

    enum FixtureError: Error { case noHeader }

    /// Compares `sampleLines` with itself, its estimate at t = 1 s given
    /// onRoadShare `live` on the sidecar side and `replay` on the replay
    /// side; every other field identical.
    static func compareOnRoadShare(live: Double?, replay: Double?) throws -> SidecarComparison {
        func with(_ share: Double?) -> [NavSidecar.Line] {
            var lines = Live.sampleLines()
            if case .estimate(var e) = lines[1] {
                e.onRoadShare = share
                lines[1] = .estimate(e)
            }
            return lines
        }
        let liveLines = with(live)
        guard case .header(let header) = liveLines[0] else { throw FixtureError.noHeader }
        let config = try JSONDecoder().decode(NavigationConfig.self, from: Data(header.configJSON.utf8))
        return SidecarComparison(sidecar: try NavSidecar.read(Live.encoded(liveLines)), replay: with(replay),
                                 replayConfig: config)
    }

    @Test("Compare: an estimate differing only in onRoadShare (one ulp, or nil vs a value) is unequal and not exact; the difference is reported (the gap, or 1 for nil vs a value) and not gated by the tolerance")
    func compareOnRoadShareOnly() throws {
        // Control: the same share on both sides is exact.
        let same = try Self.compareOnRoadShare(live: 0.5, replay: 0.5)
        #expect(same.exact && same.estimates.unequal == 0 && same.estimates.onRoadShare == 0)

        let oneUlp = (0.5).nextUp
        let gap = oneUlp - 0.5
        #expect(gap > 0 && gap < 1e-15)
        let cases: [(live: Double?, replay: Double?, difference: Double)] = [
            (0.5, oneUlp, gap),
            (oneUlp, 0.5, gap),
            (nil, 0.5, 1),  // present on one side only: 1, whatever the value
            (0.5, nil, 1),
        ]
        for c in cases {
            let label = "live \(String(describing: c.live)), replay \(String(describing: c.replay))"
            let comparison = try Self.compareOnRoadShare(live: c.live, replay: c.replay)
            let d = comparison.estimates
            #expect(d.matched == 3 && d.unequal == 1 && d.firstDifferenceT == SyntheticDrive.ms(1), "\(label)")
            #expect(d.onRoadShare == c.difference, "\(label)")
            // Every other compared field identical.
            #expect(d.positionM == 0 && d.headingDeg == 0 && d.headingStdDeg == 0 && d.ellipseAxesM == 0
                    && d.ellipseOrientationDeg == 0 && d.speedScale == 0 && d.convergedMismatches == 0, "\(label)")
            #expect(comparison.pins.unequal == 0 && comparison.sidecarOnly == 0 && comparison.replayOnly == 0
                    && comparison.pinsUnmatched == 0, "\(label)")
            // Part of the exact check.
            #expect(!comparison.linesIdentical && !comparison.exact, "\(label)")
            // Not gated by the tolerance: even a zero tolerance passes, so the
            // verdict is "PASS within tolerance", never exact and never FAIL.
            let zero = SidecarComparison.Tolerance(metres: 0, degrees: 0)
            #expect(comparison.passes(.default) && comparison.passes(zero), "\(label)")
            let report = comparison.report(tolerance: zero)
            #expect(report.contains("Compare       PASS within tolerance") && !report.contains("PASS (exact")
                    && !report.contains("FAIL"), "\(label)")
            #expect(report.contains(String(format: "on-road share %.3g,", c.difference)), "\(label)")
        }
    }
}
