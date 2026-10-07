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
/// - A poll **failure** is any outcome other than `ok` (and other than a
///   droppable `NO DATA`, below): timeout, `?`, `CAN ERROR`, malformed, …,
///   or a failed write. Failures are retried after `retryDelay`; the
///   `failuresBeforeReinit`-th consecutive one re-runs the handshake (after
///   `reinitBackoff × 2^(n−1)` for attempt `n`), then retries the command.
/// - A re-init "fails" if a handshake step fails, or if polling fails
///   `failuresBeforeReinit` times again before any poll succeeds. After
///   `reinitsBeforeReconnect` of those the session goes to `failed`, emits
///   `needsReconnect` once and sends nothing more.
///
/// ## NO DATA
///
/// Every `NO DATA` is recorded as an `elm` row with outcome `noData`. What
/// happens next depends on the PID's history in this session:
/// - A PID that has **never** answered OK in this session (poll or probe)
///   is dropped: the vehicle doesn't implement it. When no PID is left,
///   polling ends in `ready`.
/// - A PID that **has** answered OK is never dropped — whatever the `0100`
///   bitmask says; a PID that has answered is evidently supported. Its
///   `NO DATA` is a failure like a timeout: retry → re-init → `failed` +
///   `needsReconnect`, with the same backoff. One transient `NO DATA` must
///   not cost the speed signal for the rest of the drive.
/// - A multi-PID request answering `NO DATA` falls back to single PIDs, but
///   only if that exact request has never answered OK; otherwise it is a
///   failure too.
/// Whenever the combination actually polled changes (a PID dropped, the
/// multi-PID fallback, a re-init), `.adapter` is emitted again with the plan
/// now in use, so the log always says what is being polled.
///
/// ## Replies, prompts and timeouts
///
/// - A command that times out still owes a `>`. Its timeout row is emitted
///   at the moment of the timeout, in the same step that records the owed
///   prompt. Owed prompts are paid first, oldest first. The next reply is a
///   late row for the oldest owed command — outcome `timeout` **and** `rx`,
///   that command's `tx`, `phase` and `requestUptime`, its own `seq` — and
///   never resolves the command in flight. Late rows produce no readings.
/// - Before sending anything while prompts are owed, the session waits up to
///   `latePromptGrace` for them. Prompts that arrive in time are simply paid.
///   Those that don't are **written off**. A `.state` event with
///   `from == to` and a reason starting `no prompt for` records it, and the
///   link is **desynchronised**: their replies may still come, so no reply
///   can be matched to a command any more.
/// - **While desynchronised, only `ATZ` is sent.** Replies are paid to the
///   written-off commands (oldest first) or recorded as unsolicited; none
///   answers a command. The link is trusted again once `ATZ` is answered
///   with a banner. How each caller gets there:
///   - **Polling:** re-initialises at once (`reinitialising`, reason
///     `link desynchronised: …`) through the normal re-init budget and
///     backoff. A wedged adapter still ends in `failed` + one
///     `needsReconnect`.
///   - **`initialise()`:** restarts its own sequence from `ATZ` (a `.state`
///     note with `from == to`, reason starting `link desynchronised during
///     initialisation; restarting from ATZ`), at most
///     `reinitsBeforeReconnect` times. After that it throws
///     `.desynchronised` and the session is `failed`.
///   - **`sendManual`:** throws `.desynchronised` without sending anything.
///     The caller recovers with `initialise()`, or by starting polling (which
///     re-initialises itself).
/// - **`ATZ` is the resync point.**
///   - Banner-shaped text (contains `ELM`, or `isBannerCandidate`) only ever
///     answers a banner command (`ATZ`, `ATI`, `AT@1`). A late banner
///     arriving while e.g. `ATE0` waits is a late or unsolicited row, never
///     `ATE0`'s reply, so the handshake can't shift by one.
///   - If an `ATZ`, `ATI` or `AT@1` is among the written-off commands, its
///     banner may still be on its way. The next `ATZ` then waits out its full
///     `resetTimeout` and takes the **last** banner. Earlier ones are paid to
///     the written-off commands in order.
///   - Otherwise the first reply containing `ELM` is the banner. If none
///     comes within `resetTimeout`, the last banner-shaped reply is taken,
///     with a `.state` note `ATZ banner without 'ELM': <banner>`. Banner-
///     shaped means letters, digits and a version token (`v1.5`), and not
///     hex, `OK`, a voltage or a status; `ATDP`/`AT@1`-style text doesn't
///     qualify. Some clones call themselves e.g. `OBDII v1.5`. Init fails at
///     `ATZ` only if nothing usable arrived.
///   - Text half-received when `ATZ` is sent is kept as a late row, then the
///     framer starts clean.
/// - Output nobody asked for (buffered at connect, or anything while nothing
///   is owed, written off or in flight) is recorded as a `timeout` exchange
///   with `rx` and an empty `tx`.
/// - A command still in flight when the session shuts down or the link
///   drops gets a final exchange: outcome `timeout`, no `rx`, completed at
///   that moment.
/// - A session-originated command that fails `validated()` (R1-8; cannot
///   happen with a validated plan, but defended anyway) becomes a `rejected`
///   exchange with `tx = wireFormat`, then `failed` with a reason. It is never
///   retried and does not request a reconnect.
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
        // Listen from the start, so output buffered at connect is recorded as
        // unsolicited instead of being read as the reply to the first command.
        Task { await self.startReaderIfNeeded() }
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
        let wire: String
        let phase: ELMPhase
        /// Which replies may resolve this command.
        let acceptance: Acceptance
        var requiresBanner: Bool {
            if case .banner = acceptance { true } else { false }
        }
        /// The moment before the write; replaced by the transport's stamp
        /// once `send` returns.
        var requestUptime: Double
        /// `ATZ`: banner-shaped replies held in arrival order until an `ELM`
        /// banner or the end of the window decides.
        var bannerCandidates: [ELMRawReply] = []
        var resolution: Resolution?
        var continuation: CheckedContinuation<Resolution, Never>?
        var timeoutTask: Task<Void, Never>?
    }

    private enum Acceptance {
        /// Any reply that isn't banner-shaped (banner commands: any reply).
        case any
        /// `ATZ`: a reply containing `ELM`, else at the end of the window the
        /// last banner-shaped one. `waitFullWindow` (an `ATZ`/`ATI`/`AT@1` is
        /// written off, so its banner may still come): hold every banner and
        /// take the last.
        case banner(waitFullWindow: Bool)
    }

    private enum Resolution: Sendable {
        case reply(ELMRawReply)
        /// The timeout row, already emitted by `timeoutFired`.
        case timedOut(ELMExchange)
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
    /// Commands that timed out and still owe a `>`, oldest first.
    private var owedPrompts: [SentCommand] = []
    private var owedWaiter: (token: UInt64, continuation: CheckedContinuation<Bool, Never>, timer: Task<Void, Never>)?
    /// After a write-off, replies can't be matched to commands until `ATZ`
    /// is answered with a banner; until then only `ATZ` is sent.
    private var desynchronised = false
    /// Written-off commands whose replies may still come; replies no command
    /// takes are paid to them, oldest first.
    private var writtenOff: [SentCommand] = []
    /// The plan last announced in an `.adapter` event.
    private var announcedPlan: PollingPlan?

    // MARK: Adapter state

    private var headersOn = false
    private var adaptiveTimingLevel = 1
    private var initialised = false
    /// What the last successful handshake found.
    private var adapterFacts: HandshakeResult?
    /// PIDs that have answered OK (poll or probe) in this session.
    private var okPIDs: Set<OBDPID> = []
    /// Mode 01 commands (wire) that have answered OK in this session.
    private var okCommands: Set<String> = []
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
        try beginPolling(plan)
    }

    /// `startPolling` minus `validate()`. Internal so tests can push a plan
    /// that slips past validation through the poll loop (R1-8 defence).
    func beginPolling(_ plan: PollingPlan) throws(ELMSessionError) {
        try checkOpen()
        guard state == .ready, initialised, pollTask == nil else { throw .notInitialised }
        self.plan = plan
        activePIDs = plan.pids
        multiPIDActive = plan.multiPID
        // The log must say what is polled: announce a plan other than the
        // one `initialise()` (or the last change) reported.
        if currentPlan != announcedPlan { emitCurrentAdapterInfo() }
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
        let abandoned = inFlight?.wire
        abandonInFlight(with: .cancelled)
        finishOwedWait(nil, drained: false)
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
        // A write-off mid-sequence desynchronises the link; the sequence then
        // restarts from ATZ, at most `reinitsBeforeReconnect` times.
        var restarts = 0
        while true {
            do {
                let found = try await runHandshake(tracksStates: true)
                let plan: PollingPlan
                if configuration.probe {
                    setState(.probing, reason: nil)
                    plan = try await probe()
                } else {
                    plan = fallbackPlan(pids: PollingPlan.baseline.pids)
                }
                let info = Self.adapterInfo(found, plan: plan)
                initialised = true
                announcedPlan = plan
                continuation.yield(.adapter(info, uptime: uptime.uptimeSeconds))
                setState(.ready, reason: nil)
                return info
            } catch {
                if case .desynchronised = error, restarts < configuration.reinitsBeforeReconnect {
                    restarts += 1
                    noteState(
                        reason: "link desynchronised during initialisation; restarting from ATZ "
                            + "(\(restarts)/\(configuration.reinitsBeforeReconnect))"
                    )
                    continue
                }
                failIfOpen(reason: "init failed: \(error)")
                throw error
            }
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
            case .banner(let banner):
                result.banner = banner
                if !banner.uppercased().contains("ELM") {
                    noteState(reason: "ATZ banner without 'ELM': \(banner)")
                }
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
        adapterFacts = result
        return result
    }

    private static func adapterInfo(_ found: HandshakeResult, plan: PollingPlan) -> ELMAdapterInfo {
        ELMAdapterInfo(
            elmVersion: found.banner,
            protocolNumber: found.protocolNumber,
            voltage: found.voltage,
            supportedPIDs: found.supportedPIDs,
            plan: plan
        )
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
    /// to the plain single request is left out only under the NO DATA rule
    /// (it has never answered OK in this session, earlier samples and earlier
    /// `initialise()` calls included); otherwise that combination is just
    /// invalid. Leaves the adapter at the chosen timing level.
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
                    case .noData where level == 1 && responseCount == nil && isDroppableOnNoData(pid):
                        // The one NO DATA rule: never answered OK → drop.
                        supported.removeAll { $0 == pid }
                    case .noData, .invalid:
                        // A PID that has answered OK keeps its place; this
                        // combination just doesn't count.
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
            okPIDs.formUnion(decoded.map(\.measurement.pid))
            okCommands.insert(exchange.tx)
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
        /// A prompt was written off: nothing but ATZ may go out, re-init now.
        case desynchronised
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
                    case .desynchronised:
                        // Straight to re-init via ATZ, through the normal
                        // re-init budget and backoff; then retry the command.
                        guard await reinitialiseForPolling(after: "link desynchronised: a prompt was written off") else {
                            break cycles
                        }
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
            okPIDs.formUnion((decoded ?? []).map(\.measurement.pid))
            okCommands.insert(exchange.tx)
            successfulPollsInWindow += 1
            consecutiveFailures = 0
            reinitsWithoutSuccess = 0
            if state != .polling { setState(.polling, reason: "recovered") }
            return .success
        case .noData:
            let reason: String
            if multiPIDActive, pids.count > 1 {
                // Once this request has worked, NO DATA is a fault, not a
                // capability answer.
                if okCommands.contains(exchange.tx) { return .failure(ELMOutcome.noData.rawValue) }
                multiPIDActive = false
                reason = "NO DATA for \(exchange.tx); polling PIDs singly"
            } else {
                let droppable = pids.filter(isDroppableOnNoData)
                guard !droppable.isEmpty else { return .failure(ELMOutcome.noData.rawValue) }
                activePIDs.removeAll { droppable.contains($0) }
                reason = "NO DATA for \(exchange.tx); PID no longer polled"
            }
            consecutiveFailures = 0
            if state != .polling { setState(.polling, reason: reason) }
            emitCurrentAdapterInfo()
            return .noData
        default:
            return .failure(exchange.outcome.rawValue)
        }
    }

    /// The NO DATA rule (see the type's doc): only a PID that has never
    /// answered OK in this session may be dropped. Having answered OK wins
    /// over everything else, the `0100` bitmask included.
    private func isDroppableOnNoData(_ pid: OBDPID) -> Bool {
        !okPIDs.contains(pid)
    }

    /// The plan as currently polled: active PIDs and multi-PID state.
    private var currentPlan: PollingPlan? {
        guard var plan else { return nil }
        plan.pids = activePIDs
        plan.multiPID = multiPIDActive
        return plan
    }

    /// Re-announces the adapter with the combination now in use. Nothing if
    /// no PID is left (the `.state` change to `ready` says so).
    private func emitCurrentAdapterInfo() {
        guard let adapterFacts, let plan = currentPlan, !plan.pids.isEmpty else { return }
        announcedPlan = plan
        continuation.yield(.adapter(Self.adapterInfo(adapterFacts, plan: plan), uptime: uptime.uptimeSeconds))
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
        case .desynchronised:
            return .desynchronised
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
                _ = try await runHandshake(tracksStates: false)
                initialised = true
                consecutiveFailures = 0
                emitCurrentAdapterInfo()
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

    /// Test seam: fires the timeout of the command in flight and then, in
    /// the same actor step, receives `text` — the interleaving where a reply
    /// lands between the timeout and `run()` resuming. The test clock can't
    /// force it otherwise.
    func injectTimeoutThenReply(_ text: String) {
        guard let flight = inFlight, flight.resolution == nil else { return }
        timeoutFired(flight.token)
        receive(ELMChunk(bytes: Data(text.utf8), uptime: uptime.uptimeSeconds))
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
        // stopPolling() may have been called while this poll waited for the
        // slot behind a manual command: don't let it out.
        if phase == .poll, stopRequested { throw .cancelled }
        await settleOwedPrompts()
        try checkOpen()
        if phase == .poll, stopRequested { throw .cancelled }
        let isReset = command.wire == ELM327Command.reset.wireFormat
        // A desynchronised link carries nothing but ATZ: any other reply
        // could be a written-off command's.
        if desynchronised, !isReset { throw .desynchronised }
        let acceptance: Acceptance
        if isReset {
            prepareForReset()
            // A written-off ATZ (or ATI/AT@1) may still print its banner
            // during this one: wait out the window, take the last banner.
            let waitFullWindow = writtenOff.contains { Self.bannerCommands.contains($0.tx) }
            acceptance = .banner(waitFullWindow: waitFullWindow)
        } else {
            acceptance = .any
        }
        let (requestUptime, resolution) = try await transact(command, phase: phase, timeout: timeout, acceptance: acceptance)
        switch resolution {
        case .reply(let reply):
            // ATZ answered with a banner: the adapter is reset and replies
            // line up with commands again.
            if isReset { resynchronised() }
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
        case .timedOut(let exchange):
            // `timeoutFired` emitted the row and recorded the owed prompt in
            // the step that took the command off the wire.
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
        timeout: Duration,
        acceptance: Acceptance
    ) async throws(ELMSessionError) -> (requestUptime: Double, resolution: Resolution) {
        try checkOpen()
        startReaderIfNeeded()
        nextToken += 1
        let token = nextToken
        // The deadline is fixed before the write, so a slow write counts
        // against the timeout too.
        let wait = clock.sleeper(untilAfter: timeout)
        // requestUptime starts as the moment before the write and becomes the
        // transport's own stamp once `send` returns; a timeout that fires
        // while the write is still going uses the former.
        var flight = InFlight(
            token: token, wire: command.wire, phase: phase, acceptance: acceptance,
            requestUptime: uptime.uptimeSeconds
        )
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
        if inFlight?.token == token { inFlight?.requestUptime = requestUptime }

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
        guard let flight = inFlight, flight.token == token, flight.resolution == nil else { return }
        // ATZ at the end of its window: the last ELM banner held, else the
        // last banner-shaped reply.
        if flight.requiresBanner, let banner = releaseBannerCandidates(choosing: true) {
            resolve(token, with: .reply(banner))
            return
        }
        // One actor step: emit the timeout row, record the owed prompt, take
        // the command off the wire. No reply can be processed in between, so
        // a reply landing with the timeout is always this command's late row,
        // after its timeout row — never unsolicited, never first.
        let now = uptime.uptimeSeconds
        let exchange = emitExchange(
            phase: flight.phase,
            tx: flight.wire,
            requestUptime: flight.requestUptime,
            rx: nil,
            completedUptime: now,
            outcome: .timeout
        )
        owedPrompts.append(SentCommand(tx: flight.wire, phase: flight.phase, requestUptime: flight.requestUptime))
        resolve(token, with: .timedOut(exchange))
    }

    /// Empties the `ATZ` reply hold. With `choosing`, returns the banner: the
    /// last held reply containing `ELM`, else the last held one. Every other
    /// held reply is paid as late (written-off commands first) or
    /// unsolicited, in arrival order.
    @discardableResult
    private func releaseBannerCandidates(choosing: Bool) -> ELMRawReply? {
        guard var held = inFlight?.bannerCandidates, !held.isEmpty else { return nil }
        inFlight?.bannerCandidates = []
        var chosen: ELMRawReply?
        if choosing {
            let index = held.lastIndex { $0.text.uppercased().contains("ELM") } ?? held.index(before: held.endIndex)
            chosen = held.remove(at: index)
        }
        for reply in held { payLateOrUnsolicited(reply) }
        return chosen
    }

    /// A reply that could be a non-`ELM` banner. Its last line (after the
    /// echo) must look like a banner: letters **and** digits, not all hex (a
    /// CAN frame, `A6`, `6`), not `OK`, not a voltage; and no line may be a
    /// status (`?`, `NO DATA`, …). Stale output therefore never qualifies.
    /// … and contains a version token. "OBDII v1.5" and "Vgate iCar Pro V2.3"
    /// qualify; "AUTO, ISO 15765-4 (CAN 11/500)" does not.
    static func isBannerCandidate(_ text: String, command: String) -> Bool {
        let lines = ELM327ResponseParser.lines(in: text).filter { $0.uppercased() != command.uppercased() }
        guard let last = lines.last, lines.allSatisfy({ ELM327ResponseParser.error(for: $0) == nil }) else {
            return false
        }
        let compact = String(last.filter { !$0.isWhitespace })
        guard compact.contains(where: { $0.isASCII && $0.isLetter }),
              compact.contains(where: { $0.isASCII && $0.isNumber }) else { return false }
        if compact.allSatisfy({ $0.isASCII && $0.isHexDigit }) { return false }
        if compact.uppercased() == "OK" { return false }
        if isVoltageReply(last) { return false }
        // A version token (`v1.5`, `V2.3`, `2.1`) — which `ATDP` (`AUTO, ISO
        // 15765-4 (CAN 11/500)`) and `AT@1` replies don't have.
        return last.contains(/[vV]?\d+\.\d+/)
    }

    /// Commands whose reply is a banner (or banner-like text). Only they may
    /// be answered by a banner-shaped reply; see `accept(_:by:)`.
    static let bannerCommands: Set<String> = ["ATZ", "ATI", "AT@1"]

    /// The reply to `ATRV`: a number of volts (0–40), with a decimal point or
    /// a `V` suffix, e.g. `12.4V`. No data reply has this shape: mode 01
    /// replies always contain hex letters (`41 0D …`, a `7E8` header).
    static func isVoltageReply(_ text: String) -> Bool {
        let lines = ELM327ResponseParser.lines(in: text).filter { $0.uppercased() != "ATRV" }
        guard let last = lines.last, lines.count == 1 else { return false }
        var compact = String(last.filter { !$0.isWhitespace }).uppercased()
        let hadSuffix = compact.hasSuffix("V")
        if hadSuffix { compact.removeLast() }
        guard hadSuffix || compact.contains("."),
              compact.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") }),
              let volts = Double(compact) else { return false }
        return (0...40).contains(volts)
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

    /// Who a reply belongs to, in order:
    /// 1. On a trusted link, prompts still owed within their grace period,
    ///    oldest first (late rows).
    /// 2. The command in flight, if `accept(_:by:)` takes it.
    /// 3. Written-off commands, oldest first, then owed ones (late rows).
    /// 4. Nobody (an unsolicited row).
    private func receive(_ chunk: ELMChunk) {
        for reply in framer.append(chunk) {
            if !desynchronised, !owedPrompts.isEmpty {
                payOwedPrompt(reply)
                continue
            }
            if let flight = inFlight, flight.resolution == nil, accept(reply, by: flight) { continue }
            payLateOrUnsolicited(reply)
        }
    }

    /// Whether the command in flight takes `reply` (resolving with it, or
    /// holding it for `ATZ`'s banner decision).
    ///
    /// Banner-shaped text (contains `ELM`, or `isBannerCandidate`) only ever
    /// answers a banner command (`ATZ`, `ATI`, `AT@1`). A late banner from a
    /// written-off `ATZ` arriving while, say, `ATE0` waits is therefore never
    /// taken as `ATE0`'s reply, so the handshake can't be shifted by one.
    private func accept(_ reply: ELMRawReply, by flight: InFlight) -> Bool {
        let hasELM = reply.text.uppercased().contains("ELM")
        let bannerShaped = hasELM || Self.isBannerCandidate(reply.text, command: flight.wire)
        switch flight.acceptance {
        case .any:
            if bannerShaped, !Self.bannerCommands.contains(flight.wire) { return false }
            resolve(flight.token, with: .reply(reply))
            return true
        case .banner(let waitFullWindow):
            if hasELM, !waitFullWindow {
                releaseBannerCandidates(choosing: false)
                resolve(flight.token, with: .reply(reply))
                return true
            }
            guard bannerShaped else { return false }
            // Held until an ELM banner (or, waiting the full window, the
            // timeout) decides.
            inFlight?.bannerCandidates.append(reply)
            return true
        }
    }

    private func payOwedPrompt(_ reply: ELMRawReply) {
        let owed = owedPrompts.removeFirst()
        recordLateReply(owed, text: reply.text, completedUptime: reply.completedUptime)
        if owedPrompts.isEmpty { finishOwedWait(nil, drained: true) }
    }

    /// A reply no command in flight takes: the oldest written-off command's,
    /// else the oldest owed one's, else unsolicited.
    private func payLateOrUnsolicited(_ reply: ELMRawReply) {
        if !writtenOff.isEmpty {
            recordLateReply(writtenOff.removeFirst(), text: reply.text, completedUptime: reply.completedUptime)
        } else if !owedPrompts.isEmpty {
            payOwedPrompt(reply)
        } else {
            recordUnsolicited(text: reply.text, completedUptime: reply.completedUptime)
        }
    }

    /// `ATZ` was answered with a banner: replies line up with commands again.
    /// Written-off commands still unpaid lost their replies to the reset.
    private func resynchronised() {
        desynchronised = false
        writtenOff.removeAll()
    }

    private func transportDidClose() {
        guard !transportClosed, !isShutdown else { return }
        transportClosed = true
        stopRequested = true
        pollTask?.cancel()
        rateTask?.cancel()
        rateTask = nil
        abandonInFlight(with: .closed)
        finishOwedWait(nil, drained: false)
        recordPendingPartialReply()
        releaseAllWaiters()
        setState(.failed, reason: "transport closed")
        continuation.finish()
    }

    /// Ends the command in flight without its reply (shutdown, link loss):
    /// a final `timeout` exchange without `rx`, completed now, so every sent
    /// command has a row. Partial text received for it follows as a late row.
    private func abandonInFlight(with resolution: Resolution) {
        guard let flight = inFlight, flight.resolution == nil else { return }
        releaseBannerCandidates(choosing: false)
        let now = uptime.uptimeSeconds
        let requestUptime = flight.requestUptime
        emitExchange(
            phase: flight.phase,
            tx: flight.wire,
            requestUptime: requestUptime,
            rx: nil,
            completedUptime: now,
            outcome: .timeout
        )
        owedPrompts.append(SentCommand(tx: flight.wire, phase: flight.phase, requestUptime: requestUptime))
        resolve(flight.token, with: resolution)
    }

    /// The late `>` for a command that already timed out: a `timeout`
    /// exchange with `rx`, attributed to that command.
    private func recordLateReply(_ owed: SentCommand, text: String, completedUptime: Double) {
        emitExchange(
            phase: owed.phase,
            tx: owed.tx,
            requestUptime: owed.requestUptime,
            rx: text,
            completedUptime: completedUptime,
            outcome: .timeout
        )
    }

    /// Output no command is waiting for: `timeout` with `rx` and empty `tx`.
    private func recordUnsolicited(text: String, completedUptime: Double) {
        emitExchange(
            phase: lastSent?.phase ?? .initialisation,
            tx: "",
            requestUptime: completedUptime,
            rx: text,
            completedUptime: completedUptime,
            outcome: .timeout
        )
    }

    /// Bytes received without a prompt are kept too: attributed to the
    /// oldest owed command if any, else unsolicited.
    private func recordPendingPartialReply() {
        let text = framer.pendingText
        framer.reset()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let now = uptime.uptimeSeconds
        // Oldest first: written-off commands were sent before any owed one.
        if let owed = writtenOff.first ?? owedPrompts.first {
            recordLateReply(owed, text: text, completedUptime: now)
        } else {
            recordUnsolicited(text: text, completedUptime: now)
        }
    }

    /// Waits up to the grace period for owed prompts; writes off the ones
    /// that don't come, with a note, so the next command starts clean.
    private func settleOwedPrompts() async {
        guard !owedPrompts.isEmpty else { return }
        let grace = configuration.effectiveLatePromptGrace
        if await waitForOwedPrompts(grace) { return }
        guard !owedPrompts.isEmpty, !isShutdown, !transportClosed else { return }
        let lost = owedPrompts.map(\.tx).joined(separator: ", ")
        // Their replies may still come: until an ATRV sync proves the
        // stream aligned, nothing that arrives may resolve a command.
        writtenOff += owedPrompts
        owedPrompts.removeAll()
        desynchronised = true
        noteState(reason: "no prompt for \(lost) within \(grace) of its timeout; written off")
    }

    /// True when every owed prompt arrived within `grace`.
    private func waitForOwedPrompts(_ grace: Duration) async -> Bool {
        nextToken += 1
        let token = nextToken
        let wait = clock.sleeper(untilAfter: grace)
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let timer = Task { [weak self] in
                do {
                    try await wait()
                } catch {
                    return
                }
                await self?.finishOwedWait(token, drained: false)
            }
            owedWaiter = (token, continuation, timer)
        }
    }

    /// Resumes the owed-prompt wait; `token` nil matches any wait.
    private func finishOwedWait(_ token: UInt64?, drained: Bool) {
        guard let waiter = owedWaiter, token == nil || waiter.token == token else { return }
        owedWaiter = nil
        waiter.timer.cancel()
        waiter.continuation.resume(returning: drained)
    }

    /// Before `ATZ`: half-received text belongs to the adapter's previous
    /// life. Keep it, then start the framer clean. Written-off commands stay
    /// listed until `ATZ` is answered, so late replies arriving during the
    /// reset are still attributed to them.
    private func prepareForReset() {
        recordPendingPartialReply()
    }

    // MARK: Events

    private func setState(_ new: ELMState, reason: String?) {
        guard new != state else { return }
        let old = state
        state = new
        continuation.yield(.state(from: old, to: new, reason: reason, uptime: uptime.uptimeSeconds))
    }

    /// Records something about the link without a state change: a `.state`
    /// event with `from == to`.
    private func noteState(reason: String) {
        continuation.yield(.state(from: state, to: state, reason: reason, uptime: uptime.uptimeSeconds))
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
