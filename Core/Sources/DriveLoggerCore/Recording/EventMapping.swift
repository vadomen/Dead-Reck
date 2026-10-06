/// The one place where link runtime types become on-disk log types.
///
/// Runtime types (`ELMExchange`, `OBDReading`, `ELMAdapterInfo`, `LinkEvent`)
/// may evolve; the log types they map to are frozen by the format. Keeping the
/// mapping here means a runtime refactor can't silently change what gets
/// written. Every row is stamped with the uptime the event carries, converted
/// with `clock.timestamp(uptimeSeconds:)` — never with the time it was
/// consumed.
extension LogEvent {
    /// The rows a link event produces: `elm`, `obd`, `link` or `adapter`.
    /// Empty for `pollRate` (display only) and `needsReconnect` (the session
    /// always reports its transition into `failed` as a `.state` event first,
    /// and the BLE layer's reaction arrives as `.ble` transitions).
    ///
    /// - Parameter adapter: what the BLE layer knows (name, identifier,
    ///   GATT), merged into `adapter` rows.
    public static func rows(
        for event: LinkEvent,
        adapter: AdapterRecord?,
        clock: SessionClock
    ) -> [LogEvent] {
        fatalError("M1: LogEvent.rows(for:adapter:clock:)")
    }

    /// `elm` row, stamped at `completedUptime`.
    public init(exchange: ELMExchange, clock: SessionClock) {
        fatalError("M1: LogEvent(exchange:clock:)")
    }

    /// `obd` row, stamped at `replyUptime`, with `requestT` from
    /// `requestUptime`.
    public init(reading: OBDReading, clock: SessionClock) {
        fatalError("M1: LogEvent(reading:clock:)")
    }

    /// `link` row with `layer: elm`.
    public init(
        elmTransitionFrom from: ELMState,
        to: ELMState,
        reason: String?,
        uptime: Double,
        clock: SessionClock
    ) {
        fatalError("M1: LogEvent(elmTransitionFrom:to:reason:uptime:clock:)")
    }

    /// `link` row with `layer: ble`.
    public init(
        bleTransitionFrom from: LinkSample.BLEState,
        to: LinkSample.BLEState,
        reason: String?,
        uptime: Double,
        clock: SessionClock
    ) {
        fatalError("M1: LogEvent(bleTransitionFrom:to:reason:uptime:clock:)")
    }

    /// `adapter` row.
    public init(adapter: AdapterRecord, info: ELMAdapterInfo, uptime: Double, clock: SessionClock) {
        fatalError("M1: LogEvent(adapter:info:uptime:clock:)")
    }
}

extension PollingRecord {
    public init(_ plan: PollingPlan) {
        fatalError("M1: PollingRecord(plan)")
    }
}

extension AdapterRecord {
    /// Merges what the BLE layer knows (name, identifier, GATT) with what the
    /// ELM session found.
    public func with(_ info: ELMAdapterInfo) -> AdapterRecord {
        fatalError("M1: AdapterRecord.with")
    }
}
