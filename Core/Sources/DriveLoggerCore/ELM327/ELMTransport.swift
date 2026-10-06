import Foundation

/// Bytes as delivered by the radio, stamped where they arrived.
///
/// The stamp is taken in the transport's own callback (for BLE, the
/// `didUpdateValueFor` delegate method) before any actor hop, because hop
/// latency would otherwise show up as OBD latency in the recording.
public struct ELMChunk: Hashable, Sendable {
    public var bytes: Data
    /// Seconds since boot, from the recording's `UptimeSource` timebase.
    public var uptime: Double

    public init(bytes: Data, uptime: Double) {
        self.bytes = bytes
        self.uptime = uptime
    }
}

/// A byte pipe to an ELM327 adapter: BLE in the app, `MockELMAdapter` in tests
/// and on the simulator.
///
/// Knows nothing about replies — framing and parsing live above it in
/// `ELMSession`. It accepts only `ValidatedELMCommand`, which nothing outside
/// DriveLoggerCore can create except through `ELMCommandPolicy`, so holding a
/// transport does not give a way around the read-only guard.
public protocol ELMTransport: Sendable {
    /// Writes `command.wireData`, splitting it to the link's maximum write
    /// length if needed. Returns the uptime at which the write was issued —
    /// the OBD request timestamp — from the same `UptimeSource` timebase as
    /// the chunks on `incoming`.
    func send(_ command: ValidatedELMCommand) async throws -> Double

    /// Every inbound fragment, in arrival order. Finishes when the link drops.
    /// Single consumer.
    var incoming: AsyncStream<ELMChunk> { get }
}

/// Errors a transport reports.
public enum ELMTransportError: Error, Hashable, Sendable {
    case notConnected
    case writeFailed(String)
    case disconnected(String?)
}

/// One complete reply: everything up to the `>` prompt.
public struct ELMRawReply: Hashable, Sendable {
    /// Verbatim text with NUL bytes and the trailing `>` removed. Line endings
    /// are kept so the raw record is faithful.
    public var text: String
    /// Uptime of the chunk that carried the prompt.
    public var completedUptime: Double

    public init(text: String, completedUptime: Double) {
        self.text = text
        self.completedUptime = completedUptime
    }
}

/// Reassembles arbitrary BLE fragments into complete replies.
///
/// A reply is complete only when the `>` prompt arrives. One chunk may complete
/// several replies (rare, after a stall) or none.
public struct ELMFramer: Sendable {
    public init() {}

    /// Appends a fragment and returns any replies it completed, in order.
    public mutating func append(_ chunk: ELMChunk) -> [ELMRawReply] {
        fatalError("M1: ELMFramer.append")
    }

    /// Discards a partial reply, e.g. after a timeout or reconnect.
    public mutating func reset() {
        fatalError("M1: ELMFramer.reset")
    }
}
