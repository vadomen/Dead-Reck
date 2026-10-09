import Foundation
import Testing

@testable import DriveLoggerCore

/// N4 B: the live app's per-recording navigation in Core — seed, sidecar
/// format, the shared estimate/sidecar loop (`LiveNavigationRun`), the
/// `--as-live --compare` path, and the implausible-time-jump guard (B0-1).
/// Synthetic drives around (0, 0) only.
@Suite("Navigation N4 B")
struct NavigationLiveTests {
    typealias S = SyntheticDrive

    // MARK: Seed

    @Test("The seed is 64-bit FNV-1a of the sessionID's canonical string: known vectors and a pinned value")
    func seedIsStable() throws {
        #expect(NavigationSeed.fnv1a64([UInt8]()) == 0xCBF2_9CE4_8422_2325)
        #expect(NavigationSeed.fnv1a64(Array("a".utf8)) == 0xAF63_DC4C_8601_EC8C)
        #expect(NavigationSeed.fnv1a64(Array("foobar".utf8)) == 0x8594_4171_F739_67E8)
        let id = try #require(UUID(uuidString: "3F2504E0-4F89-41D3-9A0C-0305E82C3301"))
        // Pinned: a change here changes every live run's seed, and every
        // sidecar written before it no longer replays with --seed header.
        #expect(NavigationSeed.derive(sessionID: id) == 0x6381_06A3_7B08_C1B1)  // checked with an independent FNV-1a
        #expect(NavigationSeed.derive(header: WriterFixtures.header) == NavigationSeed.derive(sessionID: id))
        // Lower-case input parses to the same UUID, so the same seed.
        let lower = try #require(UUID(uuidString: "3f2504e0-4f89-41d3-9a0c-0305e82c3301"))
        #expect(NavigationSeed.derive(sessionID: lower) == NavigationSeed.derive(sessionID: id))
        #expect(NavigationSeed.hex(0xAB) == "00000000000000ab")
    }

    @Test("The seed survives the header's trip through the file: derived live and from the read header alike")
    func seedSurvivesTheFile() throws {
        let codec = LogCodec()
        let decoded = try codec.header(from: codec.line(for: WriterFixtures.header))
        #expect(NavigationSeed.derive(header: decoded) == NavigationSeed.derive(header: WriterFixtures.header))
        #expect(NavigationConfig(seed: 42) == { var c = NavigationConfig(); c.seed = 42; return c }())
    }

    // MARK: Config hash and validation

    @Test("The config hash is stable and sensitive: same config same hash, one field changed a different hash")
    func configHash() throws {
        let a = NavigationConfig(seed: 7)
        #expect(a.hashHex == NavigationConfig(seed: 7).hashHex)
        #expect(a.hashHex.count == 16)
        var b = a
        b.headingNoiseDegPerSqrtS += 1e-9
        #expect(a.hashHex != b.hashHex)
        #expect(a.hashHex != NavigationConfig(seed: 8).hashHex)
        // Sorted keys, so the text does not depend on declaration order.
        let object = try #require(try JSONSerialization.jsonObject(with: a.canonicalJSON()) as? [String: Any])
        let text = String(decoding: a.canonicalJSON(), as: UTF8.self)
        let positions = object.keys.sorted().map { text.range(of: "\"\($0)\":")!.lowerBound }
        #expect(positions == positions.sorted())
    }

    @Test("B0-1: validation clamps an absurd extrapolation horizon; defaults are unchanged")
    func validationClampsHorizon() throws {
        #expect(NavigationConfig().validated() == NavigationConfig())
        var config = S.config(particles: 100)
        config.extrapolationHorizonS = 1e12
        #expect(NavigationEngine(config: config).config.extrapolationHorizonS == NavigationConfig.maxExtrapolationHorizonS)
        config.extrapolationHorizonS = .nan
        #expect(NavigationEngine(config: config).config.extrapolationHorizonS == NavigationConfig().extrapolationHorizonS)
        config.extrapolationHorizonS = -5
        #expect(NavigationEngine(config: config).config.extrapolationHorizonS == 0)
        config.extrapolationHorizonS = 1e12
        config.maxForwardJumpS = .infinity
        #expect(NavigationEngine(config: config).config.maxForwardJumpS == NavigationConfig().maxForwardJumpS)

        // The overflow the clamp prevents: a huge horizon with a huge t.
        config.maxForwardJumpS = 1e12  // let the huge t through
        var engine = NavigationEngine(config: config)
        for input in S.inputs(NavigationCausalityTests.events()) where input.arrival < S.ms(12) { engine.ingest(input) }
        let far = try #require(engine.estimate(at: MonotonicTimestamp(nanoseconds: Int64.max - 1)))
        #expect(far.latitude.isFinite && far.ellipse.semiMajorM.isFinite)
    }

