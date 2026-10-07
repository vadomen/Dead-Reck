import Foundation

/// Talks to one adapter over one transport: init, probing, polling.
///
/// Exactly one command is in flight at any time. Every command — init, probe,
/// poll and manual — passes `ELMCommandPolicy` first. Every exchange and every
/// state transition is emitted on `events`.
///
/// Timestamps are uptimes, not session timestamps, so the link can initialise
/// before a recording (and its `SessionClock`) exists. The recorder converts
/// with `clock.timestamp(uptimeSeconds:)`, which shares the base of
/// `clock.now()`. `uptime` must be the same timebase the transport stamps
/// with — in production both use `SystemUptimeSource`.
///
/// One session lives for one transport connection. After a reconnect the owner
/// creates a new session with `firstSeq: previous.nextSeq` so exchange numbers
/// stay unique for the whole recording.
///
/// ## State machine
///
/// ```
/// idle ─initialise()→ resetting (ATZ) → initialising (ATE0…ATSP0)
///      → searching (0100) → initialising (ATDPN, ATRV) → probing → ready
/// ready ─startPolling()→ polling
/// polling ─failure→ retrying ─failure × failuresBeforeReinit→ reinitialising
/// retrying/reinitialising ─success→ polling
/// reinitialising ─limit reached→ failed (+ needsReconnect)
/// polling ─stopPolling() or every PID NO DATA→ ready
/// any ─transport closes→ failed;  any ─shutdown()→ idle
/// ```
///
/// - A poll **failure** is any outcome other than `ok` and `noData`
///   (timeout, `?`, `CAN ERROR`, malformed, …) or a failed write. Failures
///   are retried after `retryDelay`; the `failuresBeforeReinit`-th
///   consecutive one re-runs the handshake (after `reinitBackoff × 2^(n−1)`
///   for attempt `n`), then retries the command.
/// - A re-init "fails" if a handshake step fails, or if polling fails
///   `failuresBeforeReinit` times again before any poll succeeds. After
///   `reinitsBeforeReconnect` of those the session goes to `failed`, emits
///   `needsReconnect` once and sends nothing more.
/// - `NO DATA` is not a failure: the vehicle doesn't implement that PID. It
///   is recorded and the PID is dropped from polling (a multi-PID request
///   answering `NO DATA` falls back to single PIDs first). When no PID is
///   left, polling ends in `ready`.
/// - A session-originated command that fails `validated()` (R1-8; cannot
///   happen with a validated plan, but defended anyway) becomes a `rejected`
///   exchange with `tx = wireFormat`, then `failed` with a reason. It is never
///   retried and does not request a reconnect.
/// - A reply that completes when no command is waiting for it — it arrived
///   after its command timed out — is recorded as an extra `timeout`
///   exchange **with** `rx`, attributed to the most recently sent command,
///   with its own `seq`. It never produces readings.
public actor ELMSession {
    /// Single consumer. Finishes after `shutdown()` or when the transport's
    /// stream finishes.
    public nonisolated let events: AsyncStream<ELMSessionEvent>

    private let transport: any ELMTransport
    private let configuration: ELMSessionConfiguration
    private let uptime: any UptimeSource
    private let clock: any Clock<Duration>
    private let continuation: AsyncStream<ELMSessionEvent>.Continuation

    /// - Parameters:
    ///   - uptime: stamps state changes, timeouts, rejections and adapter
    ///     events. Same timebase as the transport's stamps.
    ///   - clock: drives timeouts, backoff and the poll-rate window only
    ///     (never timestamps); inject a test clock to run the state machine
    ///     without real waits.
    ///   - firstSeq: `seq` of the first exchange.
    public init(
        transport: any ELMTransport,
        configuration: ELMSessionConfiguration = .default,
        uptime: any UptimeSource = SystemUptimeSource(),
        clock: any Clock<Duration> = ContinuousClock(),
        firstSeq: Int = 0
    ) {
        self.transport = transport
        self.configuration = configuration
        self.uptime = uptime
        self.clock = clock
        self.nextSeq = firstSeq
        (events, continuation) = AsyncStream.makeStream(of: ELMSessionEvent.self)
    }

    public private(set) var state: ELMState = .idle

    /// `seq` the next exchange will get. Read it after `shutdown()` to seed the
    /// session for the next connection.
    public private(set) var nextSeq: Int

    /// Probe samples per candidate command; the median latency is compared.
    static let probeSamples = 3

    // MARK: Link state

    private struct InFlight {
        let token: UInt64
        var resolution: Resolution?
        var continuation: CheckedContinuation<Resolution, Never>?
        var timeoutTask: Task<Void, Never>?
    }

    private enum Resolution: Sendable {
        case reply(ELMRawReply)
        case timedOut(uptime: Double)
        case closed
        case cancelled
    }

    private struct SentCommand {
        var tx: String
        var phase: ELMPhase
        var requestUptime: Double
    }

    private var framer = ELMFramer()
    private var readerTask: Task<Void, Never>?
    private var transportClosed = false
    private var isShutdown = false
    private var inFlight: InFlight?
    private var nextToken: UInt64 = 0
    private var lastSent: SentCommand?
    private var slotBusy = false
    private var slotWaiters: [CheckedContinuation<Void, Never>] = []

    // MARK: Adapter state

    private var headersOn = false
    private var adaptiveTimingLevel = 1
    private var initialised = false
    private var initTask: Task<Result<ELMAdapterInfo, ELMSessionError>, Never>?

    // MARK: Polling state

    private var plan: PollingPlan?
    private var activePIDs: [OBDPID] = []
    private var multiPIDActive = false
    private var pollTask: Task<Void, Never>?
    private var rateTask: Task<Void, Never>?
    private var stopRequested = false
    private var consecutiveFailures = 0
    private var reinitsWithoutSuccess = 0
    private var successfulPollsInWindow = 0

    // MARK: Public API

    /// `ATZ` → `ATE0` → `ATL0` → `ATS0` → `ATH1` → `ATSP0` → `0100` → `ATDPN`
    /// → `ATRV`, then (if configured) probes multi-PID, the response-count
    /// suffix and `ATAT2`, keeping the fastest combination that parses.
    ///
    /// `ATZ` waits up to `resetTimeout`, the `0100` search `searchTimeout`,
    /// everything else `commandTimeout`. A failed step throws
    /// `.initFailed(step:reason:)` (reason = the exchange outcome) and leaves
    /// the session `failed`; a missing `ATRV` voltage is not a failure. Stops
    /// polling first if it was running. Concurrent calls share one run.
    public func initialise() async throws(ELMSessionError) -> ELMAdapterInfo {
        if let initTask {
            return try await initTask.value.get()
        }
        let task = Task { await self.runInitialisation() }
        initTask = task
        let result = await task.value
        initTask = nil
        return try result.get()
    }

    /// Starts the poll loop. Requires `ready`; the plan must pass
    /// `PollingPlan.validate()` (else `.invalidPlan`, nothing sent). If the
    /// plan's `adaptiveTiming` differs from the adapter's, `ATATn` is sent
    /// first (phase `poll`), and again after every re-init.
    public func startPolling(_ plan: PollingPlan) throws(ELMSessionError) {
        try checkOpen()
        try plan.validate()
        guard state == .ready, initialised, pollTask == nil else { throw .notInitialised }
        self.plan = plan
        activePIDs = plan.pids
        multiPIDActive = plan.multiPID
        stopRequested = false
        consecutiveFailures = 0
        reinitsWithoutSuccess = 0
        setState(.polling, reason: nil)
        startRateTimer()
        pollTask = Task { await self.pollLoop() }
    }

    /// Stops after the in-flight command completes (a retry or re-init
    /// backoff is cut short); returns to `ready`.
    public func stopPolling() async {
        guard let task = pollTask else { return }
        stopRequested = true
        task.cancel()
        await task.value
    }

    /// Debug console. Guarded by `ELMCommandPolicy` with `scope: .manual`:
    /// read-only AT queries and mode 01 only, so a typed command can't change
    /// the settings the session relies on. While polling, queued between polls
    /// so only one command is ever in flight.
    ///
    /// A rejected command emits an exchange with outcome `rejected` (`tx` as
    /// typed, stamped now, never sent) and then throws `.forbiddenCommand`.
    /// Manual exchanges never produce readings and never count towards poll
    /// failures.
    public func sendManual(_ command: String) async throws(ELMSessionError) -> ELMExchange {
        try checkOpen()
        let validated: ValidatedELMCommand
        do {
            validated = try ELMCommandPolicy.validate(command, scope: .manual)
        } catch {
            emitRejection(phase: .manual, tx: command)
            throw error
        }
        let headers = headersOn
        let wire = validated.wire
        return try await run(validated, phase: .manual, timeout: configuration.commandTimeout) { raw in
            (Self.classify(raw, wire: wire, headers: headers), ())
        }.exchange
    }

    /// Stops polling, abandons a command still in flight, goes `idle` and
    /// finishes `events`. Idempotent.
    public func shutdown() async {
        guard !isShutdown else { return }
        isShutdown = true
        stopRequested = true
        pollTask?.cancel()
        initTask?.cancel()
        rateTask?.cancel()
        rateTask = nil
        let abandoned = inFlight != nil ? lastSent?.tx : nil
        if let flight = inFlight { resolve(flight.token, with: .cancelled) }
        releaseAllWaiters()
        await pollTask?.value
        _ = await initTask?.value
        readerTask?.cancel()
        recordPendingPartialReply()
        if !transportClosed {
            setState(.idle, reason: abandoned.map { "shutdown; \($0) abandoned in flight" } ?? "shutdown")
        }
        continuation.finish()
    }

    // MARK: Initialisation

    private func runInitialisation() async -> Result<ELMAdapterInfo, ELMSessionError> {
        do throws(ELMSessionError) {
            return .success(try await initialiseNow())
        } catch {
            return .failure(error)
        }
    }

    private func initialiseNow() async throws(ELMSessionError) -> ELMAdapterInfo {
        try checkOpen()
        if pollTask != nil { await stopPolling() }
        initialised = false
        do {
            let found = try await runHandshake(tracksStates: true)
            let plan: PollingPlan
            if configuration.probe {
                setState(.probing, reason: nil)
                plan = try await probe()
            } else {
                plan = fallbackPlan(pids: PollingPlan.baseline.pids)
            }
            let info = ELMAdapterInfo(
                elmVersion: found.banner,
                protocolNumber: found.protocolNumber,
                voltage: found.voltage,
                supportedPIDs: found.supportedPIDs,
                plan: plan
            )
            initialised = true
            continuation.yield(.adapter(info, uptime: uptime.uptimeSeconds))
            setState(.ready, reason: nil)
            return info
        } catch {
            failIfOpen(reason: "init failed: \(error)")
            throw error
        }
    }

    private enum InitValue {
        case banner(String)
        case acknowledged
        case supported(String)
        case protocolNumber(String)
        case voltage(Double)
    }

    private struct HandshakeResult {
        var banner = ""
        var protocolNumber = ""
        var voltage: Double?
        var supportedPIDs: String?
    }

    private func runHandshake(tracksStates: Bool) async throws(ELMSessionError) -> HandshakeResult {
        var result = HandshakeResult()
        for command in ELM327Command.handshake {
            if tracksStates {
                switch command {
                case .reset: setState(.resetting, reason: nil)
                case .supportedPIDs: setState(.searching, reason: nil)
                default: setState(.initialising, reason: nil)
                }
            }
            let timeout = switch command {
            case .reset: configuration.resetTimeout
            case .supportedPIDs: configuration.searchTimeout
            default: configuration.commandTimeout
            }
            let headers = headersOn
            let (exchange, value) = try await perform(command, phase: .initialisation, timeout: timeout) { raw in
                Self.interpretInit(command, raw: raw, headers: headers)
            }
            guard let value else {
                if command == .readVoltage { continue }
                throw .initFailed(step: command.wireFormat, reason: exchange.outcome.rawValue)
            }
            switch value {
            case .banner(let banner): result.banner = banner
            case .supported: result.supportedPIDs = exchange.rx
            case .protocolNumber(let number): result.protocolNumber = number
            case .voltage(let volts): result.voltage = volts
            case .acknowledged: break
            }
            switch command {
            case .reset:
                headersOn = false
                adaptiveTimingLevel = 1
            case .headers(let on):
                headersOn = on
            default:
                break
            }
        }
        return result
    }

    private static func interpretInit(
        _ command: ELM327Command,
        raw: String,
        headers: Bool
    ) -> (outcome: ELMOutcome, value: InitValue?) {
        do {
            if command == .supportedPIDs {
                let replies = try ELM327ResponseParser.replies(in: raw, headers: headers)
                guard replies.contains(where: { $0.bytes.starts(with: [0x41, 0x00]) }) else { return (.malformed, nil) }
                return (.ok, .supported(raw))
            }
            switch (command, try ELM327ResponseParser.textReply(to: command.wireFormat, raw: raw)) {
            case (.reset, .banner(let banner)): return (.ok, .banner(banner))
            case (.describeProtocolNumber, .protocolNumber(let number)): return (.ok, .protocolNumber(number))
            case (.readVoltage, .voltage(let volts)): return (.ok, .voltage(volts))
            case (.echo, .ok), (.lineFeeds, .ok), (.spaces, .ok), (.headers, .ok), (.autoProtocol, .ok):
                return (.ok, .acknowledged)
            default: return (.malformed, nil)
            }
        } catch {
            return (outcome(for: error), nil)
        }
    }

    // MARK: Probing

    private enum ProbeResult {
        case valid(latency: Double)
        case noData
        case invalid
    }

    /// Measures every combination of adaptive timing (1, 2), response-count
    /// suffix (none, 1) and single vs multi-PID, and returns the cheapest per
    /// speed sample: `latency(speed) + latency(others) / rpmEvery` for single
    /// PIDs, `latency(all)` for multi-PID. A combination counts only if every
    /// sample parses and the primary ECU (`7E8`) answered every PID. Ties keep
    /// the earlier, more conservative combination. A PID answering `NO DATA`
    /// to the plain single request is left out. Leaves the adapter at the
    /// chosen timing level.
    private func probe() async throws(ELMSessionError) -> PollingPlan {
        var supported = PollingPlan.baseline.pids
        let rpmEvery = PollingPlan.baseline.rpmEvery
        var best: (plan: PollingPlan, cost: Double)?

        for level in 1...2 {
            guard try await setAdaptiveTiming(level, phase: .probe) == .ok else { continue }
            for responseCount in [nil, 1] as [Int?] {
                var latencies: [OBDPID: Double] = [:]
                for pid in supported {
                    switch try await measure(.currentDataMany([pid], responseCount: responseCount), pids: [pid]) {
                    case .valid(let latency):
                        latencies[pid] = latency
                    case .noData where level == 1 && responseCount == nil:
                        supported.removeAll { $0 == pid }
                    case .noData, .invalid:
                        break
                    }
                }
                if let first = supported.first, let firstLatency = latencies[first],
                   supported.allSatisfy({ latencies[$0] != nil }) {
                    let others = supported.dropFirst().compactMap { latencies[$0] }.reduce(0, +)
                    let cost = firstLatency + others / Double(rpmEvery)
                    if best.map({ cost < $0.cost }) ?? true {
                        best = (probePlan(supported, multiPID: false, responseCount, level, rpmEvery), cost)
                    }
                }
                if supported.count > 1,
                   case .valid(let latency) = try await measure(
                       .currentDataMany(supported, responseCount: responseCount),
                       pids: supported
                   ),
                   best.map({ latency < $0.cost }) ?? true {
                    best = (probePlan(supported, multiPID: true, responseCount, level, rpmEvery), latency)
                }
            }
        }

        let plan = best?.plan ?? fallbackPlan(pids: supported.isEmpty ? PollingPlan.baseline.pids : supported)
        if adaptiveTimingLevel != plan.adaptiveTiming {
            _ = try await setAdaptiveTiming(plan.adaptiveTiming, phase: .probe)
        }
        return plan
    }

    private func probePlan(
        _ pids: [OBDPID],
        multiPID: Bool,
        _ responseCount: Int?,
        _ level: Int,
        _ rpmEvery: Int
    ) -> PollingPlan {
        PollingPlan(
            pids: pids,
            multiPID: multiPID,
            responseCount: responseCount,
            adaptiveTiming: level,
            rpmEvery: rpmEvery,
            timeout: configuration.commandTimeout
        )
    }

    /// `PollingPlan.baseline` with `pids` and the configured command timeout.
    private func fallbackPlan(pids: [OBDPID]) -> PollingPlan {
        var plan = PollingPlan.baseline
        plan.pids = pids
        plan.timeout = configuration.commandTimeout
        return plan
    }

    private func measure(_ command: ELM327Command, pids: [OBDPID]) async throws(ELMSessionError) -> ProbeResult {
        var latencies: [Double] = []
        for _ in 0..<Self.probeSamples {
            let headers = headersOn
            let (exchange, decoded) = try await perform(command, phase: .probe, timeout: configuration.commandTimeout) { raw in
                Self.interpretPoll(raw, pids: pids, headers: headers)
            }
            if exchange.outcome == .noData { return .noData }
            guard let decoded else { return .invalid }
            let fromPrimary = Set(decoded.filter { OBDReading.isPrimaryECU($0.ecu) }.map(\.measurement.pid))
            guard fromPrimary.isSuperset(of: pids) else { return .invalid }
            latencies.append(exchange.completedUptime - exchange.requestUptime)
        }
        return .valid(latency: latencies.sorted()[latencies.count / 2])
    }

    /// Sends `ATATn`; on `OK` records the adapter's new level.
    private func setAdaptiveTiming(_ level: Int, phase: ELMPhase) async throws(ELMSessionError) -> ELMOutcome {
        let command = ELM327Command.adaptiveTiming(level)
        let wire = command.wireFormat
        let (exchange, _) = try await perform(command, phase: phase, timeout: configuration.commandTimeout) { raw in
            Self.interpretAcknowledgement(raw, wire: wire)
        }
        if exchange.outcome == .ok { adaptiveTimingLevel = level }
        return exchange.outcome
    }

    // MARK: Polling

    private struct DecodedValue {
        var ecu: String?
        var measurement: OBDMeasurement
    }

    private enum PollStep {
        case success
        case noData
        case failure(String)
        case ended
    }

    private func pollLoop() async {
        var cycle = 0
        cycles: while !stopRequested, !Task.isCancelled, let plan {
            let commands = cycleCommands(cycle, plan: plan)
            if commands.isEmpty {
                setState(.ready, reason: "every polled PID answered NO DATA")
                break
            }
            for (command, pids) in commands {
                attempts: while true {
                    if stopRequested || Task.isCancelled { break cycles }
                    let step: PollStep
                    if adaptiveTimingLevel != plan.adaptiveTiming {
                        step = await applyPlanTiming(plan.adaptiveTiming)
                        if case .success = step { continue attempts }
                    } else {
                        step = await pollOnce(command, pids: pids, plan: plan)
                    }
                    switch step {
                    case .success, .noData:
                        break attempts
                    case .failure(let reason):
                        guard await escalate(after: reason) else { break cycles }
                    case .ended:
                        break cycles
                    }
                }
            }
            cycle += 1
        }
        pollingEnded()
    }

    /// Multi-PID: every active PID in one request each cycle. Single: the
    /// first active PID every cycle, the others every `rpmEvery`th cycle
    /// (starting with the first). Always `.currentDataMany`, so each wire
    /// string follows `PollingPlan.primaryCommand`'s rule.
    private func cycleCommands(_ cycle: Int, plan: PollingPlan) -> [(ELM327Command, [OBDPID])] {
        guard let first = activePIDs.first else { return [] }
        if multiPIDActive {
            return [(.currentDataMany(activePIDs, responseCount: plan.responseCount), activePIDs)]
        }
        var commands = [(ELM327Command.currentDataMany([first], responseCount: plan.responseCount), [first])]
        if cycle % plan.rpmEvery == 0 {
            commands += activePIDs.dropFirst().map { (.currentDataMany([$0], responseCount: plan.responseCount), [$0]) }
        }
        return commands
    }

    private func pollOnce(_ command: ELM327Command, pids: [OBDPID], plan: PollingPlan) async -> PollStep {
        let headers = headersOn
        let exchange: ELMExchange
        let decoded: [DecodedValue]?
        do {
            (exchange, decoded) = try await perform(command, phase: .poll, timeout: plan.timeout) { raw in
                Self.interpretPoll(raw, pids: pids, headers: headers)
            }
        } catch {
            return step(for: error)
        }

        switch exchange.outcome {
        case .ok:
            for value in decoded ?? [] {
                continuation.yield(.reading(OBDReading(
                    seq: exchange.seq,
                    command: exchange.tx,
                    ecu: value.ecu,
                    measurement: value.measurement,
                    raw: exchange.rx ?? "",
                    requestUptime: exchange.requestUptime,
                    replyUptime: exchange.completedUptime
                )))
            }
            successfulPollsInWindow += 1
            consecutiveFailures = 0
            reinitsWithoutSuccess = 0
            if state != .polling { setState(.polling, reason: "recovered") }
            return .success
        case .noData:
            consecutiveFailures = 0
            let reason: String
            if multiPIDActive, pids.count > 1 {
                multiPIDActive = false
                reason = "NO DATA for \(exchange.tx); polling PIDs singly"
            } else {
                activePIDs.removeAll { pids.contains($0) }
                reason = "NO DATA for \(exchange.tx); PID no longer polled"
            }
            if state != .polling { setState(.polling, reason: reason) }
            return .noData
        default:
            return .failure(exchange.outcome.rawValue)
        }
    }

    private func applyPlanTiming(_ level: Int) async -> PollStep {
        do {
            let outcome = try await setAdaptiveTiming(level, phase: .poll)
            return outcome == .ok ? .success : .failure("ATAT\(level): \(outcome.rawValue)")
        } catch {
            return step(for: error)
        }
    }

    private func step(for error: ELMSessionError) -> PollStep {
        switch error {
        case .forbiddenCommand, .cancelled:
            return .ended
        case .transport where transportClosed || isShutdown:
            return .ended
        case .transport(let transportError):
            return .failure("write failed: \(transportError)")
        default:
            return .failure("\(error)")
        }
    }

    /// Retry, or re-init once failures reach the threshold. False when
    /// polling must end (failed, stopped, shut down or disconnected).
    private func escalate(after reason: String) async -> Bool {
        consecutiveFailures += 1
        if consecutiveFailures < configuration.failuresBeforeReinit {
            setState(.retrying, reason: reason)
            return await pause(configuration.retryDelay)
        }
        return await reinitialiseForPolling(after: reason)
    }

    private func reinitialiseForPolling(after failure: String) async -> Bool {
        var reason = failure
        while true {
            if reinitsWithoutSuccess >= configuration.reinitsBeforeReconnect {
                setState(.failed, reason: "\(reinitsWithoutSuccess) re-init(s) did not restore polling; last: \(reason)")
                continuation.yield(.needsReconnect(uptime: uptime.uptimeSeconds))
                return false
            }
            reinitsWithoutSuccess += 1
            setState(.reinitialising, reason: reason)
            let backoff = configuration.reinitBackoff * (1 << min(reinitsWithoutSuccess - 1, 16))
            guard await pause(backoff) else { return false }
            initialised = false
            do {
                let found = try await runHandshake(tracksStates: false)
                initialised = true
                consecutiveFailures = 0
                if let plan {
                    let info = ELMAdapterInfo(
                        elmVersion: found.banner,
                        protocolNumber: found.protocolNumber,
                        voltage: found.voltage,
                        supportedPIDs: found.supportedPIDs,
                        plan: plan
                    )
                    continuation.yield(.adapter(info, uptime: uptime.uptimeSeconds))
                }
                setState(.polling, reason: "re-initialised")
                return true
            } catch {
                if case .forbiddenCommand = error { return false }
                if isShutdown || transportClosed { return false }
                if case .cancelled = error { return false }
                reason = "re-init failed: \(error)"
            }
        }
    }

    /// Waits on the injected clock. False if polling should end instead.
    private func pause(_ duration: Duration) async -> Bool {
        if duration > .zero {
            do {
                try await clock.sleeper(untilAfter: duration)()
            } catch {
                return false
            }
        }
        return !stopRequested && !Task.isCancelled
    }

    private func pollingEnded() {
        pollTask = nil
        rateTask?.cancel()
        rateTask = nil
        guard !isShutdown, !transportClosed, state != .failed else { return }
        if initialised {
            setState(.ready, reason: "polling stopped")
        } else {
            setState(.failed, reason: "polling stopped during re-init; initialise() again")
        }
    }

    private func startRateTimer() {
        rateTask?.cancel()
        successfulPollsInWindow = 0
        let window = configuration.rateWindow
        guard window > .zero else { return }
        rateTask = Task { await self.rateLoop(window: window) }
    }

    private func rateLoop(window: Duration) async {
        let windowSeconds = Double(window.components.seconds) + Double(window.components.attoseconds) / 1e18
        while !Task.isCancelled {
            do {
                try await clock.sleeper(untilAfter: window)()
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            let hz = Double(successfulPollsInWindow) / windowSeconds
            successfulPollsInWindow = 0
            continuation.yield(.pollRate(hz: hz, uptime: uptime.uptimeSeconds))
        }
    }

    // MARK: Commands

    /// Session-originated command: validated (session scope), then sent.
    /// A command that fails validation is R1-8: a `rejected` exchange with
    /// `tx = wireFormat`, `failed` with a reason, and the error rethrown so
    /// the caller never retries it.
    private func perform<Value>(
        _ command: ELM327Command,
        phase: ELMPhase,
        timeout: Duration,
        interpret: (String) -> (outcome: ELMOutcome, value: Value?)
    ) async throws(ELMSessionError) -> (exchange: ELMExchange, value: Value?) {
        let validated: ValidatedELMCommand
        do {
            validated = try command.validated()
        } catch {
            emitRejection(phase: phase, tx: command.wireFormat)
            stopRequested = true
            setState(.failed, reason: "\(command.wireFormat) rejected by the read-only guard: \(error)")
            throw error
        }
        return try await run(validated, phase: phase, timeout: timeout, interpret: interpret)
    }

    /// Test seam for the R1-8 path: a session-originated command with no
    /// particular interpretation.
    func perform(_ command: ELM327Command, phase: ELMPhase) async throws(ELMSessionError) -> ELMExchange {
        let headers = headersOn
        let wire = command.wireFormat
        return try await perform(command, phase: phase, timeout: configuration.commandTimeout) { raw in
            (Self.classify(raw, wire: wire, headers: headers), ())
        }.exchange
    }

    /// Takes the single command slot, sends, waits for the prompt or the
    /// timeout, and emits the exchange.
    private func run<Value>(
        _ command: ValidatedELMCommand,
        phase: ELMPhase,
        timeout: Duration,
        interpret: (String) -> (outcome: ELMOutcome, value: Value?)
    ) async throws(ELMSessionError) -> (exchange: ELMExchange, value: Value?) {
        try await acquireSlot()
        defer { releaseSlot() }
        let (requestUptime, resolution) = try await transact(command, phase: phase, timeout: timeout)
        switch resolution {
        case .reply(let reply):
            let (outcome, value) = interpret(reply.text)
            let exchange = emitExchange(
                phase: phase,
                tx: command.wire,
                requestUptime: requestUptime,
                rx: reply.text,
                completedUptime: reply.completedUptime,
                outcome: outcome
            )
            return (exchange, outcome == .ok ? value : nil)
        case .timedOut(let firedUptime):
            let exchange = emitExchange(
                phase: phase,
                tx: command.wire,
                requestUptime: requestUptime,
                rx: nil,
                completedUptime: firedUptime,
                outcome: .timeout
            )
            return (exchange, nil)
        case .closed:
            throw .transport(.disconnected(nil))
        case .cancelled:
            throw .cancelled
        }
    }

    private func transact(
        _ command: ValidatedELMCommand,
        phase: ELMPhase,
        timeout: Duration
    ) async throws(ELMSessionError) -> (requestUptime: Double, resolution: Resolution) {
        try checkOpen()
        startReaderIfNeeded()
        nextToken += 1
        let token = nextToken
        // The deadline is fixed before the write, so a slow write counts
        // against the timeout too.
        let wait = clock.sleeper(untilAfter: timeout)
        var flight = InFlight(token: token)
        flight.timeoutTask = Task { [weak self] in
            do {
                try await wait()
            } catch {
                return
            }
            await self?.timeoutFired(token)
        }
        inFlight = flight

        let requestUptime: Double
        do {
            requestUptime = try await transport.send(command)
        } catch {
            discardInFlight(token)
            if isShutdown { throw .cancelled }
            if transportClosed { throw .transport(.disconnected(nil)) }
            throw .transport(error as? ELMTransportError ?? .writeFailed(String(describing: error)))
        }
        lastSent = SentCommand(tx: command.wire, phase: phase, requestUptime: requestUptime)

        // The reply (or the timeout) may already be in: a zero-latency
        // transport answers before `send` returns.
        guard let current = inFlight, current.token == token else { return (requestUptime, .cancelled) }
        if let resolution = current.resolution {
            inFlight = nil
            return (requestUptime, resolution)
        }
        let resolution = await withCheckedContinuation { (continuation: CheckedContinuation<Resolution, Never>) in
            if inFlight?.token == token {
                inFlight?.continuation = continuation
            } else {
                continuation.resume(returning: .cancelled)
            }
        }
        return (requestUptime, resolution)
    }

    @discardableResult
    private func resolve(_ token: UInt64, with resolution: Resolution) -> Bool {
        guard var flight = inFlight, flight.token == token, flight.resolution == nil else { return false }
        flight.timeoutTask?.cancel()
        flight.timeoutTask = nil
        if let continuation = flight.continuation {
            inFlight = nil
            continuation.resume(returning: resolution)
        } else {
            flight.resolution = resolution
            inFlight = flight
        }
        return true
    }

    private func discardInFlight(_ token: UInt64) {
        guard let flight = inFlight, flight.token == token else { return }
        flight.timeoutTask?.cancel()
        inFlight = nil
    }

    private func timeoutFired(_ token: UInt64) {
        resolve(token, with: .timedOut(uptime: uptime.uptimeSeconds))
    }

    private func acquireSlot() async throws(ELMSessionError) {
        try checkOpen()
        if slotBusy {
            // Ownership is handed over by `releaseSlot`.
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                slotWaiters.append(continuation)
            }
        } else {
            slotBusy = true
        }
        do {
            try checkOpen()
        } catch {
            releaseSlot()
            throw error
        }
    }

    private func releaseSlot() {
        if slotWaiters.isEmpty {
            slotBusy = false
        } else {
            slotWaiters.removeFirst().resume()
        }
    }

    private func releaseAllWaiters() {
        let waiters = slotWaiters
        slotWaiters = []
        for waiter in waiters { waiter.resume() }
    }

    private func checkOpen() throws(ELMSessionError) {
        if isShutdown { throw .cancelled }
        if transportClosed { throw .transport(.disconnected(nil)) }
    }

    // MARK: Transport input

    private func startReaderIfNeeded() {
        guard readerTask == nil else { return }
        let incoming = transport.incoming
        readerTask = Task { [weak self] in
            for await chunk in incoming {
                guard let self else { return }
                await self.receive(chunk)
            }
            await self?.transportDidClose()
        }
    }

    private func receive(_ chunk: ELMChunk) {
        for reply in framer.append(chunk) {
            if let flight = inFlight, resolve(flight.token, with: .reply(reply)) { continue }
            recordLateReply(text: reply.text, completedUptime: reply.completedUptime)
        }
    }

    private func transportDidClose() {
        guard !transportClosed, !isShutdown else { return }
        transportClosed = true
        stopRequested = true
        pollTask?.cancel()
        rateTask?.cancel()
        rateTask = nil
        if let flight = inFlight { resolve(flight.token, with: .closed) }
        recordPendingPartialReply()
        releaseAllWaiters()
        setState(.failed, reason: "transport closed")
        continuation.finish()
    }

    /// A reply nobody is waiting for: its command already timed out. Kept as
    /// a `timeout` exchange with `rx`, attributed to the last command sent.
    private func recordLateReply(text: String, completedUptime: Double) {
        emitExchange(
            phase: lastSent?.phase ?? .initialisation,
            tx: lastSent?.tx ?? "",
            requestUptime: lastSent?.requestUptime ?? completedUptime,
            rx: text,
            completedUptime: completedUptime,
            outcome: .timeout
        )
    }

    /// Bytes received without a prompt when the link ends are kept too.
    private func recordPendingPartialReply() {
        let text = framer.pendingText
        framer.reset()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        recordLateReply(text: text, completedUptime: uptime.uptimeSeconds)
    }

    // MARK: Events

    private func setState(_ new: ELMState, reason: String?) {
        guard new != state else { return }
        let old = state
        state = new
        continuation.yield(.state(from: old, to: new, reason: reason, uptime: uptime.uptimeSeconds))
    }

    private func failIfOpen(reason: String) {
        guard !isShutdown, !transportClosed, state != .failed else { return }
        setState(.failed, reason: reason)
    }

    @discardableResult
    private func emitExchange(
        phase: ELMPhase,
        tx: String,
        requestUptime: Double,
        rx: String?,
        completedUptime: Double,
        outcome: ELMOutcome
    ) -> ELMExchange {
        let exchange = ELMExchange(
            seq: nextSeq,
            phase: phase,
            tx: tx,
            requestUptime: requestUptime,
            rx: rx,
            completedUptime: completedUptime,
            outcome: outcome
        )
        nextSeq += 1
        continuation.yield(.exchange(exchange))
        return exchange
    }

    /// Never sent: stamped now, `requestUptime == completedUptime`.
    private func emitRejection(phase: ELMPhase, tx: String) {
        let now = uptime.uptimeSeconds
        emitExchange(phase: phase, tx: tx, requestUptime: now, rx: nil, completedUptime: now, outcome: .rejected)
    }

    // MARK: Reply interpretation

    private static func interpretPoll(
        _ raw: String,
        pids: [OBDPID],
        headers: Bool
    ) -> (outcome: ELMOutcome, value: [DecodedValue]?) {
        do {
            let replies = try ELM327ResponseParser.replies(in: raw, headers: headers)
            var decoded: [DecodedValue] = []
            for reply in replies {
                // An ECU answer that doesn't decode (e.g. a 7F negative
                // response from another module) stays in the raw text only.
                guard let measurements = try? OBDDecoder.decode(requested: pids, bytes: reply.bytes) else { continue }
                decoded += measurements.map { DecodedValue(ecu: reply.header, measurement: $0) }
            }
            return decoded.isEmpty ? (.malformed, nil) : (.ok, decoded)
        } catch {
            return (outcome(for: error), nil)
        }
    }

    private static func interpretAcknowledgement(_ raw: String, wire: String) -> (outcome: ELMOutcome, value: Void?) {
        do {
            return try ELM327ResponseParser.textReply(to: wire, raw: raw) == .ok ? (.ok, ()) : (.malformed, nil)
        } catch {
            return (outcome(for: error), nil)
        }
    }

    /// Outcome of a reply when nothing more specific is expected: AT
    /// commands must produce a text reply, mode 01 a parseable frame set.
    static func classify(_ raw: String, wire: String, headers: Bool) -> ELMOutcome {
        do {
            if wire.hasPrefix("AT") {
                _ = try ELM327ResponseParser.textReply(to: wire, raw: raw)
            } else {
                _ = try ELM327ResponseParser.replies(in: raw, headers: headers)
            }
            return .ok
        } catch {
            return outcome(for: error)
        }
    }

    static func outcome(for error: any Error) -> ELMOutcome {
        switch error as? ELM327Error {
        case .noData: .noData
        case .unableToConnect: .unableToConnect
        case .stopped: .stopped
        case .busInitFailed: .busInitError
        case .busError: .busError
        case .canError: .canError
        case .bufferFull: .bufferFull
        case .dataError: .dataError
        case .notRecognised: .notRecognised
        case .adapter: .adapterError
        case .malformedHex, .malformedFrame, .truncatedFrame, .unexpectedMode, .unexpectedPID, .emptyResponse, nil:
            .malformed
        }
    }
}
