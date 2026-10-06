/// Everything the OBD link reports to the recorder, on one stream: BLE
/// transitions from the transport layer and the ELM session's events.
///
/// Carried as one stream so the two layers stay in order relative to each
/// other, and timestamped at the source for the same reason as
/// `ELMSessionEvent`.
public enum LinkEvent: Hashable, Sendable {
    case ble(from: LinkSample.BLEState, to: LinkSample.BLEState, reason: String?, uptime: Double)
    case session(ELMSessionEvent)
}