    // MARK: B0-1 forward jumps

    static func motion(_ t: Double) -> NavigationInput { NavigationB0Tests.motion(t) }

    @Test("B0-1: one corrupt huge t is rejected and counted, and the engine goes on exactly as without it")
    func corruptForwardJumpIsRejected() throws {
        let inputs = S.inputs(NavigationCausalityTests.events())
        let config = S.config(particles: 300, seed: 3)
        var plain = NavigationEngine(config: config)
        var guarded = NavigationEngine(config: config)
        var corrupted = false
        for input in inputs {
            plain.ingest(input)
            guarded.ingest(input)
            if !corrupted && input.arrival > S.ms(20) {
                // About 32 years ahead: before B0-1 the engine clock moved
                // there and every later input was in the past.
                let corrupt = Self.motion(1e9)
                #expect(!guarded.accepts(corrupt))
                guarded.ingest(corrupt)
                corrupted = true
            }
        }
        #expect(guarded.counters.inputsRejectedTimeJump == 1)
        #expect(plain.counters.inputsRejectedTimeJump == 0)
        var expected = plain.counters
        expected.inputsRejectedTimeJump = 1
        #expect(guarded.counters == expected)
        let t = S.ms(54)
        #expect(guarded.estimate(at: t) == plain.estimate(at: t))
        #expect(guarded.counters.steps > 400)
    }

    @Test("B0-1: a real resume after more than the limit costs one input, then the engine steps on")
    func confirmedResumeIsAccepted() throws {
        var config = S.config(particles: 200)
        config.maxForwardJumpS = 60
        var engine = NavigationEngine(config: config)
        for input in S.inputs(NavigationCausalityTests.events()) where input.arrival < S.ms(20) { engine.ingest(input) }
        let before = engine.counters.steps
        // 200 s of silence, then motion every 10 ms again.
        let resume = (0..<300).map { Self.motion(220 + Double($0) * 0.01) }
        #expect(!engine.accepts(resume[0]))
        engine.ingest(resume[0])
        #expect(engine.accepts(resume[1]))
        for input in resume.dropFirst() { engine.ingest(input) }
        #expect(engine.counters.inputsRejectedTimeJump == 1)
        // The grid caught up to the resume and kept stepping at 10 Hz.
        #expect(engine.counters.steps - before > 2_000)
        #expect(engine.counters.coalescedSteps > 0)

        // Two corrupt values far apart are both rejected.
        var other = NavigationEngine(config: config)
        for input in S.inputs(NavigationCausalityTests.events()) where input.arrival < S.ms(20) { other.ingest(input) }
        other.ingest(Self.motion(1e6))
        other.ingest(Self.motion(5e6))
        other.ingest(Self.motion(20.01))
        #expect(other.counters.inputsRejectedTimeJump == 2)
    }

    // MARK: Sidecar format

    static func estimate(_ t: Double, lat: Double = 0.001, dropped: Int = 0) -> NavSidecar.Estimate {
        var e = NavSidecar.Estimate(NavigationEstimate(
            t: S.ms(t), east: 10, north: 20, latitude: lat, longitude: 1.0 / 3.0, headingDeg: 359.999_999_999_9,
            headingStdDeg: 0.1 + 0.2, ellipse: ErrorEllipse(semiMajorM: 123.456_789_012_345_6, semiMinorM: 1e-300, orientationDeg: 179.9),
            speedMps: 13, speedScaleMean: 1.016_000_000_000_1, speedScaleStd: 0.01, effectiveSampleSize: 1999.5,
            converged: true, stationary: false
        ), droppedInputs: dropped, msPerStep: 0.061, maxStepMs: 0.38)
        e.converged = t > 2
        return e
    }

