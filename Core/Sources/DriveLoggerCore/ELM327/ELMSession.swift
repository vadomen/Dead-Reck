import Foundation

// Contract for the ELM327 session: init, probing, polling state machine.
// Stubs: implemented in M1 by the ELM layer (docs/PLAN.md §4.2).

/// Failures surfaced by `ELMSession`.
public enum ELMSessionError: Error, Hashable, Sendable {
    /// Blocked by `ELMCommandPolicy`; nothing was sent.
    case forbiddenCommand(String)
    /// The operation needs a completed `initialise()`.
    case notInitialised
    /// No `>` prompt within the command's timeout.
    case timeout(command: String)
    /// An init step failed; `step` is the command that failed.
    case initFailed(step: String, reason: String)
    case transport(ELMTransportError)
    case adapter(ELM327Error)
    /// The session was shut down while the operation was pending.
    case cancelled
}

/// Named states of the session's state machine. Raw values are written into
/// `link` rows: rename the case if you like, never the string.
public enum ELMState: String, Hashable, Sendable, CaseIterable {
    /// No transport traffic yet, or after `shutdown()`.
    case idle
    /// `ATZ` sent, waiting for the banner.
    case resetting
    /// Running the AT part of the init sequence.
    case initialising
    /// `0100` sent after `ATSP0`; the adapter is searching for a protocol.
    case searching
    /// Trying multi-PID, the response-count suffix and adaptive timing.
    case probing
    /// Initialised, not polling.
    case ready
    case polling
    /// A poll failed; retrying the same command.
    case retrying
    /// Too many consecutive failures; re-running the init sequence.
    case reinitialising
    /// Re-init failed too; the BLE link needs reconnecting.
    case failed
}

/// Why an exchange was sent. Raw values are on-disk strings (`elm.phase`).
public enum ELMPhase: String, Hashable, Sendable, CaseIterable {
    case initialisation = "init"
    case probe
    case poll
    case manual
    case keepalive
}

/// How an exchange ended. Raw values are on-disk strings (`elm.outcome`).
public enum ELMOutcome: String, Hashable, Sendable, CaseIterable {
    case ok
    case noData
    case timeout
    case stopped
    case notRecognised
    case canError
    case busError
    case busInitError
    case bufferFull
    case dataError
    case unableToConnect
    case adapterError
    /// A reply arrived but could not be parsed.
    case malformed
    /// Blocked by `ELMCommandPolicy`; never left the phone.
    case rejected
}

/// One command and its reply, verbatim, with both timestamps. Becomes an
/// `elm` row.
public struct ELMExchange: Hashable, Sendable {
    /// Unique per session, increasing.
    public var seq: Int
    public var phase: ELMPhase
    /// Command as written, without the carriage return.
    public var tx: String
    /// Uptime when the write was issued (`ELMTransport.send`).
    public var requestUptime: Double
    /// Reply minus the prompt; nil on timeout or rejection.
    public var rx: String?
    /// Uptime when the reply completed, or when the timeout fired.
    public var completedUptime: Double
    public var outcome: ELMOutcome

    public init(
        seq: Int,
        phase: ELMPhase,
        tx: String,
        requestUptime: Double,
        rx: String?,
        completedUptime: Double,
        outcome: ELMOutcome
    ) {
        self.seq = seq
        self.phase = phase
        self.tx = tx
        self.requestUptime = requestUptime
        self.rx = rx
        self.completedUptime = completedUptime
        self.outcome = outcome
    }
}

/// One decoded value from one ECU in a successful poll. Becomes an `obd` row.
/// A multi-PID reply from two ECUs yields up to four of these, all sharing
/// `seq`, `raw` and both timestamps.
public struct OBDReading: Hashable, Sendable {
    public var seq: Int
    public var command: String
    /// CAN header of the answering ECU (`7E8`); nil with headers off.
    public var ecu: String?
    public var measurement: OBDMeasurement
    /// The full reply the value was decoded from.
    public var raw: String
    public var requestUptime: Double
    public var replyUptime: Double

    public init(
        seq: Int,
        command: String,
        ecu: String?,
        measurement: OBDMeasurement,
        raw: String,
        requestUptime: Double,
        replyUptime: Double
    ) {
        self.seq = seq
        self.command = command
        self.ecu = ecu
        self.measurement = measurement
        self.raw = raw
        self.requestUptime = requestUptime
        self.replyUptime = replyUptime
    }
}

/// The polling combination: what to send each cycle.
public struct PollingPlan: Hashable, Sendable {
    /// PIDs combined into one request when `multiPID`, else polled singly with
    /// the first every cycle and the rest every `rpmEvery`th cycle.
    public var pids: [OBDPID]
    public var multiPID: Bool
    /// Response-count suffix, e.g. `1` → `010D1`. Nil when unsupported.
    public var responseCount: Int?
    /// `ATAT` level: 0, 1 or 2.
    public var adaptiveTiming: Int
    public var rpmEvery: Int
    public var timeout: Duration

    public init(
        pids: [OBDPID],
        multiPID: Bool,
        responseCount: Int?,
        adaptiveTiming: Int,
        rpmEvery: Int,
        timeout: Duration
    ) {
        self.pids = pids
        self.multiPID = multiPID
        self.responseCount = responseCount
        self.adaptiveTiming = adaptiveTiming
        self.rpmEvery = rpmEvery
        self.timeout = timeout
    }

    /// Conservative fallback that every ELM327 clone accepts: `010D` every
    /// cycle, `010C` every 5th, adaptive timing 1, no suffix.
    public static let baseline = PollingPlan(
        pids: [.vehicleSpeed, .engineSpeed],
        multiPID: false,
        responseCount: nil,
        adaptiveTiming: 1,
        rpmEvery: 5,
        timeout: .seconds(1)
    )

