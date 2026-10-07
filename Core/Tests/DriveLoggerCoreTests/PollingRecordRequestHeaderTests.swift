import Foundation
import Testing

@testable import DriveLoggerCore

/// `PollingRecord.requestHeader`, added after the 2026-10-07 bench test: the
/// CAN request header polls go out with. Optional and written only when
/// present, so recordings without it (every file before it existed, and
/// every functional-addressing plan) encode exactly as before.
@Suite("PollingRecord.requestHeader")
struct PollingRecordRequestHeaderTests {
    static let physicalPlan = PollingPlan(
        pids: [.vehicleSpeed, .engineSpeed], multiPID: true, responseCount: 1,
        adaptiveTiming: 1, rpmEvery: 5, timeout: .seconds(1), requestHeader: .engine
    )

    static let functionalPlan = PollingPlan(
        pids: [.vehicleSpeed, .engineSpeed], multiPID: true, responseCount: nil,
        adaptiveTiming: 1, rpmEvery: 5, timeout: .seconds(1)
    )

    static func header(polling: PollingRecord) -> LogHeader {
        LogHeader(
            sessionID: LogFixtures.sessionID,
            startedAt: Date(timeIntervalSince1970: 1_791_331_200),
            referenceUptimeSeconds: 5_000.25,
            app: LogFixtures.app,
            device: LogFixtures.device,
            polling: polling
        )
    }

    @Test("PollingRecord(plan) records the physical header, and nothing for functional addressing")
    func fromPlan() {
        #expect(PollingRecord(Self.physicalPlan) == PollingRecord(
            command: "010D0C1", pids: [13, 12], multiPID: true, responseCount: 1,
            adaptiveTiming: 1, rpmEvery: 5, timeoutMs: 1_000, requestHeader: "7E0"
        ))
        #expect(PollingRecord(Self.functionalPlan).requestHeader == nil)
        #expect(PollingRecord(.baseline).requestHeader == nil)
    }

    @Test("adapter row: requestHeader is written and read back")
    func adapterRowRoundTrip() throws {
        let codec = LogCodec()
        let info = ELMAdapterInfo(
            elmVersion: "ELM327 v2.3", protocolNumber: "6", voltage: 11.0,
            supportedPIDs: "7E906410098180001\r7E8064100BE1CA813\r\r", plan: Self.physicalPlan
        )
        let event = LogEvent(adapter: MappingFixtures.bleAdapter, info: info, uptime: 1_002, clock: MappingFixtures.clock)
        let line = try codec.line(for: event)
        let text = String(decoding: line, as: UTF8.self)
        #expect(text.contains(#""requestHeader":"7E0""#))
        let decoded = try codec.event(from: line)
        #expect(decoded == event)
        guard case .adapter(let sample) = decoded.payload else {
            Issue.record("not an adapter row: \(decoded.payload)")
            return
        }
        #expect(sample.polling?.requestHeader == "7E0")
        #expect(try codec.line(for: decoded) == line, "re-encoding is byte-identical")
    }

    @Test("Header polling section: requestHeader is written and read back")
    func headerRoundTrip() throws {
        let codec = LogCodec()
        let header = Self.header(polling: PollingRecord(Self.physicalPlan))
        let line = try codec.line(for: header)
        #expect(String(decoding: line, as: UTF8.self).contains(#""requestHeader":"7E0""#))
        let decoded = try codec.header(from: line)
        #expect(decoded == header)
        #expect(decoded.polling?.requestHeader == "7E0")
        #expect(try codec.line(for: decoded) == line)
    }

    @Test("Functional addressing writes no requestHeader key at all")
    func absentWhenFunctional() throws {
        let codec = LogCodec()
        let line = try codec.line(for: Self.header(polling: PollingRecord(Self.functionalPlan)))
        #expect(!String(decoding: line, as: UTF8.self).contains("requestHeader"))
        #expect(try codec.header(from: line).polling?.requestHeader == nil)
    }

    @Test("A polling section written before requestHeader existed decodes with it absent")
    func olderPollingSectionDecodes() throws {
        let json = #"{"adaptiveTiming":1,"command":"010D","multiPID":false,"pids":[13,12],"rpmEvery":5,"timeoutMs":1000}"#
        let record = try JSONDecoder().decode(PollingRecord.self, from: Data(json.utf8))
        #expect(record.requestHeader == nil)
        #expect(record.command == "010D")
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        #expect(String(decoding: try encoder.encode(record), as: UTF8.self) == json)
    }
}