    static func sampleLines() -> [NavSidecar.Line] {
        var config = NavigationConfig(seed: UInt64.max - 12_345)  // above Int64.max
        config.extrapolationHorizonS = 2.5
        let pinFix = ManualFixSample(latitude: 0.002, longitude: -0.003, pressedT: S.ms(4), mapSpanM: 480, speedSource: "obd")
        var nonFinite = estimate(3)
        nonFinite.headingStdDeg = .infinity
        nonFinite.speedScale = .nan
        return [
            .header(NavSidecar.Header(sessionID: LogFixtures.sessionID, config: config, appBuild: "42")),
            .estimate(estimate(1)),
            .estimate(estimate(2, dropped: 3)),
            .pin(NavSidecar.Pin(ManualFixSample(latitude: 0.0005, longitude: 0, pressedT: S.ms(1), speedSource: "unknown"),
                                at: S.ms(2.5), prior: nil)),
            .estimate(nonFinite),
            .pin(NavSidecar.Pin(pinFix, at: S.ms(4.25), prior: estimate(4.25, dropped: 3))),
        ]
    }

    static func encoded(_ lines: [NavSidecar.Line]) throws -> Data {
        let encoder = NavSidecar.makeEncoder()
        return try lines.reduce(into: Data()) { $0.append(try NavSidecar.encode($1, with: encoder)) }
    }

    @Test("Sidecar round trip: header, estimates and pins decode to the same values, bit for bit, through a file")
    func sidecarRoundTrip() throws {
        let scratch = try ScratchDirectory()
        defer { scratch.remove() }
        let lines = Self.sampleLines()
        let writer = try NavSidecarWriter(url: scratch.file("drive.nav.jsonl"))
        for line in lines { writer.append(line) }
        #expect(writer.bytesWritten == 0, "buffered until flush")
        writer.flush()
        writer.close()
        #expect(writer.failure == nil && writer.linesLost == 0 && !writer.isOpen)
        let data = try Data(contentsOf: writer.url)
        #expect(data == (try Self.encoded(lines)))
        #expect(data.split(separator: 0x0A).count == lines.count)

        let contents = try NavSidecar.read(data)
        guard case .header(let header) = lines[0] else { Issue.record("no header"); return }
        #expect(contents.header == header)
        #expect(contents.header.seed == UInt64.max - 12_345)
        #expect(contents.header.sidecarVersion == NavSidecar.version)
        #expect(contents.header.configHash == { var c = NavigationConfig(seed: UInt64.max - 12_345); c.extrapolationHorizonS = 2.5; return c }().hashHex)
        #expect(contents.estimates.count == 3 && contents.pins.count == 2)
        #expect(contents.estimates[0] == Self.estimate(1))
        #expect(contents.estimates[0].headingDeg.bitPattern == Self.estimate(1).headingDeg.bitPattern)
        #expect(contents.estimates[2].headingStdDeg == .infinity && contents.estimates[2].speedScale.isNaN)
        #expect(contents.pins[0].prior == nil && contents.pins[1].prior == Self.estimate(4.25, dropped: 3))
        #expect(contents.pins[1].mapSpanM == 480)
        #expect(contents.droppedInputs == 3)
        #expect(!contents.truncatedLastLine && contents.unrecognizedLines == 0)
        // One JSON object per line, with its kind.
        let first = try #require(String(data: data, encoding: .utf8)?.split(separator: "\n").first)
        #expect(first.contains("\"kind\":\"header\""))
    }

