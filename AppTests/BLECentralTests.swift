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

    // R3.2-2: a second connect for the same peripheral (the central's own
    // on poweredOn, racing the service's) used to call `connect` again on a
    // pending connection and restart discovery on a connected one, which
    // could lose the notify callback and leave the link `discovering`.
    @Test("connect: one CoreBluetooth connect and one discovery per connection, however often it is asked")
    func connectSteps() {
        #expect(BLECentral.connectStep(.disconnected, discovering: false) == .connect)
        #expect(BLECentral.connectStep(.disconnecting, discovering: false) == .connect)
        #expect(BLECentral.connectStep(.connecting, discovering: false) == .awaitConnect)
        #expect(BLECentral.connectStep(.connected, discovering: false) == .adopt, "restored or connected elsewhere")
        #expect(BLECentral.connectStep(.connected, discovering: true) == .joinDiscovery, "never a second discovery")
    }
}
