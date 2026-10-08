import Foundation
import Testing

@testable import DriveLoggerCore

// M4 bench (docs/BENCH_TEST_2026-10-08.md): the re-init's 3-sample probe
// picked ATAT2 on a 4.6 ms edge (58.9 vs 63.5 ms), and the steady state was
// identical (median 59.3 vs 59.2 ms, 16.4 Hz either way). ATAT1 is now kept
// unless ATAT2's median, over `adaptiveTimingSamples` polls at each level,
// is at least `adaptiveTimingMinimumGain` lower.
//
// The mock tracks the adapter's ATAT level, so each rule below answers only
// at the level it names: the delays are the scripted latencies at ATAT1 and
// ATAT2.

@Suite("ELMSession ATAT1 vs ATAT2 (M4 bench)", .timeLimit(.minutes(1)))
struct ELMSessionAdaptiveTimingTests {
    typealias Rule = MockELMAdapter.Rule

    static let speedRPM = "7E806410D3C0C0BB8\r\r>"

    /// `010D0C1` (the Touareg's winning command) answered in `ms` at `level`.
    static func poll(ms: Double, level: Int, reply: String = speedRPM, times: Int? = nil) -> Rule {
        Rule(
            command: "010D0C1", reply: reply, delay: .microseconds(Int((ms * 1_000).rounded())),
            fragmentSizes: [20], times: times, adaptiveTiming: level
        )
    }

    static func harness(_ rules: [Rule]) -> SessionHarness {
        SessionHarness(rules: rules + MockELMAdapter.Rule.touareg, configuration: ELMSessionProbeTests.probing)
    }

    /// Probe-phase `010D0C1` exchanges, grouped by the ATAT level the
    /// adapter was at when each was sent (the last `ATATn` answered `OK`
    /// before it).
    static func probesByLevel(_ exchanges: [ELMExchange]) -> [Int: [ELMExchange]] {
        var level = 1
        var grouped: [Int: [ELMExchange]] = [:]
        for exchange in exchanges {
            if exchange.tx.hasPrefix("ATAT"), exchange.outcome == .ok, let n = Int(exchange.tx.dropFirst(4)) {
                level = n
            } else if exchange.tx == "010D0C1", exchange.phase == .probe {
                grouped[level, default: []].append(exchange)
            }
        }
        return grouped
    }

    static func timingNote(_ log: EventLog) async -> String? {
        await log.transitions.last { $0.from == $0.to && $0.reason?.hasPrefix("adaptive timing: ") == true }?.reason
    }

    @Test("The thresholds: 10 samples at each level, ATAT2 at least 10% lower")
    func constants() {
        #expect(ELMSession.adaptiveTimingSamples == 10)
        #expect(ELMSession.adaptiveTimingMinimumGain == 0.10)
        #expect(ELMSession.isClearlyFaster(53, than: 60))
        #expect(!ELMSession.isClearlyFaster(55, than: 60))
        #expect(!ELMSession.isClearlyFaster(58.9, than: 63.5), "the bench edge that flipped the re-init")
        #expect(!ELMSession.isClearlyFaster(60, than: 60))
        #expect(!ELMSession.isClearlyFaster(61, than: 60))
    }

    @Test(
        "A small ATAT2 edge keeps ATAT1",
        arguments: [(60.0, 56.0), (63.5, 58.9), (59.3, 59.2), (60.0, 60.0), (60.0, 64.0)]
    )
    func smallEdgeKeepsATAT1(atat1: Double, atat2: Double) async throws {
        let harness = Self.harness([Self.poll(ms: atat1, level: 1), Self.poll(ms: atat2, level: 2)])
        let info = try await harness.initialise()

        #expect(info.plan.adaptiveTiming == 1)
        #expect(info.plan.primaryCommand.wireFormat == "010D0C1")
        let sent = await harness.mock.sentCommands
        #expect(sent.last == "ATAT1", "adapter must be left at ATAT1")
        #expect(await harness.mock.adaptiveTiming == 1)
        let byLevel = Self.probesByLevel(await harness.log.exchanges)
        // Selection's samples, then the timing comparison's at each level.
        #expect(byLevel[1]?.count == ELMSession.probeSamples + ELMSession.adaptiveTimingSamples)
        #expect(byLevel[2]?.count == ELMSession.adaptiveTimingSamples)
        #expect(byLevel.values.joined().allSatisfy { $0.outcome == .ok })
        let note = try #require(await Self.timingNote(harness.log))
        #expect(note.hasPrefix("adaptive timing: ATAT1 kept"))
        #expect(note.contains("10 samples each"))
    }