    @Test("A truncated last line is dropped and reported; a bad line elsewhere, a missing header or a newer version is refused")
    func sidecarTruncation() throws {
        let lines = Self.sampleLines()
        let data = try Self.encoded(lines)
        for cut in [2, 10, 40] {  // 1 would remove only the final newline
            let truncated = data.dropLast(cut)
            let contents = try NavSidecar.read(Data(truncated))
            #expect(contents.truncatedLastLine, "cut \(cut)")
            #expect(contents.estimates.count == 3 && contents.pins.count == 1, "cut \(cut)")
        }
        // Without the final newline only: the line is whole and kept.
        let whole = try NavSidecar.read(Data(data.dropLast(1)))
        #expect(whole.pins.count == 2)
        #expect(!whole.truncatedLastLine)

        var text = String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
        text[2] = String(text[2].prefix(20))
        #expect(throws: NavSidecar.ReadError.self) { try NavSidecar.read(Data((text.joined(separator: "\n") + "\n").utf8)) }
        #expect(throws: NavSidecar.ReadError.missingHeader) { try NavSidecar.read(Self.encoded(Array(lines.dropFirst()))) }
        guard case .header(var newer) = lines[0] else { return }
        newer.sidecarVersion = NavSidecar.version + 1
        #expect(throws: NavSidecar.ReadError.unsupportedVersion(NavSidecar.version + 1)) {
            try NavSidecar.read(Self.encoded([.header(newer)] + lines.dropFirst()))
        }
        // An unknown kind from a later minor change is skipped and counted.
        let future = data + Data("{\"kind\":\"future\",\"x\":1}\n".utf8)
        #expect(try NavSidecar.read(future).unrecognizedLines == 1)
    }

    // MARK: The live loop

    @Test("The live loop: estimates on whole seconds from initialisation on, each what estimate(at:) gave then; the pin is the prior")
    func liveLoopGrid() throws {
        let inputs = NavigationReplay.fileOrderInputs(from: NavigationCausalityTests.events())
        let config = S.config(particles: 300, seed: 5)
        var run = LiveNavigationRun(sessionID: LogFixtures.sessionID, config: config, appBuild: "t")
        var shadow = NavigationEngine(config: config)
        var lines: [NavSidecar.Line] = []
        var expectedPins: [NavSidecar.Estimate?] = []
        var nextSecond = 1.0
        var expectedEstimates: [NavSidecar.Estimate] = []
        for input in inputs {
            while S.ms(nextSecond) <= input.arrival {
                if let e = shadow.estimate(at: S.ms(nextSecond)) { expectedEstimates.append(NavSidecar.Estimate(e)) }
                nextSecond += 1
            }
            if case .manualFix(_, let t) = input { expectedPins.append(shadow.estimate(at: t).map { NavSidecar.Estimate($0) }) }
            run.ingest(input) { lines.append($0) }
            shadow.ingest(input)
        }
        let estimates = lines.compactMap { if case .estimate(let e) = $0 { e } else { nil } }
        let pins = lines.compactMap { if case .pin(let p) = $0 { p } else { nil } }
        #expect(estimates.count == expectedEstimates.count && estimates.count >= 50)
        #expect(estimates.allSatisfy { $0.t.nanoseconds % 1_000_000_000 == 0 })
        for (a, b) in zip(estimates, expectedEstimates) {
            #expect(SidecarComparison.Differences.bitEqual(a, b), "t \(a.t.seconds)")
            #expect(a.msPerStep != nil && a.droppedInputs == 0)
        }
        #expect(pins.count == 1 && pins.map(\.prior) == expectedPins.map { $0.map { var e = $0; e.msPerStep = pins[0].prior?.msPerStep; e.maxStepMs = pins[0].prior?.maxStepMs; return e } })
        #expect(run.engine.counters == shadow.counters)
        #expect(run.inputs == inputs.count && run.estimates == estimates.count)
        let snapshot = run.snapshot(at: S.ms(54), droppedInputs: 7)
        #expect(snapshot.initialized && snapshot.sessionID == LogFixtures.sessionID)
        #expect(snapshot.estimate == shadow.estimate(at: S.ms(54)))
        #expect(snapshot.stats.droppedInputs == 7 && snapshot.stats.steps == shadow.counters.steps)
        #expect(snapshot.stats.msPerStep > 0 && snapshot.stats.maxMsPerStep >= snapshot.stats.msPerStep)
        #expect(snapshot.stats.effectiveSampleSize == snapshot.estimate?.effectiveSampleSize)
        #expect(!NavigationSnapshot.idle(at: .zero).initialized && !NavigationSnapshot.idle(at: .zero).converged)
    }

    @Test("The live loop: a rejected jump emits nothing and leaves the grid; a long silence emits at most 600 estimates, then resumes")
    func liveLoopGaps() throws {
        var config = S.config(particles: 100)
        config.maxForwardJumpS = 7_200
        var run = LiveNavigationRun(sessionID: LogFixtures.sessionID, config: config, appBuild: "t")
        var lines: [NavSidecar.Line] = []
        let early = S.inputs(NavigationCausalityTests.events()).filter { $0.arrival < S.ms(20) }
        for input in early { run.ingest(input) { lines.append($0) } }
        let before = lines.count
        run.ingest(Self.motion(1e9)) { lines.append($0) }  // rejected
        #expect(lines.count == before && run.engine.counters.inputsRejectedTimeJump == 1)
        // A 2000 s silence, accepted (under the 7200 s limit).
        run.ingest(Self.motion(2_020.005)) { lines.append($0) }
        let gap = lines[before...].compactMap { if case .estimate(let e) = $0 { e.t.seconds } else { nil } }
        #expect(gap.count == LiveNavigationRun.maxEstimatesPerGap + 1)
        #expect(gap.first == 20 && gap[LiveNavigationRun.maxEstimatesPerGap - 1] == 619 && gap.last == 2_020)
        run.ingest(Self.motion(2_021.5)) { lines.append($0) }
        #expect(lines.last.map { if case .estimate(let e) = $0 { e.t.seconds } else { -1 } } == 2_021)
    }

    // MARK: Live path → file → as-live compare

    /// File order as a recorder writes it: CoreMotion delivers 10 samples per
    /// batch, so a motion sample is written at the end of its 100 ms batch,
    /// after OBD replies and fixes that arrived meanwhile. File order then
    /// differs from arrival order.
    static func recorderOrder(_ events: [LogEvent]) -> [LogEvent] {
        func written(_ event: LogEvent) -> Int64 {
            guard let input = NavigationInput(event) else { return event.timestamp.nanoseconds }
            if case .motion = input {
                let batch: Int64 = 100_000_000
                return (input.arrival.nanoseconds / batch + 1) * batch
            }
            return input.arrival.nanoseconds
        }
        return events.enumerated()
            .sorted { written($0.element) != written($1.element) ? written($0.element) < written($1.element) : $0.offset < $1.offset }
            .map(\.element)
    }

    @Test("A sidecar from the live path (sink tap → stream → live loop → writer) equals the as-live replay of the file exactly")
    func liveSidecarMatchesAsLiveReplay() async throws {
        let scratch = try ScratchDirectory()
        defer { scratch.remove() }
        let events = Self.recorderOrder(NavigationCausalityTests.events())
        // Large enough that this test never drops: drops are the App tests'.
        let tap = NavigationTap(bufferLimit: 1_000_000)
        let writer = try TapFixtures.writer(scratch, "live.jsonl.gz", tap: tap.tap)
        let sidecarURL = NavSidecarFile.url(forRecording: scratch.file("live.jsonl.gz"))
        let header = WriterFixtures.header
        let consumer = Task {
            var run = LiveNavigationRun(header: header, appBuild: "test")
            let out = try NavSidecarWriter(url: sidecarURL)
            out.append(.header(run.header))
            var count = 0
            for await input in tap.inputs {
                run.ingest(input, droppedInputs: tap.droppedInputs) { out.append($0) }
                count += 1
                if count % 1_000 == 0 { out.flush() }
            }
            out.close()
            return (run.estimates, out.failure)
        }
        let summary = try await TapFixtures.write(events, to: writer)
        tap.finish()
        let (estimateCount, failure) = try await consumer.value
        #expect(failure == nil && tap.droppedInputs == 0)

        let read = try WriterFixtures.read(summary.url, recovery: .strict)
        let contents = try NavSidecar.read(contentsOf: sidecarURL)
        let seed = NavigationSeed.derive(header: read.header)
        #expect(contents.header.seed == seed && contents.header.sessionID == read.header.sessionID)
        #expect(contents.estimates.count == estimateCount && estimateCount >= 50)
        #expect(contents.pins.count == 1 && contents.pins[0].prior != nil)

        // replay_nav --as-live --compare: file order, header seed, default config.
        let config = NavigationConfig(seed: seed)
        let asLive = NavigationReplay.liveLines(inputs: NavigationReplay.fileOrderInputs(from: read.events),
                                                sessionID: read.header.sessionID, config: config)
        let comparison = SidecarComparison(sidecar: contents, replay: asLive, replayConfig: config)
        #expect(comparison.exact, "\(comparison.report(tolerance: .default))")
        #expect(comparison.estimates.positionM == 0 && comparison.estimates.headingDeg == 0 && comparison.estimates.ellipseAxesM == 0)
        #expect(comparison.estimates.matched == estimateCount && comparison.pins.matched == 1)
        #expect(!comparison.configHashMismatch && !comparison.seedMismatch && comparison.droppedInputs == 0)
        #expect(comparison.passes(SidecarComparison.Tolerance(metres: 0, degrees: 0)))

        // The order matters: arrival order (the normal replay) is not what ran live.
        let arrival = NavigationReplay.liveLines(inputs: NavigationReplay.inputs(from: read.events),
                                                 sessionID: read.header.sessionID, config: config)
        let other = SidecarComparison(sidecar: contents, replay: arrival, replayConfig: config)
        #expect(!other.exact && other.estimates.unequal > 0)

        // So do the seed and config: a mismatch is reported (a warning in replay_nav).
        let seed1 = NavigationReplay.liveLines(inputs: NavigationReplay.fileOrderInputs(from: read.events),
                                               sessionID: read.header.sessionID, config: NavigationConfig())
        let wrongSeed = SidecarComparison(sidecar: contents, replay: seed1, replayConfig: NavigationConfig())
        #expect(wrongSeed.seedMismatch && wrongSeed.configHashMismatch && wrongSeed.configDifferences == ["seed"])
        #expect(!wrongSeed.exact)
        #expect(wrongSeed.report(tolerance: .default).contains("a different seed or config"))

        // The replay's own pin estimate (metrics, GeoJSON) is the sidecar's pin.
        var options = ReplayOptions(gps: .use, config: config)
        options.asLive = true
        let result = NavigationReplay.run(logName: "live", inputs: NavigationReplay.fileOrderInputs(from: read.events),
                                          options: options)
        #expect(result.mode == "use-as-live")
        let replayPin = try #require(result.pins.first?.pin.prior)
        let livePin = try #require(contents.pins.first?.prior)
        #expect(SidecarComparison.Differences.bitEqual(replayPin, livePin))
        #expect(result.pins.first?.ring?.count == 37)
        let geo = try #require(try JSONSerialization.jsonObject(with: ReplayReport.geoJSON(result)) as? [String: Any])
        let kinds = (geo["features"] as? [[String: Any]] ?? []).compactMap { ($0["properties"] as? [String: Any])?["kind"] as? String }
        #expect(kinds.suffix(2) == ["pinEstimate", "pinEllipse95"])
        #expect(ReplayMetrics(result).pins?.count == 1)
    }

    @Test("Compare: dropped inputs and encoding failures are reported as the explanation; a tolerance passes a tiny difference")
    func compareExplainsDifferences() throws {
        let lines = Self.sampleLines()
        let contents = try NavSidecar.read(Self.encoded(lines))
        guard case .header(let header) = lines[0] else { return }
        let config = try JSONDecoder().decode(NavigationConfig.self, from: Data(header.configJSON.utf8))
        #expect(config.hashHex == header.configHash)
        var replay = lines
        // Replay: no drops, no timing; one estimate 0.5 m north of the live one.
        if case .estimate(var e) = replay[1] {
            e.latitude += 0.5 / 111_320
            replay[1] = .estimate(e)
        }
        let comparison = SidecarComparison(sidecar: contents, replay: replay, replayConfig: config, encodingFailures: 2)
        #expect(!comparison.exact)
        #expect(comparison.estimates.positionM > 0.45 && comparison.estimates.positionM < 0.55)
        #expect(comparison.estimates.firstDifferenceT == S.ms(1))
        #expect(comparison.passes(.default))
        #expect(!comparison.passes(SidecarComparison.Tolerance(metres: 0.1, degrees: 0.1)))
        let report = comparison.report(tolerance: .default)
        #expect(report.contains("PASS within tolerance"))
        #expect(report.contains("3 dropped input(s)") && report.contains("2 row(s) that failed to encode"))
        // A missing estimate is never within tolerance.
        let shorter = SidecarComparison(sidecar: contents, replay: Array(lines.dropLast(2)), replayConfig: config)
        #expect(shorter.sidecarOnly == 1 && shorter.pinsUnmatched == 1 && !shorter.passes(.default))
        // Identical lines compare exactly (timing and drops are not compared).
        #expect(SidecarComparison(sidecar: contents, replay: lines, replayConfig: config).exact)
    }

    @Test("encodingFailed rows of navigation kinds are found; other kinds are not")
    func encodingFailuresFound() {
        let events: [LogEvent] = [
            LogEvent(timestamp: S.ms(1), payload: .lifecycle(LifecycleSample(.error, detail: "encodingFailed motion: invalidValue(nan)"))),
            LogEvent(timestamp: S.ms(2), payload: .lifecycle(LifecycleSample(.error, detail: "encodingFailed stats: x"))),
            LogEvent(timestamp: S.ms(3), payload: .lifecycle(LifecycleSample(.error, detail: "disk full"))),
            LogEvent(timestamp: S.ms(4), payload: .lifecycle(LifecycleSample(.error, detail: "encodingFailed location: y"))),
        ]
        let found = NavigationReplay.encodingFailures(in: events)
        #expect(found.map(\.kind) == ["motion", "location"])
        #expect(found.map(\.t) == [S.ms(1), S.ms(4)])
    }
}
