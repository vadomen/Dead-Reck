import Foundation
import Testing

@testable import DriveLoggerCore

/// Every reply from `docs/BENCH_TEST_2026-10-07.md` (Vgate iCar Pro BLE 4.0,
/// ELM327 v2.3, on the test car), verbatim: the text between the command and
/// the `>` prompt, with the `\r` line endings the adapter sends (echo,
/// linefeeds and spaces off). The terminal doesn't show the blank line an
/// ELM327 prints before its prompt; it is the trailing second `\r`.
///
/// Deliberately a separate copy from `MockELMAdapter.Rule.benchCar`, so the
/// mock is checked against the transcript instead of against itself.
enum BenchTranscript {
    // Block 1: functional addressing (7DF), engine off.
    static let ati = "ELM327 v2.3\r\r"
    static let atrvEngineOff = "11.0V\r\r"
    static let atdpn = "6\r\r"
    static let ath1 = "OK\r\r"
    static let supportedPIDs0100 = "7E906410098180001\r7E8064100BE1CA813\r\r"
    static let speed010D = "7E903410D00\r7E803410D00\r\r"
    static let speedFunctionalSuffix010D1 = "7E903410D00\r\r"
    static let speedRPM010D0C = "7E906410D000C0000\r7E806410D000C0000\r\r"
    static let udsSpeed22F40D = "NO DATA\r\r"

    // Block 2: physical addressing to the engine ECU (7E0), engine idling.
    static let atsh7E0 = "OK\r\r"
    static let speedPhysicalSuffix010D1 = "7E803410D00\r\r"
    static let speedRPMPhysicalSuffix010D0C1 = "7E806410D000C0A5C\r\r"
    static let atrvIdling = "11.8V\r\r"

    /// Every transcript, with the command that produced it.
    static let all: [(command: String, reply: String)] = [
        ("ATI", ati), ("ATRV", atrvEngineOff), ("ATDPN", atdpn), ("ATH1", ath1),
        ("0100", supportedPIDs0100), ("010D", speed010D), ("010D1", speedFunctionalSuffix010D1),
        ("010D0C", speedRPM010D0C), ("22F40D", udsSpeed22F40D),
        ("ATSH7E0", atsh7E0), ("010D1", speedPhysicalSuffix010D1), ("010D0C1", speedRPMPhysicalSuffix010D0C1),
        ("ATRV", atrvIdling),
    ]
}

@Suite("Bench transcript 2026-10-07: AT replies")
struct BenchATReplyTests {
    typealias T = BenchTranscript

    @Test("ATI → banner ELM327 v2.3 (also as an ATZ banner)")
    func banner() throws {
        #expect(try ELM327ResponseParser.textReply(to: "ATI", raw: T.ati) == .banner("ELM327 v2.3"))
        #expect(try ELM327ResponseParser.textReply(to: "ATZ", raw: T.ati) == .banner("ELM327 v2.3"))
    }

    @Test("ATDPN → 6 (ISO 15765-4 CAN, 11-bit, 500 kbaud), no A prefix")
    func protocolNumber() throws {
        #expect(try ELM327ResponseParser.textReply(to: "ATDPN", raw: T.atdpn) == .protocolNumber("6"))
    }

    @Test("ATRV → 11.0 V engine off, 11.8 V idling")
    func voltage() throws {
        #expect(try ELM327ResponseParser.textReply(to: "ATRV", raw: T.atrvEngineOff) == .voltage(11.0))
        #expect(try ELM327ResponseParser.textReply(to: "ATRV", raw: T.atrvIdling) == .voltage(11.8))
    }

    @Test("ATH1 and ATSH7E0 → OK")
    func acknowledgements() throws {
        #expect(try ELM327ResponseParser.textReply(to: "ATH1", raw: T.ath1) == .ok)
        #expect(try ELM327ResponseParser.textReply(to: "ATSH7E0", raw: T.atsh7E0) == .ok)
    }

    @Test("None of the AT replies looks like data, a banner where it shouldn't, or a voltage where it shouldn't")
    func shapes() {
        #expect(ELMSession.isBannerCandidate("ELM327 v2.3", command: "ATZ"))
        #expect(!ELMSession.isBannerCandidate(T.atdpn, command: "ATZ"))
        #expect(!ELMSession.isBannerCandidate(T.atsh7E0, command: "ATZ"))
        #expect(!ELMSession.isBannerCandidate(T.atrvEngineOff, command: "ATZ"))
        #expect(ELMSession.isVoltageReply(T.atrvEngineOff))
        #expect(ELMSession.isVoltageReply(T.atrvIdling))
        #expect(!ELMSession.isVoltageReply(T.atdpn))
    }
}

@Suite("Bench transcript 2026-10-07: mode 01 replies")
struct BenchMode01ReplyTests {
    typealias T = BenchTranscript

    func parse(_ raw: String) throws -> [ECUReply] {
        try ELM327ResponseParser.replies(in: raw, headers: true)
    }

