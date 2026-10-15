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
            #expect(contents.header.sidecarVersion == 2 && NavSidecar.version == 2)
            #expect(contents.roads == roads)
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
        #expect(contents.header.sidecarVersion == 1 && contents.roads == nil)
        let estimate = try #require(contents.estimates.first)
        #expect(estimate.onRoadShare == nil)
        let reencoded = try NavSidecar.encode(.estimate(estimate), with: NavSidecar.makeEncoder())
        #expect(String(decoding: reencoded, as: UTF8.self) == String(v1.split(separator: "\n")[1]) + "\n")
    }

    @Test("A reader that knows only v1 refuses v2; this reader refuses v3; a second roads line is refused")
    func versionsRefused() throws {
        let data = try Live.encoded(Self.lines(roads: Self.roads))
        #expect(throws: NavSidecar.ReadError.unsupportedVersion(2)) { try NavSidecar.read(data, maxVersion: 1) }
        #expect(try NavSidecar.read(data, maxVersion: 2).roads == Self.roads)
        var lines = Self.lines(roads: nil)
        guard case .header(var header) = lines[0] else { return }
        header.sidecarVersion = 3
        lines[0] = .header(header)
        #expect(throws: NavSidecar.ReadError.unsupportedVersion(3)) { try NavSidecar.read(Live.encoded(lines)) }
        let twice = Self.lines(roads: Self.roads) + [.roads(Self.roads), .estimate(Live.estimate(9))]
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
        #expect(try NavSidecar.read(data).roads == atInit)
    }
}
