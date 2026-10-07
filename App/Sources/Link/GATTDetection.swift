import DriveLoggerCore
import Foundation

/// The UART characteristic pair picked from a discovered GATT table.
///
/// Pure value logic, no CoreBluetooth: `BLECentral` turns the discovered
/// services into `[GATTServiceRecord]` (the same records that go into the
/// log header), asks `GATTDetection.select(from:)` which pair to use, and
/// looks the characteristics up again by UUID.
struct GATTChoice: Hashable, Sendable {
    enum WriteType: String, Hashable, Sendable {
        case withResponse
        case withoutResponse
    }

    /// Normalised UUID strings (`GATTDetection.normalise`).
    var service: String
    var notify: String
    var write: String
    var writeType: WriteType
    /// Which rule matched: `vgate`, `fff0`, `ffe0` or `generic`. For the
    /// console; the log records the UUIDs themselves.
    var layout: String
}

/// GATT auto-detection per docs/SPEC_V1.md "BLE" and the `elm327-protocol`
/// skill. Never hard-codes one layout; known ones are only preferred:
/// 1. Vgate: service `E7810A71-…`, characteristic `BEF8D6C9-…` (notify +
///    write on one characteristic).
/// 2. `FFF0`: `FFF1` notify, `FFF2` write.
/// 3. `FFE0`: `FFE1` notify + write.
/// 4. Otherwise the first non-standard service with a notify/indicate and a
///    write/writeWithoutResponse characteristic, preferring one
///    characteristic that does both.
///
/// Write type: `withResponse` when the characteristic allows it, else
/// `withoutResponse`. Acknowledged writes surface errors; at one short
/// command in flight their extra radio round trip doesn't delay the adapter.
/// Which one the Vgate clone actually offers is a field check (PLAN §6).
enum GATTDetection {
    static let vgateService = "E7810A71-73AE-499D-8C15-FAA9AEF0C3F2"
    static let vgateCharacteristic = "BEF8D6C9-9C21-4C9E-B632-BD58C1009F9F"

    /// Known layouts in order of preference: (layout, service, notify, write).
    static let knownLayouts: [(layout: String, service: String, notify: String, write: String)] = [
        ("vgate", vgateService, vgateCharacteristic, vgateCharacteristic),
        ("fff0", "FFF0", "FFF1", "FFF2"),
        ("ffe0", "FFE0", "FFE1", "FFE1"),
    ]

    /// Bluetooth SIG services that are never an ELM327 UART: GAP, GATT,
    /// Device Information, Battery, Current Time, Tx Power, Immediate Alert,
    /// Link Loss, Heart Rate, HID.
    static let standardServices: Set<String> = [
        "1800", "1801", "180A", "180F", "1805", "1804", "1802", "1803", "180D", "1812",
    ]

    static let notifyProperties: Set<String> = ["notify", "indicate"]
    static let writeProperties: Set<String> = ["write", "writeWithoutResponse"]

    /// The Bluetooth base UUID suffix: a 128-bit UUID ending in it is the
    /// 16-bit UUID in characters 4–7.
    private static let baseSuffix = "-0000-1000-8000-00805F9B34FB"

    /// Uppercased; a base-UUID form (`0000FFF0-0000-1000-8000-00805F9B34FB`)
    /// is shortened to its 16-bit form (`FFF0`), which is how CoreBluetooth
    /// prints 16-bit UUIDs.
    static func normalise(_ uuid: String) -> String {
        let upper = uuid.uppercased()
        if upper.count == 36, upper.hasPrefix("0000"), upper.hasSuffix(baseSuffix) {
            let start = upper.index(upper.startIndex, offsetBy: 4)
            let end = upper.index(start, offsetBy: 4)
            return String(upper[start..<end])
        }
        return upper
    }

    static func select(from table: [GATTServiceRecord]) -> GATTChoice? {
        let services = table.map { record in
            (
                uuid: normalise(record.service),
                characteristics: record.characteristics.map { (uuid: normalise($0.uuid), properties: Set($0.properties)) }
            )
        }
        func properties(_ characteristic: String, in service: String) -> Set<String>? {
            services.first { $0.uuid == service }?.characteristics.first { $0.uuid == characteristic }?.properties
        }

        for known in knownLayouts {
            guard let notify = properties(known.notify, in: known.service),
                  let write = properties(known.write, in: known.service),
                  !notify.isDisjoint(with: notifyProperties),
                  let writeType = writeType(for: write) else { continue }
            return GATTChoice(
                service: known.service, notify: known.notify, write: known.write, writeType: writeType, layout: known.layout
            )
        }

        for service in services where !standardServices.contains(service.uuid) {
            let notifiers = service.characteristics.filter { !$0.properties.isDisjoint(with: notifyProperties) }
            let writers = service.characteristics.filter { writeType(for: $0.properties) != nil }
            if let both = notifiers.first(where: { candidate in writers.contains { $0.uuid == candidate.uuid } }),
               let writeType = writeType(for: both.properties) {
                return GATTChoice(service: service.uuid, notify: both.uuid, write: both.uuid, writeType: writeType, layout: "generic")
            }
            if let notify = notifiers.first, let write = writers.first, let writeType = writeType(for: write.properties) {
                return GATTChoice(service: service.uuid, notify: notify.uuid, write: write.uuid, writeType: writeType, layout: "generic")
            }
        }
        return nil
    }

    static func writeType(for properties: Set<String>) -> GATTChoice.WriteType? {
        if properties.contains("write") { return .withResponse }
        if properties.contains("writeWithoutResponse") { return .withoutResponse }
        return nil
    }
}

/// Splits one command's bytes into writes no longer than the link allows.
enum BLEWriteSplitter {
    /// `data` in order, in pieces of at most `maxLength` bytes (at least 1).
    /// Empty data yields no writes.
    static func chunks(of data: Data, maxLength: Int) -> [Data] {
        let size = max(1, maxLength)
        var chunks: [Data] = []
        var index = data.startIndex
        while index < data.endIndex {
            let end = data.index(index, offsetBy: size, limitedBy: data.endIndex) ?? data.endIndex
            chunks.append(Data(data[index..<end]))
            index = end
        }
        return chunks
    }
}
