import CoreBluetooth
import Foundation
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

    // Prompt 49: a connect cancelled by the service's watchdog and issued
    // again at once must reach CoreBluetooth even if the peripheral still
    // reads `connecting`, or no connect would be pending at all.
    @Test("A cancelled pending connect is connected again even if the peripheral still reads connecting")
    func reissueAfterCancelledPending() {
        #expect(BLECentral.connectStep(.connecting, discovering: false, cancelledWhilePending: true) == .connect)
        #expect(BLECentral.connectStep(.connected, discovering: true, cancelledWhilePending: true) == .joinDiscovery)
        let id = UUID()
        var marks = BLEAttemptMarks()
        marks.connectRequested(generation: 1)
        marks.cancelRequested(id, state: .connecting)
        #expect(marks.reissuesConnect(id))
        marks.connectRequested(generation: 3)
        marks.connectIssued(id)
        #expect(!marks.reissuesConnect(id))
        // Nothing to cancel on a disconnected peripheral: no mark, no re-issue.
        var idle = BLEAttemptMarks()
        idle.cancelRequested(id, state: .disconnected)
        #expect(!idle.reissuesConnect(id))
        #expect(idle.disconnected(id) == .lost(generation: 0))
    }

    @Test("A disconnect callback after a cancel belongs to the cancelled attempt, not to the connect issued right after it")
    func lateCancelBelongsToItsAttempt() {
        let id = UUID()
        var marks = BLEAttemptMarks()
        marks.connectRequested(generation: 1)
        marks.cancelRequested(id, state: .connecting)
        marks.connectRequested(generation: 3)
        #expect(marks.failedToConnect(id) == 3, "a failure is always the latest attempt's")
        #expect(marks.disconnected(id) == .cancelled(generation: 1))
        #expect(marks.connected(id) == 3)
        #expect(marks.disconnected(id) == .lost(generation: 3), "the mark was taken once")
    }

    @Test("A cancel mark whose callback never came can't swallow the next connection's loss")
    func staleMarkClearedByNextConnection() {
        let id = UUID()
        var marks = BLEAttemptMarks()
        marks.connectRequested(generation: 1)
        marks.cancelRequested(id, state: .connecting)   // no didDisconnect ever comes for it
        marks.connectRequested(generation: 3)
        #expect(marks.connected(id) == 3)
        #expect(marks.disconnected(id) == .lost(generation: 3))

        // Cancelled while connected, then adopted before its callback: the
        // late disconnect ends the adopted link, so it is a loss.
        marks.connectRequested(generation: 5)
        _ = marks.connected(id)
        marks.cancelRequested(id, state: .connected)
        marks.connectRequested(generation: 7)
        #expect(marks.connected(id) == 7)
        #expect(marks.disconnected(id) == .lost(generation: 7))
    }

    @Test("Bluetooth going away clears every mark")
    func resetClearsMarks() {
        let id = UUID()
        var marks = BLEAttemptMarks()
        marks.connectRequested(generation: 2)
        marks.cancelRequested(id, state: .connected)
        marks.reset()
        #expect(marks.disconnected(id) == .lost(generation: 2))
        #expect(!marks.reissuesConnect(id))
    }
}
