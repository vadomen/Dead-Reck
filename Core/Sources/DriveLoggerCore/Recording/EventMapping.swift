/// The one place where link runtime types become on-disk log types.
///
/// Runtime types (`ELMExchange`, `OBDReading`, `ELMAdapterInfo`, `LinkEvent`)
/// may evolve; the log types they map to are frozen by the format. Keeping the
/// mapping here means a runtime refactor can't silently change what gets
/// written. Every row is stamped with the uptime the event carries, converted
/// with `clock.timestamp(uptimeSeconds:)` — never with the time it was
/// consumed, and never clamped: an event from before the session started
/// (pre-drive init) gets a negative `t`.
extension LogEvent {
    /// The rows a link event produces: `elm`, `obd`, `link` or `adapter`.
    /// Empty for `pollRate` (display only) and `needsReconnect` (the session
    /// always reports its transition into `failed` as a `.state` event first,
    /// and the BLE layer's reaction arrives as `.ble` transitions).
    ///
    /// - Parameter adapter: what the BLE layer knows (name, identifier,
    ///   GATT), merged into `adapter` rows. When nil, an `adapter` row is
    ///   still written — the ELM facts are worth keeping — with `name` and
    ///   `identifier` as empty strings (both are required by the format).
    public static func rows(
        for event: LinkEvent,
        adapter: AdapterRecord?,
        clock: SessionClock
    ) -> [LogEvent] {
        switch event {
        case .ble(let from, let to, let reason, let uptime):
            return [LogEvent(bleTransitionFrom: from, to: to, reason: reason, uptime: uptime, clock: clock)]
        case .session(let sessionEvent):
            switch sessionEvent {
            case .state(let from, let to, let reason, let uptime):
                return [LogEvent(elmTransitionFrom: from, to: to, reason: reason, uptime: uptime, clock: clock)]
            case .exchange(let exchange):
                return [LogEvent(exchange: exchange, clock: clock)]
            case .reading(let reading):
                return [LogEvent(reading: reading, clock: clock)]
            case .adapter(let info, let uptime):
                let known = adapter ?? AdapterRecord(name: "", identifier: "")
                return [LogEvent(adapter: known, info: info, uptime: uptime, clock: clock)]
            case .pollRate, .needsReconnect:
                return []
            }
        }
    }

    /// `elm` row, stamped at `completedUptime`.
    public init(exchange: ELMExchange, clock: SessionClock) {
        self.init(
            timestamp: clock.timestamp(uptimeSeconds: exchange.completedUptime),
            payload: .elm(ELMTrafficSample(
                seq: exchange.seq,
                phase: exchange.phase.rawValue,
                tx: exchange.tx,
                requestT: clock.timestamp(uptimeSeconds: exchange.requestUptime),
                rx: exchange.rx,
                outcome: exchange.outcome.rawValue
            ))
        )
    }

    /// `obd` row, stamped at `replyUptime`, with `requestT` from
    /// `requestUptime`.
    public init(reading: OBDReading, clock: SessionClock) {
        self.init(
            timestamp: clock.timestamp(uptimeSeconds: reading.replyUptime),
            payload: .obd(OBDSample(
                measurement: reading.measurement,
                raw: reading.raw,
                requestT: clock.timestamp(uptimeSeconds: reading.requestUptime),
                command: reading.command,
                ecu: reading.ecu,
                seq: reading.seq
            ))
        )
    }

    /// `link` row with `layer: elm`.
    public init(
        elmTransitionFrom from: ELMState,
        to: ELMState,
        reason: String?,
        uptime: Double,
        clock: SessionClock
    ) {
        self.init(
            timestamp: clock.timestamp(uptimeSeconds: uptime),
            payload: .link(LinkSample(
                layer: LinkSample.Layer.elm.rawValue,
                from: from.rawValue,
                to: to.rawValue,
                reason: reason
            ))
        )
    }

    /// `link` row with `layer: ble`.
    public init(
        bleTransitionFrom from: LinkSample.BLEState,
        to: LinkSample.BLEState,
        reason: String?,
        uptime: Double,
        clock: SessionClock
    ) {
        self.init(
            timestamp: clock.timestamp(uptimeSeconds: uptime),
            payload: .link(LinkSample(
                layer: LinkSample.Layer.ble.rawValue,
                from: from.rawValue,
                to: to.rawValue,
                reason: reason
            ))
        )
    }

    /// `adapter` row: `adapter.with(info)` plus `PollingRecord(info.plan)`.
    public init(adapter: AdapterRecord, info: ELMAdapterInfo, uptime: Double, clock: SessionClock) {
        self.init(
            timestamp: clock.timestamp(uptimeSeconds: uptime),
            payload: .adapter(AdapterEventSample(
                adapter: adapter.with(info),
                polling: PollingRecord(info.plan)
            ))
        )
    }
}

extension PollingRecord {
    /// The record of `plan`.
    ///
    /// `command` is the command sent on a cycle where every PID is due:
    /// multi-PID → all PIDs in one request (`010D0C1`); single-PID → the
    /// every-cycle PID alone (`010D1`); the response-count suffix in both
    /// cases when set. This is `plan.primaryCommand.wireFormat`, so the
    /// recorded command is exactly what the session sends. A plan with no
    /// PIDs (never valid for polling) records an empty command rather than
    /// the meaningless `01`. `timeoutMs` is rounded to the nearest
    /// millisecond. `requestHeader` is the plan's physical header (`7E0`),
    /// absent for functional addressing.
    public init(_ plan: PollingPlan) {
        let command = plan.pids.isEmpty ? "" : plan.primaryCommand.wireFormat
        let (seconds, attoseconds) = plan.timeout.components
        let milliseconds = seconds * 1_000 + Int64((Double(attoseconds) / 1e15).rounded())
        self.init(
            command: command,
            pids: plan.pids.map { Int($0.rawValue) },
            multiPID: plan.multiPID,
            responseCount: plan.responseCount,
            adaptiveTiming: plan.adaptiveTiming,
            rpmEvery: plan.rpmEvery,
            timeoutMs: Int(milliseconds),
            requestHeader: plan.requestHeader?.rawValue
        )
    }
}

extension AdapterRecord {
    /// Merges what the BLE layer knows (name, identifier, GATT) with what the
    /// ELM session found. Every ELM field (`elmVersion`, `protocol`,
    /// `voltage`) comes from `info`, including an absent voltage — a value
    /// from an earlier initialisation is never carried over as if current.
    public func with(_ info: ELMAdapterInfo) -> AdapterRecord {
        var merged = self
        merged.elmVersion = info.elmVersion
        merged.protocolNumber = info.protocolNumber
        merged.voltage = info.voltage
        return merged
    }
}
