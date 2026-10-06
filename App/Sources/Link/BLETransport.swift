import CoreBluetooth
import DriveLoggerCore
import Foundation

/// `ELMTransport` over a connected BLE peripheral's UART characteristic pair.
///
/// Owned by `OBDLinkService`, which does scanning, connection, GATT discovery
/// and pair selection (preferred layouts in docs/SPEC_V1.md "BLE"), then hands
/// the chosen characteristics to this type. Responsibilities here:
/// - stamp every notification with uptime inside the delegate callback;
/// - split writes to `maximumWriteValueLength(for:)`;
/// - finish `incoming` when the peripheral disconnects.
///
/// Implemented in M2.
final class BLETransport: ELMTransport {
    let incoming: AsyncStream<ELMChunk>

    /// The selection that will be recorded in the header.
    let selection: GATTSelection

    init(selection: GATTSelection, uptime: any UptimeSource = SystemUptimeSource()) {
        fatalError("M2: BLETransport.init")
    }

    func send(_ data: Data) async throws -> Double {
        fatalError("M2: BLETransport.send")
    }
}