    @Test("A clear ATAT2 edge picks ATAT2", arguments: [(60.0, 53.0), (95.0, 45.0)])
    func clearEdgePicksATAT2(atat1: Double, atat2: Double) async throws {
        let harness = Self.harness([Self.poll(ms: atat1, level: 1), Self.poll(ms: atat2, level: 2)])
        let info = try await harness.initialise()

        #expect(info.plan.adaptiveTiming == 2)
        #expect(await harness.mock.adaptiveTiming == 2)
        let sent = await harness.mock.sentCommands
        let lastATAT = try #require(sent.last { $0.hasPrefix("ATAT") })
        #expect(lastATAT == "ATAT2")
        let byLevel = Self.probesByLevel(await harness.log.exchanges)
        #expect(byLevel[2]?.count == ELMSession.adaptiveTimingSamples)
        let note = try #require(await Self.timingNote(harness.log))
        #expect(note == String(
            format: "adaptive timing: ATAT2 kept, median %.1f ms at ATAT2 vs %.1f ms at ATAT1 "
                + "(10 samples each; ATAT2 must be at least 10%% lower)",
            atat2, atat1
        ))
        #expect(await harness.log.adapterInfos.last?.plan.adaptiveTiming == 2)
    }

    @Test("Median, not mean: one slow ATAT1 sample doesn't make ATAT2 look clearly faster")
    func medianNotMean() async throws {
        // ATAT1: selection's 3 samples at 60 ms, then one 160 ms outlier and
        // 60 ms after that. Mean of the 10 timing samples 70 ms, median 60.
        // ATAT2 at 57 ms is 18.6% below the mean, but only 5% below the
        // median: ATAT1 stays.
        let harness = Self.harness([
            Self.poll(ms: 60, level: 1, times: ELMSession.probeSamples),
            Self.poll(ms: 160, level: 1, times: 1),
            Self.poll(ms: 60, level: 1),
            Self.poll(ms: 57, level: 2),
        ])
        let info = try await harness.initialise()
        #expect(info.plan.adaptiveTiming == 1)
        #expect(await harness.mock.sentCommands.last == "ATAT1")
    }

    @Test("An ATAT2 that cuts replies short is rejected, even once in ten", arguments: [0, 9])
    func shortRepliesRejected(goodBefore: Int) async throws {
        // Under ATAT2 the adapter stops waiting before RPM arrives: the
        // reply is fast but carries speed only. `goodBefore` full replies
        // come first.
        let harness = Self.harness([
            Self.poll(ms: 60, level: 1),
            Self.poll(ms: 30, level: 2, times: goodBefore),
            Self.poll(ms: 20, level: 2, reply: "7E803410D3C\r\r>", times: 1),
            Self.poll(ms: 30, level: 2),
        ])
        let info = try await harness.initialise()

        #expect(info.plan.adaptiveTiming == 1)
        #expect(await harness.mock.sentCommands.last == "ATAT1")
        #expect(await harness.mock.adaptiveTiming == 1)
        let atat2 = Self.probesByLevel(await harness.log.exchanges)[2] ?? []
        #expect(atat2.count == goodBefore + 1, "measurement stops at the first short reply")
        #expect(atat2.last?.outcome == .ok, "a short reply is a well-formed exchange; it just lacks a PID")
        #expect(await Self.timingNote(harness.log) == "adaptive timing: ATAT1 kept, ATAT2 replies did not parse")
    }

    @Test("ATAT2 refused: ATAT1 stays, with a note")
    func atat2Refused() async throws {
        let harness = Self.harness([
            Rule(command: "ATAT2", reply: "?\r\r>", delay: .milliseconds(10)),
            Self.poll(ms: 60, level: 1),
        ])
        let info = try await harness.initialise()
        #expect(info.plan.adaptiveTiming == 1)
        #expect(await harness.mock.adaptiveTiming == 1)
        #expect(Self.probesByLevel(await harness.log.exchanges)[2] == nil)
        #expect(await Self.timingNote(harness.log) == "adaptive timing: ATAT1 kept, ATAT2 not accepted (notRecognised)")
    }

    @Test("Single-PID plans: per-cycle cost from each PID's median; a clear edge picks ATAT2")
    func singlePIDClearEdge() async throws {
        // Multi-PID and the suffix are refused, so selection lands on
        // 010D + 010C every 5th cycle.
        let refused: [Rule] = ["010D1", "010C1", "010D0C", "010D0C1"].map {
            Rule(command: $0, reply: "?\r\r>", delay: .milliseconds(5))
        }
        let harness = Self.harness(refused + [
            Rule(command: "010D", reply: "7E803410D3C\r\r>", delay: .milliseconds(95), adaptiveTiming: 1),
            Rule(command: "010C", reply: "7E804410C0BB8\r\r>", delay: .milliseconds(95), adaptiveTiming: 1),
            Rule(command: "010D", reply: "7E803410D3C\r\r>", delay: .milliseconds(50), adaptiveTiming: 2),
            Rule(command: "010C", reply: "7E804410C0BB8\r\r>", delay: .milliseconds(50), adaptiveTiming: 2),
        ])
        let info = try await harness.initialise()
        #expect(info.plan.multiPID == false)
        #expect(info.plan.responseCount == nil)
        #expect(info.plan.adaptiveTiming == 2)
    }
}
