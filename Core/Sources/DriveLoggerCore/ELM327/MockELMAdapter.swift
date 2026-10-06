import Foundation

/// A scripted ELM327 that speaks over `ELMTransport`.
///
/// Ships in the library, not only in tests, so the simulator build can run the
/// whole recording pipeline without hardware. Replies arrive in configurable
/// fragments after configurable delays, the way BLE notifications do.
///
/// An actor, so its mutable script state needs no locks.
public actor MockELMAdapter: ELMTransport {
    /// One scripted behaviour: when a command matching `command` arrives, reply
    /// with `reply` (which should end with `>`) after `delay`, split into
    /// chunks of `fragmentSizes` bytes (cycled; empty = one chunk).
    public struct Rule: Hashable, Sendable {
        /// Matched case-insensitively against the command without CR.
        public var command: String
        /// Nil = never answer, to exercise timeouts.
        public var reply: String?
        public var delay: Duration
        public var fragmentSizes: [Int]

        public init(command: String, reply: String?, delay: Duration = .milliseconds(30), fragmentSizes: [Int] = []) {
            self.command = command
            self.reply = reply
            self.delay = delay
            self.fragmentSizes = fragmentSizes
        }
    }

    public nonisolated let incoming: AsyncStream<ELMChunk>

    /// - Parameters:
    ///   - rules: first match wins; unmatched commands get `?\r\r>`.
    ///   - uptime: stamps sends and chunks, like the real transport.
    ///   - clock: drives reply delays.
    public init(
        rules: [Rule],
        uptime: any UptimeSource = SystemUptimeSource(),
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        fatalError("M1: MockELMAdapter.init")
    }

    public func send(_ command: ValidatedELMCommand) async throws -> Double {
        fatalError("M1: MockELMAdapter.send")
    }

    /// Every command received, in order — for asserting that nothing forbidden
    /// was ever written. Also re-checks each one against `ELMCommandPolicy`
    /// and fails the test run (`preconditionFailure`) if a command slipped
    /// through, which can only happen if the policy itself regresses.
    public var sentCommands: [String] {
        fatalError("M1: MockELMAdapter.sentCommands")
    }

    /// Simulates the adapter being unplugged: finishes `incoming`.
    public func disconnect() {
        fatalError("M1: MockELMAdapter.disconnect")
    }
}

extension MockELMAdapter.Rule {
    /// A VW Touareg 2025 behind an ELM327 v2.1 clone, headers on, spaces off:
    /// protocol 6, two ECUs answering `0100`, multi-PID and the `1` suffix
    /// supported, `NO DATA` for intake air temperature. Speed and RPM replies
    /// come from `7E8`.
    public static var touareg: [MockELMAdapter.Rule] {
        fatalError("M1: MockELMAdapter.Rule.touareg")
    }
}
