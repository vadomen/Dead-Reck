import CoreBluetooth
import DriveLoggerCore
import Foundation
import Testing

@testable import DriveLogger

private func service(_ uuid: String, _ characteristics: [(String, [String])]) -> GATTServiceRecord {
    GATTServiceRecord(service: uuid, characteristics: characteristics.map { GATTCharacteristicRecord(uuid: $0.0, properties: $0.1) })
}

@Suite("GATT auto-detection")
struct GATTDetectionTests {
    static let deviceInfo = service("180A", [("2A29", ["read"]), ("2A24", ["read"])])

    @Test("Vgate layout: one characteristic for notify and write, preferred over FFF0/FFE0")
    func vgatePreferred() throws {
        let table = [
            Self.deviceInfo,
            service("FFF0", [("FFF1", ["notify"]), ("FFF2", ["write"])]),
            service(GATTDetection.vgateService, [(GATTDetection.vgateCharacteristic, ["write", "writeWithoutResponse", "notify"])]),
        ]
        let choice = try #require(GATTDetection.select(from: table))
        #expect(choice.layout == "vgate")
        #expect(choice.service == GATTDetection.vgateService)
        #expect(choice.notify == GATTDetection.vgateCharacteristic && choice.write == GATTDetection.vgateCharacteristic)
        #expect(choice.writeType == .withResponse, "acknowledged writes when offered")
    }

    @Test("Vgate UUIDs in lower case still match")
    func vgateLowercase() throws {
        let table = [service(GATTDetection.vgateService.lowercased(), [(GATTDetection.vgateCharacteristic.lowercased(), ["notify", "write"])])]
        #expect(try #require(GATTDetection.select(from: table)).layout == "vgate")
    }

    @Test("FFF0: FFF1 notify, FFF2 write without response")
    func fff0() throws {
        let table = [Self.deviceInfo, service("FFF0", [("FFF1", ["notify"]), ("FFF2", ["writeWithoutResponse"])])]
        let choice = try #require(GATTDetection.select(from: table))
        #expect(choice == GATTChoice(service: "FFF0", notify: "FFF1", write: "FFF2", writeType: .withoutResponse, layout: "fff0"))
    }

    @Test("FFE0: FFE1 notify + write, also when spelled as a 128-bit base UUID")
    func ffe0() throws {
        let table = [service("0000ffe0-0000-1000-8000-00805f9b34fb", [("0000FFE1-0000-1000-8000-00805F9B34FB", ["read", "notify", "writeWithoutResponse", "write"])])]
        let choice = try #require(GATTDetection.select(from: table))
        #expect(choice == GATTChoice(service: "FFE0", notify: "FFE1", write: "FFE1", writeType: .withResponse, layout: "ffe0"))
    }

    @Test("A known service missing its notify property falls through to the next layout")
    func knownButBroken() throws {
        let table = [
            service(GATTDetection.vgateService, [(GATTDetection.vgateCharacteristic, ["write"])]),
            service("FFE0", [("FFE1", ["notify", "write"])]),
        ]
        #expect(try #require(GATTDetection.select(from: table)).layout == "ffe0")
    }

    @Test("Unknown clone: the first non-standard service with notify + write, one characteristic preferred")
    func generic() throws {
        let table = [
            service("180F", [("2A19", ["read", "notify"])]),                     // battery: notify, but standard
            service("1234", [("AAA1", ["notify"]), ("AAA2", ["write"]), ("AAA3", ["notify", "writeWithoutResponse"])]),
        ]
        let choice = try #require(GATTDetection.select(from: table))
        #expect(choice == GATTChoice(service: "1234", notify: "AAA3", write: "AAA3", writeType: .withoutResponse, layout: "generic"))
    }

    @Test("Unknown clone with separate notify and write characteristics")
    func genericPair() throws {
        let table = [service("ABCD", [("0001", ["indicate"]), ("0002", ["write"])])]
        let choice = try #require(GATTDetection.select(from: table))
        #expect(choice == GATTChoice(service: "ABCD", notify: "0001", write: "0002", writeType: .withResponse, layout: "generic"))
    }

