import CoreBluetooth
import Testing

@testable import DriveLogger

// `BLECentral` itself needs a radio. What is tested here is its pure
// decision of which manager states invalidate the retained peripherals;
// that the reconnect after a real bluetoothd reset completes is in
// docs/PLAN.md §6.

@Suite("BLECentral")
struct BLECentralTests {
    // R3.1-2: a retained peripheral after a reset is stale and a connect on
    // it can hang for the rest of the drive.
    @Test("Peripherals are dropped below poweredOff (resetting, unknown, unauthorized, unsupported), kept on poweredOn/poweredOff")
    func invalidatingStates() {
        for state in [CBManagerState.resetting, .unknown, .unauthorized, .unsupported] {
            #expect(BLECentral.invalidatesPeripherals(state), "\(state.rawValue)")
        }
        #expect(!BLECentral.invalidatesPeripherals(.poweredOn))
        #expect(!BLECentral.invalidatesPeripherals(.poweredOff))
    }
}
