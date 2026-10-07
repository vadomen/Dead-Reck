import Foundation
import Testing

@testable import DriveLoggerCore

enum MappingFixtures {
    /// Reference uptime 1000 s. The live source reads 5000 s, so any row
    /// stamped with `now()` instead of the event's own uptime is far off.
    static let clock = SessionClock(
        referenceUptimeSeconds: 1_000,
        wallClockStart: Date(timeIntervalSince1970: 1_700_000_000),
        source: FixedUptimeSource(uptimeSeconds: 5_000)
    )

    static func ns(_ secondsAfterReference: Double) -> MonotonicTimestamp {
        MonotonicTimestamp(seconds: secondsAfterReference)
    }

    static let multiPlan = PollingPlan(
        pids: [.vehicleSpeed, .engineSpeed], multiPID: true, responseCount: 1,
        adaptiveTiming: 2, rpmEvery: 1, timeout: .milliseconds(750)
    )

    static let info = ELMAdapterInfo(
        elmVersion: "ELM327 v2.1", protocolNumber: "A6", voltage: 12.6,
        supportedPIDs: "7E8064100BE3FA813", plan: multiPlan
    )

    static let bleAdapter = AdapterRecord(
        name: "IOS-Vlink",
        identifier: "6B1E9C1A-3C0E-4C55-9E57-0C6C2C0B8E11",
        gatt: GATTSelection(
            service: "E7810A71-73AE-499D-8C15-FAA9AEF0C3F2", notify: "BEF8D6C9-9C21-4C9E-B632-BD58C1009F9F",
            write: "BEF8D6C9-9C21-4C9E-B632-BD58C1009F9F", writeType: "withResponse", maxWriteLength: 20
        ),
        gattTable: [GATTServiceRecord(service: "FFF0", characteristics: [GATTCharacteristicRecord(uuid: "FFF1", properties: ["notify"])])],
        elmVersion: "stale", protocolNumber: "stale", voltage: 1
    )
}

@Suite("Event mapping")
struct EventMappingTests {
    typealias F = MappingFixtures