    @Test("No usable pair: nil", arguments: [
        [GATTServiceRecord](),
        [GATTDetectionTests.deviceInfo],
        [service("1234", [("AAA1", ["notify"])])],
        [service("1234", [("AAA1", ["write"])])],
        [service("180F", [("2A19", ["notify", "write"])])],
    ])
    func none(table: [GATTServiceRecord]) {
        #expect(GATTDetection.select(from: table) == nil)
    }

    @Test("Normalisation: base UUIDs shorten to 16 bits, others are uppercased")
    func normalise() {
        #expect(GATTDetection.normalise("0000fff0-0000-1000-8000-00805f9b34fb") == "FFF0")
        #expect(GATTDetection.normalise("fff0") == "FFF0")
        #expect(GATTDetection.normalise("e7810a71-73ae-499d-8c15-faa9aef0c3f2") == GATTDetection.vgateService)
    }

    @Test("CoreBluetooth property names, as recorded in gattTable")
    func propertyNames() {
        let names = BLECentral.propertyNames([.read, .writeWithoutResponse, .write, .notify, .indicate])
        #expect(names == ["read", "writeWithoutResponse", "write", "notify", "indicate"])
        #expect(BLECentral.propertyNames([]) == [])
    }
}

@Suite("BLE write splitting")
struct BLEWriteSplitterTests {
    @Test("A command that fits goes out in one write")
    func fits() {
        let data = Data("010D0C1\r".utf8)
        #expect(BLEWriteSplitter.chunks(of: data, maxLength: 20) == [data])
    }

    @Test("Longer than the link allows: split in order, every piece within the limit")
    func splits() {
        let data = Data((0..<45).map { UInt8($0) })
        let chunks = BLEWriteSplitter.chunks(of: data, maxLength: 20)
        #expect(chunks.map(\.count) == [20, 20, 5])
        #expect(Data(chunks.joined()) == data)
    }

    @Test("Exact multiple, empty data, and a nonsensical limit")
    func edges() {
        #expect(BLEWriteSplitter.chunks(of: Data(count: 40), maxLength: 20).map(\.count) == [20, 20])
        #expect(BLEWriteSplitter.chunks(of: Data(), maxLength: 20).isEmpty)
        #expect(BLEWriteSplitter.chunks(of: Data("AT\r".utf8), maxLength: 0).map(\.count) == [1, 1, 1])
    }

    @Test("Works on a slice whose indices don't start at 0")
    func slice() {
        let whole = Data("xx010D\r".utf8)
        let slice = whole.dropFirst(2)
        #expect(BLEWriteSplitter.chunks(of: slice, maxLength: 3) == [Data("010".utf8), Data("D\r".utf8)])
    }
}

@Suite("Reconnect backoff and picker order")
struct ReconnectBackoffTests {
    @Test("1 s doubling, capped at 30 s")
    func schedule() {
        let backoff = ReconnectBackoff.default
        #expect((1...7).map { backoff.delay(forAttempt: $0) } == [1, 2, 4, 8, 16, 30, 30].map { Duration.seconds($0) })
        #expect(backoff.delay(forAttempt: 0) == .seconds(1))
        #expect(backoff.delay(forAttempt: 1_000) == .seconds(30))
    }

    @Test("Likely OBD adapters are listed before stronger unrelated peripherals")
    func pickerOrder() {
        let list = [
            DiscoveredAdapter(id: UUID(), name: "AirPods", rssi: -40),
            DiscoveredAdapter(id: UUID(), name: "IOS-Vlink", rssi: -70),
            DiscoveredAdapter(id: UUID(), name: "Watch", rssi: -50),
            DiscoveredAdapter(id: UUID(), name: "iCar Pro", rssi: -60),
        ].sorted(by: OBDLinkService.listOrder)
        #expect(list.map(\.name) == ["iCar Pro", "IOS-Vlink", "AirPods", "Watch"])
    }
}
