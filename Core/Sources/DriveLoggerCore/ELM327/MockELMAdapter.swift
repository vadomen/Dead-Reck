import Foundation

/// A scripted ELM327 that speaks over `ELMTransport`.
///
/// Ships in the library, not only in tests, so the simulator build can run the
/// whole recording pipeline without hardware. Replies arrive in configurable
/// fragments after configurable delays, the way BLE notifications do.
///
/// Like a real adapter it is serial: replies come out in the order the
/// commands went in, even if a later rule has a shorter delay. Delays run on
/// the injected clock, with the deadline fixed when the command arrives, so a
/// test clock drives it deterministically. A rule with zero delay answers
/// before `send` returns.
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
        /// How many commands this rule answers before it is used up and later
        /// rules get their turn. Nil = unlimited. Lets a test script "time out
        /// twice, then answer".
        public var times: Int?

        public init(
            command: String,
            reply: String?,
            delay: Duration = .milliseconds(30),
            fragmentSizes: [Int] = [],
            times: Int? = nil
        ) {
            self.command = command
            self.reply = reply
            self.delay = delay
            self.fragmentSizes = fragmentSizes
            self.times = times
        }
    }

    public nonisolated let incoming: AsyncStream<ELMChunk>

    private let continuation: AsyncStream<ELMChunk>.Continuation
    private let uptime: any UptimeSource
    private let clock: any Clock<Duration>
    private var rules: [Rule]
    private var received: [String] = []
    private var connected = true
    private var deliveries: [UInt64: Task<Void, Never>] = [:]
    private var lastDelivery: Task<Void, Never>?
    private var nextDeliveryID: UInt64 = 0

    /// Commands that arrived while an earlier reply was still being
    /// delivered. A session that keeps one command in flight never causes
    /// this unless a reply outlives its timeout.
    public private(set) var overlappingSends = 0

    /// The commands counted by `overlappingSends`, in order.
    public private(set) var overlappingCommands: [String] = []

    /// - Parameters:
    ///   - rules: first match wins; unmatched commands get `?\r\r>`.
    ///   - uptime: stamps sends and chunks, like the real transport.
    ///   - clock: drives reply delays.
    public init(
        rules: [Rule],
        uptime: any UptimeSource = SystemUptimeSource(),
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.rules = rules
        self.uptime = uptime
        self.clock = clock
        (incoming, continuation) = AsyncStream.makeStream(of: ELMChunk.self)
    }

    public func send(_ command: ValidatedELMCommand) async throws -> Double {
        Self.assertAllowed(command.wire)
        guard connected else { throw ELMTransportError.notConnected }
        received.append(command.wire)
        if !deliveries.isEmpty {
            overlappingSends += 1
            overlappingCommands.append(command.wire)
        }
        let requestUptime = uptime.uptimeSeconds

        let rule = takeRule(for: command.wire)
        guard let reply = rule.reply else { return requestUptime }
        let fragments = Self.fragments(of: Data(reply.utf8), sizes: rule.fragmentSizes)

        if rule.delay <= .zero, deliveries.isEmpty {
            deliver(fragments)
            return requestUptime
        }

        nextDeliveryID += 1
        let id = nextDeliveryID
        let wait = clock.sleeper(untilAfter: rule.delay)
        let previous = lastDelivery
        let task = Task {
            await previous?.value
            do {
                try await wait()
            } catch {
                self.deliveryEnded(id)
                return
            }
            self.deliver(fragments)
            self.deliveryEnded(id)
        }
        deliveries[id] = task
        lastDelivery = task
        return requestUptime
    }

    /// Every command received, in order — for asserting that nothing forbidden
    /// was ever written. Also re-checks each one against `ELMCommandPolicy`
    /// and fails the test run (`preconditionFailure`) if a command slipped
    /// through, which can only happen if the policy itself regresses.
    public var sentCommands: [String] {
        received.forEach(Self.assertAllowed)
        return received
    }

    /// Simulates output nobody asked for — what an adapter may still have
    /// buffered at connect, or a reply to a command sent before this
    /// session. Delivered immediately as one chunk, behind any pending reply.
    public func emitUnsolicited(_ text: String) {
        let fragments = [Data(text.utf8)]
        guard let previous = lastDelivery else {
            deliver(fragments)
            return
        }
        lastDelivery = Task {
            await previous.value
            self.deliver(fragments)
        }
    }

    /// Simulates the adapter being unplugged: finishes `incoming`. Replies
    /// still pending are dropped and later sends throw `.notConnected`.
    public func disconnect() {
        connected = false
        for task in deliveries.values { task.cancel() }
        deliveries.removeAll()
        lastDelivery = nil
        continuation.finish()
    }

    private func takeRule(for wire: String) -> Rule {
        let upper = wire.uppercased()
        guard let index = rules.firstIndex(where: { $0.command.uppercased() == upper && ($0.times ?? 1) > 0 }) else {
            return Rule(command: wire, reply: "?\r\r>", delay: .zero)
        }
        let rule = rules[index]
        if let times = rule.times { rules[index].times = times - 1 }
        return rule
    }

    private func deliver(_ fragments: [Data]) {
        guard connected else { return }
        for fragment in fragments {
            continuation.yield(ELMChunk(bytes: fragment, uptime: uptime.uptimeSeconds))
        }
    }

    private func deliveryEnded(_ id: UInt64) {
        deliveries[id] = nil
    }

    private static func fragments(of data: Data, sizes: [Int]) -> [Data] {
        let sizes = sizes.filter { $0 > 0 }
        guard !sizes.isEmpty else { return [data] }
        var result: [Data] = []
        var index = data.startIndex
        var sizeIndex = 0
        while index < data.endIndex {
            let end = min(data.endIndex, index + sizes[sizeIndex % sizes.count])
            result.append(data[index..<end])
            index = end
            sizeIndex += 1
        }
        return result
    }

    private static func assertAllowed(_ wire: String) {
        guard ELMCommandPolicy.isAllowed(wire, scope: .session) else {
            preconditionFailure("MockELMAdapter received \(wire), which ELMCommandPolicy forbids")
        }
    }
}

