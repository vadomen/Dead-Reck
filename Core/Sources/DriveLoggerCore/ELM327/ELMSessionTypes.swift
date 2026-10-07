import Foundation

// Value types of the ELM327 session contract (docs/PLAN.md §4.2). The state
// machine itself is `ELMSession`, in ELMSession.swift.

/// Failures surfaced by `ELMSession`.
public enum ELMSessionError: Error, Hashable, Sendable {
    /// Blocked by `ELMCommandPolicy`; nothing was sent.
    case forbiddenCommand(String)
    /// The operation needs a completed `initialise()`.
    case notInitialised
    /// A `PollingPlan` field is out of range (`PollingPlan.validate()`);
    /// nothing was sent.
    case invalidPlan(String)
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
    /// Increasing across the whole recording, reconnects included: a new
    /// session continues from the previous one's `nextSeq` (see
    /// `ELMSession.init(firstSeq:)`).
    public var seq: Int
    public var phase: ELMPhase
    /// Command as sent, without the carriage return: printable ASCII,
    /// uppercased (`ValidatedELMCommand.wire`). For a `rejected` exchange,
    /// which never left the phone: the input as typed (manual), or the
    /// command's `wireFormat` (session-originated).
    public var tx: String
    /// Uptime when the write was issued (`ELMTransport.send`). For a
    /// `rejected` exchange, which is never sent, the session's uptime at the
    /// moment of rejection.
    public var requestUptime: Double
    /// Reply minus the prompt; nil on timeout or rejection.
    public var rx: String?
    /// Uptime of the chunk that completed the reply; on timeout, the session's
    /// uptime when the timeout fired; on rejection, equal to `requestUptime`.
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

    /// CAN headers of the engine ECU, whose vehicle speed is the one the
    /// logger treats as authoritative: `7E8` (11-bit) and `18DAF110` (29-bit).
    public static let primaryECUHeaders: Set<String> = ["7E8", "18DAF110"]

    /// True for a reply from the engine ECU, and with headers off (`ecu ==
    /// nil`), where replies can't be attributed. Other ECUs' readings are
    /// kept and recorded; consumers that want one speed take this one.
    public static func isPrimaryECU(_ ecu: String?) -> Bool {
        ecu.map(primaryECUHeaders.contains) ?? true
    }

    /// `OBDReading.isPrimaryECU(ecu)`.
    public var isFromPrimaryECU: Bool {
        Self.isPrimaryECU(ecu)
    }

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
    /// Must be 1–9; anything else fails `ELM327Command.validated()`.
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

    /// The command sent every cycle, and the one recorded as
    /// `PollingRecord.command`:
    /// - `multiPID` → `.currentDataMany(pids, responseCount: responseCount)`,
    ///   e.g. `010D0C1`;
    /// - otherwise → `.currentDataMany([pids[0]], responseCount: responseCount)`,
    ///   e.g. `010D1` or `010D`.
    ///
    /// An `ELM327Command`, not a string, so it can only reach the adapter
    /// through `validated()`, which range-checks the response count (a
    /// string `010D10` would pass the policy as PIDs 0x0D and 0x10). The
    /// recorded string is its `wireFormat`. An empty plan yields a command
    /// that fails validation rather than trapping.
    public var primaryCommand: ELM327Command {
        .currentDataMany(multiPID ? pids : Array(pids.prefix(1)), responseCount: responseCount)
    }

    /// Throws `.invalidPlan` unless every field is in range: 1–6 distinct
    /// PIDs, `responseCount` nil or 1–9, `adaptiveTiming` 0–2, `rpmEvery` ≥ 1,
    /// `timeout` > 0, and `primaryCommand` passes `validated()`.
    /// `ELMSession.startPolling` calls it before anything is sent.
    public func validate() throws(ELMSessionError) {
        guard (1...6).contains(pids.count) else { throw .invalidPlan("\(pids.count) PIDs; 1-6 allowed") }
        guard Set(pids).count == pids.count else { throw .invalidPlan("repeated PID") }
        if let responseCount, !(1...9).contains(responseCount) {
            throw .invalidPlan("responseCount \(responseCount); 1-9 allowed")
        }
        guard (0...2).contains(adaptiveTiming) else { throw .invalidPlan("adaptiveTiming \(adaptiveTiming); 0-2 allowed") }
        guard rpmEvery >= 1 else { throw .invalidPlan("rpmEvery \(rpmEvery); must be at least 1") }
        guard timeout > .zero else { throw .invalidPlan("timeout must be positive") }
        do {
            _ = try primaryCommand.validated()
        } catch {
            throw .invalidPlan("primary command rejected: \(error)")
        }
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
    /// Pause before retrying a failed poll, so an adapter that answers every
    /// command instantly with an error isn't hammered in a tight loop.
    public var retryDelay: Duration
    /// Pause before re-init attempt `n` (1-based): `reinitBackoff × 2^(n−1)`.
    public var reinitBackoff: Duration

    public init(
        commandTimeout: Duration = .seconds(1),
        resetTimeout: Duration = .seconds(3),
        searchTimeout: Duration = .seconds(10),
        failuresBeforeReinit: Int = 3,
        reinitsBeforeReconnect: Int = 2,
        probe: Bool = true,
        rateWindow: Duration = .seconds(10),
        retryDelay: Duration = .milliseconds(100),
        reinitBackoff: Duration = .seconds(1)
    ) {
        self.commandTimeout = commandTimeout
        self.resetTimeout = resetTimeout
        self.searchTimeout = searchTimeout
        self.failuresBeforeReinit = failuresBeforeReinit
        self.reinitsBeforeReconnect = reinitsBeforeReconnect
        self.probe = probe
        self.rateWindow = rateWindow
        self.retryDelay = retryDelay
        self.reinitBackoff = reinitBackoff
    }

    public static let `default` = ELMSessionConfiguration()
}

/// Everything the session reports, on one stream.
///
/// Every case carries the uptime at which it *happened*, read from the
/// session's `UptimeSource` at that moment, so a consumer that runs late (the
/// main actor during a stall or a background transition) still writes it at
/// the right place on the session clock.
public enum ELMSessionEvent: Hashable, Sendable {
    case state(from: ELMState, to: ELMState, reason: String?, uptime: Double)
    case exchange(ELMExchange)
    case reading(OBDReading)
    case adapter(ELMAdapterInfo, uptime: Double)
    /// Successful polls per second over the last `rateWindow`. Display only;
    /// the recorder's `stats` rows compute their own rate from the file.
    case pollRate(hz: Double, uptime: Double)
    /// Re-init failed `reinitsBeforeReconnect` times; the owner should drop
    /// and reconnect the transport. Always preceded by `.state(to: .failed)`.
    case needsReconnect(uptime: Double)
}

