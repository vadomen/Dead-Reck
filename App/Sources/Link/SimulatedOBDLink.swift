import DriveLoggerCore
import Foundation
import Observation

/// `OBDLinkServicing` over `MockELMAdapter` with the bench-car script
/// (`Rule.benchCar`: the Touareg + Vgate transcript of 2026-10-07), so the
/// simulator runs the full pipeline. Chosen automatically on the simulator
/// (`OBDLinkFactory`).
///
/// It is `OBDLinkService` itself — same state machine, sessions, reconnects,
/// console and `linkEvents()` — over `SimulatedBLECentral` instead of
/// CoreBluetooth. It advertises one fake adapter named "Simulated Vlink",
/// whose recorded GATT selection is the Vgate layout with a 20-byte write
/// length. Speed is 0 km/h and RPM 663, as on the bench.
@MainActor
final class SimulatedOBDLink: OBDLinkService {
    let simulatedCentral: SimulatedBLECentral

    /// - Parameters:
    ///   - rules: the adapter script; each connection gets a fresh adapter.
    ///   - defaults: nil = a private, empty store (the simulated adapter's
    ///     identifier never lands in the real app's defaults by accident).
    ///   - latency: simulated scan and connect delays.
    init(
        rules: [MockELMAdapter.Rule] = MockELMAdapter.Rule.benchCar,
        defaults: UserDefaults? = nil,
        uptime: any UptimeSource = SystemUptimeSource(),
        sessionConfiguration: ELMSessionConfiguration = .default,
        backoff: ReconnectBackoff = .default,
        latency: Duration = .milliseconds(200)
    ) {
        let central = SimulatedBLECentral(rules: rules, uptime: uptime, latency: latency)
        simulatedCentral = central
        super.init(
            central: central,
            defaults: defaults ?? UserDefaults(suiteName: "DriveLogger.SimulatedOBDLink") ?? .standard,
            uptime: uptime,
            sessionConfiguration: sessionConfiguration,
            backoff: backoff
        )
    }

    /// The adapter disappears, as if unplugged: the link drops and the
    /// service reconnects to a fresh simulated adapter. For tests and demos.
    func simulateLinkLoss() async {
        await simulatedCentral.simulateLinkLoss()
    }
}

/// `BLECentralClient` with one simulated adapter behind a `MockELMAdapter`.
/// Bluetooth is always on. `connect` "connects" after `latency` and hands
/// over a new `MockELMAdapter` as the transport.
final class SimulatedBLECentral: BLECentralClient {
    static let adapterID = UUID(uuidString: "5E1A7ED0-0B0D-4C1E-A5E5-00000000B00C")!
    static let adapterName = "Simulated Vlink"

    /// What a Vgate clone is expected to expose (docs/SPEC_V1.md "BLE",
    /// layout 1). Simulated: not a measurement.
    static let table = [
        GATTServiceRecord(service: "180A", characteristics: [GATTCharacteristicRecord(uuid: "2A29", properties: ["read"])]),
        GATTServiceRecord(
            service: GATTDetection.vgateService,
            characteristics: [GATTCharacteristicRecord(
                uuid: GATTDetection.vgateCharacteristic, properties: ["write", "writeWithoutResponse", "notify"]
            )]
        ),
    ]

    static var selection: GATTSelection {
        let choice = GATTDetection.select(from: table)!
        return GATTSelection(
            service: choice.service, notify: choice.notify, write: choice.write,
            writeType: choice.writeType.rawValue, maxWriteLength: 20
        )
    }

    let events: AsyncStream<BLECentralEvent>

    private let continuation: AsyncStream<BLECentralEvent>.Continuation
    private let rules: [MockELMAdapter.Rule]
    private let uptime: any UptimeSource
    private let latency: Duration
    private let lock = NSLock()
    // Guarded by `lock`. The adapter of the current connection.
    private nonisolated(unsafe) var adapter: MockELMAdapter?
    // Guarded by `lock`. Bumped by every connect and cancel, so a connect
    // still sleeping when it was cancelled does nothing.
    private nonisolated(unsafe) var generation = 0

    init(rules: [MockELMAdapter.Rule], uptime: any UptimeSource = SystemUptimeSource(), latency: Duration = .milliseconds(200)) {
        self.rules = rules
        self.uptime = uptime
        self.latency = latency
        (events, continuation) = AsyncStream.makeStream(of: BLECentralEvent.self)
        continuation.yield(.availability(.poweredOn, uptime: uptime.uptimeSeconds))
    }

    func startScan() {
        let latency = latency
        Task {
            try? await Task.sleep(for: latency)
            continuation.yield(.discovered(DiscoveredAdapter(id: Self.adapterID, name: Self.adapterName, rssi: -58)))
        }
    }

    func stopScan() {}

    func connect(_ id: UUID) {
        let now = uptime.uptimeSeconds
        guard id == Self.adapterID else {
            continuation.yield(.connectFailed(id, reason: "no such simulated adapter", uptime: now))
            return
        }
        let mine = lock.withLock { () -> Int in
            generation += 1
            return generation
        }
        let latency = latency
        Task {
            try? await Task.sleep(for: latency)
            guard lock.withLock({ generation == mine }) else { return }
            continuation.yield(.connected(id, uptime: uptime.uptimeSeconds))
            try? await Task.sleep(for: latency)
            let adapter = MockELMAdapter(rules: rules, uptime: uptime)
            let current = lock.withLock { () -> Bool in
                guard generation == mine else { return false }
                self.adapter = adapter
                return true
            }
            guard current else { return }
            let link = BLELinkReady(
                id: id, name: Self.adapterName, transport: adapter, selection: Self.selection, table: Self.table
            )
            continuation.yield(.ready(link, uptime: uptime.uptimeSeconds))
        }
    }

    func cancelConnection(_ id: UUID) {
        let adapter = lock.withLock { () -> MockELMAdapter? in
            generation += 1
            defer { self.adapter = nil }
            return self.adapter
        }
        guard let adapter else { return }
        Task {
            await adapter.disconnect()
            continuation.yield(.disconnected(id, reason: nil, uptime: uptime.uptimeSeconds))
        }
    }

    /// Drops the current connection as an unplugged adapter would: the
    /// transport finishes and `.disconnected` follows with a reason.
    func simulateLinkLoss() async {
        let adapter = lock.withLock { () -> MockELMAdapter? in
            defer { self.adapter = nil }
            return self.adapter
        }
        guard let adapter else { return }
        await adapter.disconnect()
        continuation.yield(.disconnected(Self.adapterID, reason: "simulated link loss", uptime: uptime.uptimeSeconds))
    }
}

/// Picks the link implementation for the platform: CoreBluetooth on a
/// device, `SimulatedOBDLink` on the simulator (which has no Bluetooth).
/// Create it once, at launch, so CoreBluetooth state restoration finds the
/// central (`OBDLinkService.restoreIdentifier`).
enum OBDLinkFactory {
    @MainActor
    static func makeDefault() -> any OBDLinkServicing {
        #if targetEnvironment(simulator)
        SimulatedOBDLink()
        #else
        OBDLinkService()
        #endif
    }
}