extension MockELMAdapter.Rule {
    /// A VW Touareg 2025 behind an ELM327 v2.1 clone, headers on, spaces off:
    /// protocol 6, two ECUs answering `0100`, multi-PID and the `1` suffix
    /// supported, `NO DATA` for intake air temperature. Speed and RPM replies
    /// come from `7E8` (60 km/h, 750 rpm), the battery reads 12.4 V.
    ///
    /// Delays imitate a cheap clone over BLE: without the suffix the adapter
    /// waits out its own timeout for more ECUs (~95 ms), with it the reply
    /// comes as soon as `7E8` answers (~40 ms); `ATZ` and the first `0100`
    /// are slow. Replies arrive in 20-byte notifications. These numbers are
    /// invented, not measured — check them on the bench (M4).
    public static var touareg: [MockELMAdapter.Rule] {
        func rule(_ command: String, _ reply: String, ms: Int = 30) -> MockELMAdapter.Rule {
            MockELMAdapter.Rule(command: command, reply: reply, delay: .milliseconds(ms), fragmentSizes: [20])
        }
        return [
            // ATZ arrives with echo still on from the adapter's power-up default.
            rule("ATZ", "ATZ\r\r\rELM327 v2.1\r\r>", ms: 600),
            rule("ATE0", "ATE0\rOK\r\r>"),
            rule("ATE1", "OK\r\r>"),
            rule("ATL0", "OK\r\r>"),
            rule("ATS0", "OK\r\r>"),
            rule("ATH1", "OK\r\r>"),
            rule("ATH0", "OK\r\r>"),
            rule("ATSP0", "OK\r\r>"),
            rule("ATAT0", "OK\r\r>"),
            rule("ATAT1", "OK\r\r>"),
            rule("ATAT2", "OK\r\r>"),
            rule("ATI", "ELM327 v2.1\r\r>"),
            rule("AT@1", "OBDII to RS232 Interpreter\r\r>"),
            rule("ATDP", "AUTO, ISO 15765-4 (CAN 11/500)\r\r>"),
            rule("ATDPN", "A6\r\r>"),
            rule("ATRV", "12.4V\r\r>"),
            rule("0100", "SEARCHING...\r7E8064100BE3FA813\r7E906410098180001\r\r>", ms: 1_500),
            rule("010D", "7E803410D3C\r\r>", ms: 95),
            rule("010D1", "7E803410D3C\r\r>", ms: 40),
            rule("010C", "7E804410C0BB8\r\r>", ms: 95),
            rule("010C1", "7E804410C0BB8\r\r>", ms: 40),
            rule("010D0C", "7E806410D3C0C0BB8\r\r>", ms: 100),
            rule("010D0C1", "7E806410D3C0C0BB8\r\r>", ms: 45),
            rule("010F", "NO DATA\r\r>", ms: 95),
            rule("010F1", "NO DATA\r\r>", ms: 95),
        ]
    }
}
