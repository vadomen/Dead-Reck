import DriveLoggerCore
import Foundation
import Observation

/// `OBDLinkServicing` over `MockELMAdapter` with the Touareg script, so the
/// simulator runs the full pipeline. Advertises one fake adapter named
/// "Simulated Vlink". Implemented in M2.
@MainActor
@Observable
final class SimulatedOBDLink: OBDLinkServicing {
    private(set) var state: OBDLinkState = .idle
    private(set) var discovered: [DiscoveredAdapter] = []
    private(set) var rememberedAdapterID: UUID?
    private(set) var adapter: AdapterRecord?
    private(set) var plan: PollingPlan?
    private(set) var pollHz: Double = 0
    private(set) var console: [ConsoleLine] = []

    init() {}

    func startScan() {
        fatalError("M2: SimulatedOBDLink.startScan")
    }

    func stopScan() {
        fatalError("M2: SimulatedOBDLink.stopScan")
    }

    func connect(to id: UUID) {
        fatalError("M2: SimulatedOBDLink.connect")
    }

    func disconnect() {
        fatalError("M2: SimulatedOBDLink.disconnect")
    }

    func forget() {
        fatalError("M2: SimulatedOBDLink.forget")
    }

    func sendManual(_ command: String) async throws(ELMSessionError) -> ELMExchange {
        fatalError("M2: SimulatedOBDLink.sendManual")
    }

    func sessionEvents() -> AsyncStream<ELMSessionEvent> {
        fatalError("M2: SimulatedOBDLink.sessionEvents")
    }
}
