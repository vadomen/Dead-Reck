/// Failures reported by an ELM327 adapter, or found while parsing its replies.
///
/// Adapter status strings are part of the protocol, not transport noise: `NO
/// DATA` means the ECU didn't answer that PID, which is normal for PIDs a given
/// vehicle doesn't implement and should be recorded rather than retried forever.
public enum ELM327Error: Error, Hashable, Sendable {
    /// `NO DATA` — the request went out but no ECU answered in time. Usually
    /// means this vehicle doesn't support the PID.
    case noData

    /// `UNABLE TO CONNECT` — no OBD protocol could be negotiated at all.
    case unableToConnect

    /// `STOPPED` — the adapter aborted the request, typically because a new
    /// command arrived while one was in flight.
    case stopped

    /// `BUS INIT: ERROR` — bus initialisation failed.
    case busInitFailed

    /// `BUS ERROR` — bus wiring or voltage problem.
    case busError

    /// `CAN ERROR` — CAN transport failure.
    case canError

    /// `BUFFER FULL` — the adapter's buffer overflowed; the reply is truncated.
    case bufferFull

    /// `DATA ERROR` — the adapter saw a malformed frame on the bus.
    case dataError

    /// `?` — the adapter didn't recognise the command.
    case notRecognised

    /// An unrecognised adapter error line, kept verbatim for diagnosis.
    case adapter(String)

    /// The reply contained something that wasn't valid ASCII hex.
    case malformedHex(String)

    /// The reply ended before the expected number of bytes arrived.
    case truncatedFrame(expected: Int, actual: Int)

    /// The adapter answered a different service than the one requested.
    case unexpectedMode(expected: UInt8, actual: UInt8)

    /// The adapter answered a different PID than the one requested.
    case unexpectedPID(expected: UInt8, actual: UInt8)

    /// The reply contained no usable lines.
    case emptyResponse
}