    /// 7E8's reply, the one the logger takes speed from.
    func primary(_ raw: String) throws -> ECUReply {
        try #require(try parse(raw).first { $0.isFromPrimaryECU })
    }

    @Test("0100: two ECUs, 7E9 first; both bitmasks as in the Decoded table")
    func supportedPIDs() throws {
        let replies = try parse(T.supportedPIDs0100)
        #expect(replies == [
            ECUReply(header: "7E9", bytes: [0x41, 0x00, 0x98, 0x18, 0x00, 0x01]),
            ECUReply(header: "7E8", bytes: [0x41, 0x00, 0xBE, 0x1C, 0xA8, 0x13]),
        ])
        // Engine: 01, 03-07, 0C, 0D, 0E, 11, 13, 15, 1C, 1F, 20.
        #expect(try OBDDecoder.supportedPIDs(bytes: replies[1].bytes) == [
            0x01, 0x03, 0x04, 0x05, 0x06, 0x07, 0x0C, 0x0D, 0x0E, 0x11, 0x13, 0x15, 0x1C, 0x1F, 0x20,
        ])
        // Second ECU: 01, 04, 05, 0C, 0D, 20.
        #expect(try OBDDecoder.supportedPIDs(bytes: replies[0].bytes) == [0x01, 0x04, 0x05, 0x0C, 0x0D, 0x20])
        #expect(try primary(T.supportedPIDs0100).header == "7E8")
    }

    @Test("010D under functional addressing: both ECUs, speed 0; 7E8's is the primary")
    func speedTwoECUs() throws {
        let replies = try parse(T.speed010D)
        #expect(replies.map(\.header) == ["7E9", "7E8"])
        for reply in replies {
            #expect(try OBDDecoder.decode(requested: [.vehicleSpeed], bytes: reply.bytes) == [
                OBDMeasurement(pid: .vehicleSpeed, value: 0, unit: .kilometersPerHour),
            ])
        }
        let engine = try primary(T.speed010D)
        #expect(engine.header == "7E8")
        #expect(engine.bytes == [0x41, 0x0D, 0x00])
    }

    @Test("010D1 under functional addressing: only 7E9 answers, so there is no engine reply at all")
    func functionalSuffixIsWrongECU() throws {
        let replies = try parse(T.speedFunctionalSuffix010D1)
        #expect(replies == [ECUReply(header: "7E9", bytes: [0x41, 0x0D, 0x00])])
        #expect(!replies.contains { $0.isFromPrimaryECU })
    }

    @Test("010D0C under functional addressing: both ECUs, speed 0 and RPM 0 each")
    func speedRPMTwoECUs() throws {
        let replies = try parse(T.speedRPM010D0C)
        #expect(replies.map(\.header) == ["7E9", "7E8"])
        for reply in replies {
            #expect(try OBDDecoder.decode(requested: [.vehicleSpeed, .engineSpeed], bytes: reply.bytes) == [
                OBDMeasurement(pid: .vehicleSpeed, value: 0, unit: .kilometersPerHour),
                OBDMeasurement(pid: .engineSpeed, value: 0, unit: .revolutionsPerMinute),
            ])
        }
        #expect(try primary(T.speedRPM010D0C).header == "7E8")
    }

    @Test("010D1 after ATSH7E0: 7E8 only, speed 0")
    func physicalSuffixSpeed() throws {
        #expect(try parse(T.speedPhysicalSuffix010D1) == [ECUReply(header: "7E8", bytes: [0x41, 0x0D, 0x00])])
        #expect(try OBDDecoder.decode(pid: .vehicleSpeed, payload: [0x00]).value == 0)
    }

    @Test("010D0C1 after ATSH7E0: speed 0 km/h, RPM (0x0A·256 + 0x5C)/4 = 663")
    func physicalSuffixSpeedRPM() throws {
        let replies = try parse(T.speedRPMPhysicalSuffix010D0C1)
        #expect(replies == [ECUReply(header: "7E8", bytes: [0x41, 0x0D, 0x00, 0x0C, 0x0A, 0x5C])])
        #expect(try OBDDecoder.decode(requested: [.vehicleSpeed, .engineSpeed], bytes: replies[0].bytes) == [
            OBDMeasurement(pid: .vehicleSpeed, value: 0, unit: .kilometersPerHour),
            OBDMeasurement(pid: .engineSpeed, value: 663, unit: .revolutionsPerMinute),
        ])
    }

    @Test("22F40D → NO DATA, a status, never data")
    func udsNoData() {
        #expect(throws: ELM327Error.noData) { try parse(T.udsSpeed22F40D) }
        #expect(throws: ELM327Error.noData) { try OBDDecoder.decode(pid: .vehicleSpeed, raw: T.udsSpeed22F40D) }
        #expect(ELMSession.classify(T.udsSpeed22F40D, wire: "010D", headers: true) == .noData)
    }

    @Test("Every mode 01 transcript survives 20-byte BLE fragmentation unchanged", arguments: [
        BenchTranscript.supportedPIDs0100, BenchTranscript.speed010D, BenchTranscript.speedFunctionalSuffix010D1,
        BenchTranscript.speedRPM010D0C, BenchTranscript.speedPhysicalSuffix010D1,
        BenchTranscript.speedRPMPhysicalSuffix010D0C1,
    ])
    func fragmented(raw: String) throws {
        var framer = ELMFramer()
        let bytes = Array((raw + ">").utf8)
        var replies: [ELMRawReply] = []
        for start in stride(from: 0, to: bytes.count, by: 20) {
            let chunk = Data(bytes[start..<min(start + 20, bytes.count)])
            replies += framer.append(ELMChunk(bytes: chunk, uptime: 1_000))
        }
        #expect(replies.map(\.text) == [raw])
        #expect(try parse(replies[0].text) == parse(raw))
    }
}

