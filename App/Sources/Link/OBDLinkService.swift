import CoreBluetooth
import DriveLoggerCore
import Foundation
import Observation

/// CoreBluetooth implementation of `OBDLinkServicing`.
///
/// Uses a restore identifier for state restoration, remembers the chosen
/// peripheral by identifier, reconnects with backoff after a drop or after the
/// ELM session asks for it, and re-runs init on every reconnect. Implemented
/// in M2.
@MainActor
@Observable
final class OBDLinkService: OBDLinkServicing {
    static let restoreIdentifier = "DriveLogger.OBDLink"

    private(set) var state: OBDLinkState = .idle
    private(set) var discovered: [DiscoveredAdapter] = []
    private(set) var rememberedAdapterID: UUID?
    private(set) var adapter: AdapterRecord?
    private(set) var plan: PollingPlan?
    private(set) var pollHz: Double = 0
    private(set) var console: [ConsoleLine] = []

    init() {}

    func startScan() {
        fatalError("M2: OBDLinkService.startScan")
    }

    func stopScan() {
        fatalError("M2: OBDLinkService.stopScan")
    }

    func connect(to id: UUID) {
        fatalError("M2: OBDLinkService.connect")
    }

    func disconnect() {
        fatalError("M2: OBDLinkService.disconnect")
    }

    func forget() {
        fatalError("M2: OBDLinkService.forget")
    }

    func sendManual(_ command: String) async throws(ELMSessionError) -> ELMExchange {
        fatalError("M2: OBDLinkService.sendManual")
    }

    func sessionEvents() -> AsyncStream<ELMSessionEvent> {
        fatalError("M2: OBDLinkService.sessionEvents")
    }
}