    @Test("elm row: t at completion, requestT at the write, vocabulary as raw strings")
    func exchangeRow() {
        let exchange = ELMExchange(
            seq: 41, phase: .poll, tx: "010D0C1", requestUptime: 1_010.25,
            rx: "7E804410D320C1AF8\r\r", completedUptime: 1_010.30, outcome: .ok
        )
        let row = LogEvent(exchange: exchange, clock: F.clock)
        #expect(row.timestamp == F.ns(10.30))
        #expect(row.payload == .elm(ELMTrafficSample(
            seq: 41, phase: "poll", tx: "010D0C1", requestT: F.ns(10.25),
            rx: "7E804410D320C1AF8\r\r", outcome: "ok"
        )))
    }

    @Test("elm row for a timeout and a rejection: no rx")
    func timeoutAndRejection() throws {
        let timeout = LogEvent(exchange: ELMExchange(
            seq: 2, phase: .initialisation, tx: "0100", requestUptime: 1_001, rx: nil,
            completedUptime: 1_011, outcome: .timeout
        ), clock: F.clock)
        guard case .elm(let sample) = timeout.payload else {
            Issue.record("expected elm")
            return
        }
        #expect(sample.phase == "init")
        #expect(sample.outcome == "timeout")
        #expect(sample.rx == nil)
        #expect(timeout.timestamp == F.ns(11))

        let rejected = LogEvent(exchange: ELMExchange(
            seq: 3, phase: .manual, tx: "04", requestUptime: 1_002, rx: nil,
            completedUptime: 1_002, outcome: .rejected
        ), clock: F.clock)
        let line = String(decoding: try LogCodec().line(for: rejected), as: UTF8.self)
        #expect(!line.contains("\"rx\""))
        #expect(line.contains("\"outcome\":\"rejected\""))
    }

    @Test("obd row: t at the reply, requestT, command, ECU, seq, verbatim raw")
    func readingRow() {
        let reading = OBDReading(
            seq: 41, command: "010D0C1", ecu: "7E8",
            measurement: OBDMeasurement(pid: .vehicleSpeed, value: 50, unit: .kilometersPerHour),
            raw: "7E804410D320C1AF8\r\r", requestUptime: 1_010.25, replyUptime: 1_010.30
        )
        let row = LogEvent(reading: reading, clock: F.clock)
        #expect(row.timestamp == F.ns(10.30))
        #expect(row.payload == .obd(OBDSample(
            pid: .vehicleSpeed, value: 50, unit: .kilometersPerHour, raw: "7E804410D320C1AF8\r\r",
            requestT: F.ns(10.25), command: "010D0C1", ecu: "7E8", seq: 41
        )))
    }

    @Test("link rows for both layers")
    func linkRows() {
        let elm = LogEvent(elmTransitionFrom: .polling, to: .retrying, reason: "timeout", uptime: 1_020, clock: F.clock)
        #expect(elm == LogEvent(timestamp: F.ns(20), payload: .link(LinkSample(layer: "elm", from: "polling", to: "retrying", reason: "timeout"))))
        let ble = LogEvent(bleTransitionFrom: .connected, to: .disconnected, reason: nil, uptime: 1_021, clock: F.clock)
        #expect(ble == LogEvent(timestamp: F.ns(21), payload: .link(LinkSample(layer: "ble", from: "connected", to: "disconnected"))))
    }

    @Test("adapter row merges BLE facts with what the ELM session found, plus the polling record")
    func adapterRow() {
        let row = LogEvent(adapter: F.bleAdapter, info: F.info, uptime: 1_005, clock: F.clock)
        #expect(row.timestamp == F.ns(5))
        guard case .adapter(let sample) = row.payload else {
            Issue.record("expected adapter")
            return
        }
        #expect(sample.adapter.name == "IOS-Vlink")
        #expect(sample.adapter.gatt == F.bleAdapter.gatt)
        #expect(sample.adapter.gattTable == F.bleAdapter.gattTable)
        #expect(sample.adapter.elmVersion == "ELM327 v2.1")
        #expect(sample.adapter.protocolNumber == "A6")
        #expect(sample.adapter.voltage == 12.6)
        #expect(sample.polling == PollingRecord(F.multiPlan))
    }

    @Test("AdapterRecord.with replaces every ELM field, keeping the BLE ones")
    func adapterMerge() {
        var info = F.info
        info.voltage = nil
        let merged = F.bleAdapter.with(info)
        #expect(merged.name == F.bleAdapter.name)
        #expect(merged.identifier == F.bleAdapter.identifier)
        #expect(merged.elmVersion == "ELM327 v2.1")
        #expect(merged.protocolNumber == "A6")
        #expect(merged.voltage == nil)  // not the stale value from an earlier init
    }

    @Test("PollingRecord: multi-PID command, PIDs as integers, timeout in ms")
    func pollingRecordMulti() {
        let record = PollingRecord(F.multiPlan)
        #expect(record == PollingRecord(
            command: "010D0C1", pids: [13, 12], multiPID: true, responseCount: 1,
            adaptiveTiming: 2, rpmEvery: 1, timeoutMs: 750
        ))
    }

    @Test("PollingRecord: single-PID plans name the every-cycle command")
    func pollingRecordSingle() {
        #expect(PollingRecord(.baseline) == PollingRecord(
            command: "010D", pids: [13, 12], multiPID: false, responseCount: nil,
            adaptiveTiming: 1, rpmEvery: 5, timeoutMs: 1_000
        ))
        var withSuffix = PollingPlan.baseline
        withSuffix.responseCount = 1
        #expect(PollingRecord(withSuffix).command == "010D1")
        var empty = PollingPlan.baseline
        empty.pids = []
        #expect(PollingRecord(empty).command == "")
        #expect(PollingRecord(empty).pids == [])
    }

    @Test("PollingRecord rounds sub-millisecond timeouts")
    func pollingTimeoutRounding() {
        var plan = PollingPlan.baseline
        plan.timeout = .microseconds(1_500_600)
        #expect(PollingRecord(plan).timeoutMs == 1_501)
        plan.timeout = .seconds(10)
        #expect(PollingRecord(plan).timeoutMs == 10_000)
    }

    @Test("rows(for:) covers every link event; pollRate and needsReconnect write nothing")
    func rowsForEveryCase() {
        let exchange = ELMExchange(seq: 1, phase: .poll, tx: "010D", requestUptime: 1_001, rx: "7E803410D32", completedUptime: 1_001.05, outcome: .ok)
        let reading = OBDReading(
            seq: 1, command: "010D", ecu: "7E8",
            measurement: OBDMeasurement(pid: .vehicleSpeed, value: 50, unit: .kilometersPerHour),
            raw: "7E803410D32", requestUptime: 1_001, replyUptime: 1_001.05
        )
        let cases: [(LinkEvent, [LogEvent])] = [
            (.ble(from: .scanning, to: .connecting, reason: nil, uptime: 1_000.5),
             [LogEvent(bleTransitionFrom: .scanning, to: .connecting, reason: nil, uptime: 1_000.5, clock: F.clock)]),
            (.session(.state(from: .ready, to: .polling, reason: nil, uptime: 1_000.75)),
             [LogEvent(elmTransitionFrom: .ready, to: .polling, reason: nil, uptime: 1_000.75, clock: F.clock)]),
            (.session(.exchange(exchange)), [LogEvent(exchange: exchange, clock: F.clock)]),
            (.session(.reading(reading)), [LogEvent(reading: reading, clock: F.clock)]),
            (.session(.adapter(F.info, uptime: 1_000.9)),
             [LogEvent(adapter: F.bleAdapter, info: F.info, uptime: 1_000.9, clock: F.clock)]),
            (.session(.pollRate(hz: 9.5, uptime: 1_010)), []),
            (.session(.needsReconnect(uptime: 1_011)), []),
        ]
        for (event, expected) in cases {
            #expect(LogEvent.rows(for: event, adapter: F.bleAdapter, clock: F.clock) == expected, "\(event)")
        }
    }

    @Test("An adapter event with no BLE record still writes the ELM facts, with empty BLE fields")
    func adapterWithoutBLE() {
        let rows = LogEvent.rows(for: .session(.adapter(F.info, uptime: 1_001)), adapter: nil, clock: F.clock)
        guard rows.count == 1, case .adapter(let sample) = rows[0].payload else {
            Issue.record("expected one adapter row, got \(rows)")
            return
        }
        #expect(sample.adapter.name == "")
        #expect(sample.adapter.identifier == "")
        #expect(sample.adapter.gatt == nil)
        #expect(sample.adapter.elmVersion == "ELM327 v2.1")
    }

    @Test("Events from before the session start keep negative timestamps")
    func negativeOffsets() {
        let row = LogEvent(elmTransitionFrom: .idle, to: .resetting, reason: nil, uptime: 990.5, clock: F.clock)
        #expect(row.timestamp == MonotonicTimestamp(nanoseconds: -9_500_000_000))
        let exchange = ELMExchange(seq: 0, phase: .initialisation, tx: "ATZ", requestUptime: 990, rx: "ELM327 v2.1", completedUptime: 991, outcome: .ok)
        guard case .elm(let sample) = LogEvent(exchange: exchange, clock: F.clock).payload else {
            Issue.record("expected elm")
            return
        }
        #expect(sample.requestT == MonotonicTimestamp(nanoseconds: -10_000_000_000))
    }
}
