/// The one place where ELM runtime types become on-disk log types.
///
/// Runtime types (`ELMExchange`, `OBDReading`, `ELMAdapterInfo`) may evolve;
/// the log types they map to are frozen by the format. Keeping the mapping here
/// means a runtime refactor can't silently change what gets written.
extension LogEvent {
    /// `elm` row, stamped at `completedUptime`.
    public init(exchange: ELMExchange, clock: SessionClock) {
        fatalError("M1: LogEvent(exchange:clock:)")
    }

    /// `obd` row, stamped at `replyUptime`, with `requestT` from
    /// `requestUptime`.
    public init(reading: OBDReading, clock: SessionClock) {
        fatalError("M1: LogEvent(reading:clock:)")
    }

    /// `link` row for an ELM state transition, stamped `clock.now()`.
    public init(
        elmTransitionFrom from: ELMState,
        to: ELMState,
        reason: String?,
        clock: SessionClock
    ) {
        fatalError("M1: LogEvent(elmTransitionFrom:to:reason:clock:)")
    }

    /// `adapter` row, stamped `clock.now()`.
    public init(adapter: AdapterRecord, info: ELMAdapterInfo, clock: SessionClock) {
        fatalError("M1: LogEvent(adapter:info:clock:)")
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