/// When both ECUs answer, speed comes from 7E8 — whichever line comes first.
@Suite("Bench transcript 2026-10-07: speed is 7E8's")
struct BenchPrimaryECUTests {
    func primarySpeed(_ raw: String) throws -> Double {
        let replies = try ELM327ResponseParser.replies(in: raw, headers: true)
        let engine = try #require(replies.first { $0.isFromPrimaryECU })
        let values = try OBDDecoder.decode(requested: [.vehicleSpeed, .engineSpeed], bytes: engine.bytes)
        return try #require(values.first { $0.pid == .vehicleSpeed }).value
    }

    @Test("Verbatim: both report 0, the chosen reading is 7E8's")
    func verbatim() throws {
        #expect(try primarySpeed(BenchTranscript.speed010D) == 0)
        #expect(try primarySpeed(BenchTranscript.speedRPM010D0C) == 0)
    }

    // Synthetic: the bench car's ECUs agreed (parked). These don't, so
    // taking the wrong line would show.
    @Test("Synthetic: 7E9 first with 0, 7E8 second with 60 km/h → 60", arguments: [
        "7E903410D00\r7E803410D3C\r\r",
        "7E906410D000C0000\r7E806410D3C0C0A5C\r\r",
    ])
    func engineSecond(raw: String) throws {
        #expect(try primarySpeed(raw) == 60)
    }

    @Test("Synthetic: 7E8 first with 60 km/h, 7E9 second with 0 → 60", arguments: [
        "7E803410D3C\r7E903410D00\r\r",
        "7E806410D3C0C0A5C\r7E906410D000C0000\r\r",
    ])
    func engineFirst(raw: String) throws {
        #expect(try primarySpeed(raw) == 60)
    }

    @Test("Only 7E8 and 18DAF110 are primary; headers-off replies can't be attributed and count as primary")
    func primaryHeaders() {
        #expect(ECUReply(header: "7E8", bytes: []).isFromPrimaryECU)
        #expect(ECUReply(header: "18DAF110", bytes: []).isFromPrimaryECU)
        #expect(!ECUReply(header: "7E9", bytes: []).isFromPrimaryECU)
        #expect(ECUReply(header: nil, bytes: []).isFromPrimaryECU)
    }
}

@Suite("OBDDecoder supported-PID bitmask")
struct OBDSupportedPIDTests {
    @Test("Bit 7 of A is base+1, bit 0 of D is base+32")
    func bitOrder() throws {
        #expect(try OBDDecoder.supportedPIDs(bytes: [0x41, 0x00, 0x80, 0x00, 0x00, 0x01]) == [0x01, 0x20])
        #expect(try OBDDecoder.supportedPIDs(bytes: [0x41, 0x20, 0x80, 0x00, 0x00, 0x00]) == [0x21])
        #expect(try OBDDecoder.supportedPIDs(bytes: [0x41, 0x00, 0x00, 0x00, 0x00, 0x00]) == [])
    }

    @Test("Padding after the four bitmask bytes is ignored")
    func padding() throws {
        #expect(try OBDDecoder.supportedPIDs(bytes: [0x41, 0x00, 0x80, 0x00, 0x00, 0x01, 0xAA, 0xAA]) == [0x01, 0x20])
    }

    @Test("Not a supported-PID reply is an error", arguments: [
        [0x41, 0x00, 0xBE, 0x1C, 0xA8] as [UInt8],  // short
        [0x41, 0x0D, 0x00, 0x00, 0x00, 0x00],        // PID 0D is not a bitmask PID
        [0x41, 0x10, 0x00, 0x00, 0x00, 0x00],        // nor is 10
        [0x7F, 0x01, 0x12, 0x00, 0x00, 0x00],        // negative response
        [0x41],
    ])
    func rejects(bytes: [UInt8]) {
        #expect(throws: ELM327Error.self) { try OBDDecoder.supportedPIDs(bytes: bytes) }
    }
}
