/// The read-only guard: the only gate between any caller and the adapter.
///
/// Car safety depends on this. Allowed:
/// - `AT…` adapter commands;
/// - mode `01` requests: `01` followed by 1–6 PID bytes and an optional single
///   response-count digit (`010D`, `010D0C`, `010D1`).
///
/// Everything else is rejected before it reaches the transport — in
/// particular modes 04 (clear DTCs), 08, 2E, 31, 3B and any UDS or coding
/// request. `ELMSession` calls this for every command it sends, including its
/// own init and polling commands, so there is no unguarded path.
public enum ELMCommandPolicy {
    /// Throws `ELMSessionError.forbiddenCommand` unless `wire` (without the
    /// carriage return) is allowed. Case-insensitive; whitespace is rejected
    /// rather than stripped, so what is checked is exactly what is sent.
    public static func validate(_ wire: String) throws(ELMSessionError) {
        fatalError("M1: ELMCommandPolicy.validate")
    }

    public static func isAllowed(_ wire: String) -> Bool {
        do {
            try validate(wire)
            return true
        } catch {
            return false
        }
    }
}