    /// The command sent on a cycle where every PID is due, e.g. `010D0C1`.
    public var primaryCommand: String {
        fatalError("M1: PollingPlan.primaryCommand")
    }
}

/// What `initialise()` found.
public struct ELMAdapterInfo: Hashable, Sendable {
    /// `ATZ` banner, e.g. `ELM327 v2.1`.
    public var elmVersion: String
    /// Raw `ATDPN` reply, e.g. `A6`.
    public var protocolNumber: String
    /// Parsed `ATRV`, volts.
    public var voltage: Double?
    /// Raw `0100` reply (supported-PID bitmask), recorded as-is.
    public var supportedPIDs: String?
    /// The fastest combination that parsed correctly during probing.
    public var plan: PollingPlan

    public init(
        elmVersion: String,
        protocolNumber: String,
        voltage: Double?,
        supportedPIDs: String?,
        plan: PollingPlan
    ) {
        self.elmVersion = elmVersion
        self.protocolNumber = protocolNumber
        self.voltage = voltage
        self.supportedPIDs = supportedPIDs
        self.plan = plan
    }
}

/// Timeouts and escalation thresholds.
public struct ELMSessionConfiguration: Hashable, Sendable {
    /// Default per-command timeout.
    public var commandTimeout: Duration
    /// `ATZ` banner wait.
    public var resetTimeout: Duration
    /// The first `0100` after `ATSP0`, while the adapter searches protocols.
    public var searchTimeout: Duration
    /// Consecutive poll failures before re-initialising.
    public var failuresBeforeReinit: Int
    /// Consecutive failed re-inits before asking for a BLE reconnect.
    public var reinitsBeforeReconnect: Int
    /// Whether `initialise()` probes faster combinations or uses `.baseline`.
    public var probe: Bool
    /// How often `pollRate` events are emitted.
    public var rateWindow: Duration

    public init(
        commandTimeout: Duration = .seconds(1),
        resetTimeout: Duration = .seconds(3),
        searchTimeout: Duration = .seconds(10),
        failuresBeforeReinit: Int = 3,
        reinitsBeforeReconnect: Int = 2,
        probe: Bool = true,
        rateWindow: Duration = .seconds(10)
    ) {
        self.commandTimeout = commandTimeout
        self.resetTimeout = resetTimeout
        self.searchTimeout = searchTimeout
        self.failuresBeforeReinit = failuresBeforeReinit
        self.reinitsBeforeReconnect = reinitsBeforeReconnect
        self.probe = probe
        self.rateWindow = rateWindow
    }

    public static let `default` = ELMSessionConfiguration()
}

/// Everything the session reports, on one stream.
public enum ELMSessionEvent: Hashable, Sendable {
    case state(from: ELMState, to: ELMState, reason: String?)
    case exchange(ELMExchange)
    case reading(OBDReading)
    case adapter(ELMAdapterInfo)
    /// Successful polls per second over the last `rateWindow`.
    case pollRate(hz: Double)
    /// Re-init failed `reinitsBeforeReconnect` times; the owner should drop
    /// and reconnect the transport.
    case needsReconnect
}

/// Talks to one adapter over one transport: init, probing, polling.
///
/// Exactly one command is in flight at any time. Every command — init, probe,
/// poll and manual — passes `ELMCommandPolicy` first. Every exchange and every
/// state transition is emitted on `events`.
///
/// Timestamps are uptimes, not session timestamps, so the link can initialise
/// before a recording (and its `SessionClock`) exists. The recorder converts
/// with `clock.timestamp(uptimeSeconds:)`, which shares the base of
/// `clock.now()`.
public actor ELMSession {
    /// Single consumer. Finishes after `shutdown()` or when the transport's
    /// stream finishes.
    public nonisolated let events: AsyncStream<ELMSessionEvent>

    private let transport: any ELMTransport
    private let configuration: ELMSessionConfiguration
    private let clock: any Clock<Duration>
    private let continuation: AsyncStream<ELMSessionEvent>.Continuation

    /// - Parameter clock: drives timeouts and the poll-rate window; inject a
    ///   test clock to run the state machine without real waits.
    public init(
        transport: any ELMTransport,
        configuration: ELMSessionConfiguration = .default,
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.transport = transport
        self.configuration = configuration
        self.clock = clock
        (events, continuation) = AsyncStream.makeStream(of: ELMSessionEvent.self)
    }

    public private(set) var state: ELMState = .idle

    /// `ATZ` → `ATE0` → `ATL0` → `ATS0` → `ATH1` → `ATSP0` → `0100` → `ATDPN`
    /// → `ATRV`, then (if configured) probes multi-PID, the response-count
    /// suffix and `ATAT2`, keeping the fastest combination that parses.
    public func initialise() async throws(ELMSessionError) -> ELMAdapterInfo {
        fatalError("M1: ELMSession.initialise")
    }

    /// Starts the poll loop. Requires `ready`.
    public func startPolling(_ plan: PollingPlan) throws(ELMSessionError) {
        fatalError("M1: ELMSession.startPolling")
    }

    /// Stops after the in-flight command completes; returns to `ready`.
    public func stopPolling() async {
        fatalError("M1: ELMSession.stopPolling")
    }

    /// Debug console. Guarded by `ELMCommandPolicy`; while polling, queued
    /// between polls so only one command is ever in flight. A rejected command
    /// still produces an exchange with outcome `rejected`.
    public func sendManual(_ command: String) async throws(ELMSessionError) -> ELMExchange {
        fatalError("M1: ELMSession.sendManual")
    }

    /// Stops polling, finishes `events`.
    public func shutdown() async {
        fatalError("M1: ELMSession.shutdown")
    }
}
