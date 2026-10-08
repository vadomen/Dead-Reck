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
///      → searching (0100) → initialising (ATDPN, ATRV[, ATSH7E0]) → probing → ready
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
/// ## Addressing and start-up selection
///
/// From the bench test (docs/BENCH_TEST_2026-10-07.md): functional requests
/// (`7DF`) are answered by the engine (`7E8`) and the gearbox (`7E9`), and
/// with the response-count suffix the adapter keeps the first reply, which
/// was the gearbox's.
/// - After `ATRV` the handshake sends `ATSH7E0`, **only** if `ATDPN`
///   reported 11-bit ISO 15765-4 CAN (`6`, `A6`, `8`, `A8`) and the `0100`
///   reply had a positive `7E8` line (`ELM327Command.physicalAddressing`
///   explains why: elsewhere `ATSH7E0` is not the engine's request ID).
///   Otherwise it is skipped, with a `.state` note (`from == to`)
///   `ATSH7E0 skipped: protocol <n> is not 11-bit ISO 15765-4 CAN (6, A6,
///   8, A8); …` or `ATSH7E0 skipped: no 7E8 reply to 0100; …`, both ending
///   `requests stay functional (7DF), no response-count suffix`. The gate
///   is re-evaluated on every handshake, re-inits included.
/// - `ATSH7E0` answered `OK` → requests go to the engine alone (physical
///   addressing). Anything else → requests stay functional, with a note
///   `ATSH7E0 not accepted (<outcome>); requests stay functional (7DF), no
///   response-count suffix`, and init carries on. A late `OK` (paid within
///   the grace period on a trusted link) counts, with a note `late OK for
///   ATSH7E0; requests go to 7E0`. `ATZ` returns the adapter to functional.
/// - Start-up selection (`probing`) tries, in order, `010D0C1` → `010D0C`
///   → `010D1` → `010D` (single-PID steps also send `010C1` / `010C`) and
///   takes the first whose every sample carries the primary ECU's value for
///   every requested PID. Under functional addressing the suffix steps are
///   skipped: `010D0C` → `010D`. Selection sends each command
///   `probeSamples` (3) times.
/// - **`ATAT1` unless `ATAT2` is clearly better** (M4 bench: a 3-sample
///   probe flipped to `ATAT2` on a 4.6 ms edge that the steady state did not
///   show). The chosen command is sent `adaptiveTimingSamples` (10) times at
///   `ATAT1`, then 10 times at `ATAT2`, back to back. `ATAT2` is kept only
///   if all 10 replies parse with the primary ECU's value for every PID (a
///   reply cut short rejects it) and its **median** cost is at least
///   `adaptiveTimingMinimumGain` (10%) below `ATAT1`'s; otherwise the
///   adapter goes back to `ATAT1`. About 20 extra polls, ~1.2 s at the bench
///   car's 60 ms. A note (`from == to`) records the decision: `adaptive
///   timing: ATAT2 kept, median <a> ms at ATAT2 vs <b> ms at ATAT1 (10
///   samples each; ATAT2 must be at least 10% lower)`, the same with `ATAT1 kept, …`,
///   `adaptive timing: ATAT1 kept, ATAT2 replies did not parse`, `adaptive
///   timing: ATAT1 kept, ATAT2 not accepted (<outcome>)`, or `adaptive
///   timing: ATAT1 kept, ATAT1 replies did not parse in the timing
///   comparison; ATAT2 not tried`.
/// - Physical addressing is abandoned if it reaches nothing: when no step
///   parses under `7E0` (or the only one that does has lost vehicle speed
///   to the NO DATA rule), the session sends `ATSH7DF` (phase `probe`) and
///   runs selection again functionally, starting from the full PID list,
///   with a note `no poll command parsed with physical addressing (7E0);
///   selecting again with functional addressing (7DF), no response-count
///   suffix`. An `ATSH7DF` that times out still counts if its late `OK`
///   arrives within the grace period. One that is refused, or never
///   answered, leaves the adapter physical: the session notes `no poll
///   command parsed with physical addressing (7E0); ATSH7DF not accepted
///   (<outcome>); physical addressing disabled for this session;
///   re-initialising without ATSH7E0`, re-runs the handshake from `ATZ`
///   (which skips `ATSH7E0` with `ATSH7E0 skipped: physical addressing
///   disabled for this session: …`) and then selects functionally. The
///   disable lasts for the session: every later handshake skips `ATSH7E0`.
/// - Nothing parses → `PollingPlan.baseline`: functional, no suffix. The
///   plan records the addressing (`requestHeader`).
/// - The response-count suffix is never sent unless `ATSH7E0` was answered
///   `OK`: `PollingPlan.validate()` requires a `requestHeader` for it, the
///   poll loop sends `ATSH<header>` (phase `poll`) whenever the adapter's
///   addressing differs from the plan's — after every re-init too, since
///   `ATZ` resets it — and polls only once that is answered `OK`, and a
///   suffixed poll with the adapter functional is refused like a rejected
///   session command (`rejected` exchange, `failed`). Before comparing,
///   the loop lets owed prompts settle (B1-3, R2.1-2): a late `ATSH` `OK`
///   changes the addressing, so it must land before the decision, not
///   between the decision and the poll.
/// - **Selected and polled plan.** `startPolling`'s plan is kept as given;
///   the plan polled is derived from it and the gate, at `startPolling` and
///   after every successful re-init (R2.2-1, R2.2-2). Gate closed → the
///   physical plan is polled functionally without the suffix, with a note
///   `physical addressing unavailable: <cause>; polling with functional
///   addressing (7DF), no response-count suffix`. Gate open again at a
///   later re-init → the physical plan is polled again, with a note
///   `physical addressing available again; polling <command> at 7E0`. An
///   `.adapter` event follows every change, and none ever announces a plan
///   that isn't the one polled.
/// - While polling, a functional plan restores its addressing with
///   `ATSH7DF`; if the adapter refuses it (it accepted `ATSH7E0` at the
///   re-init), physical addressing is disabled for the session and the
///   session re-initialises at once, so `ATZ` makes it functional again
///   (R2.2-3). A physical plan whose `ATSH7E0` is refused fails like any
///   poll (retry → re-init → `failed` + `needsReconnect`).
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
///   answers a command. Late replies are routed by shape (M1-E4): a
///   banner-shaped one only to a banner command (`ATZ`, `ATI`, `AT@1`) —
///   unsolicited if none is pending — anything else to the oldest
///   non-banner command first; written-off commands before owed ones. The
///   link is trusted again once `ATZ` is answered with a banner, from the
///   actor step that takes the banner. How each caller gets there:
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

    /// Probe samples per candidate command during selection (does it parse
    /// from the primary ECU?); their median latency is the candidate's cost.
    static let probeSamples = 3

    /// Samples per timing level when `ATAT2` is compared with `ATAT1`: the
    /// chosen command is sent this many times at `ATAT1`, then this many at
    /// `ATAT2`, back to back. Ten each costs about 1.2 s at the bench car's
    /// 60 ms per poll. The 3 selection samples are not reused: the first
    /// poll after a header change can be slow, and one slow sample in three
    /// is what flipped the bench re-init to `ATAT2` (M4).
    static let adaptiveTimingSamples = 10

    /// `ATAT2` is kept only if its median cost is at least this fraction
    /// below `ATAT1`'s (`isClearlyFaster`). The bench car's steady state was
    /// identical at both levels (59.3 vs 59.2 ms median), so a smaller edge
    /// is noise, and `ATAT2` risks replies cut short for no gain.
    static let adaptiveTimingMinimumGain = 0.10

    /// Whether a median cost of `atat2` at `ATAT2` beats `atat1` at `ATAT1`
    /// by at least `adaptiveTimingMinimumGain`.
    static func isClearlyFaster(_ atat2: Double, than atat1: Double) -> Bool {
        atat2 <= atat1 * (1 - adaptiveTimingMinimumGain)
    }

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
    /// What requests go out with, as far as the session knows: functional
    /// from the moment `ATZ` is sent, physical once an `ATSH` is answered
    /// `OK`. Never physical without that `OK`.
    private var requestHeader = CANRequestHeader.functional
    /// Why a physical header may not be sent now; nil once the last
    /// handshake's gate passed. Closed from the moment `ATZ` is sent.
    private var physicalAddressingBlocked: String? = "no handshake yet"
    /// Set when the adapter accepted `ATSH7E0` but refused (or lost)
    /// `ATSH7DF`: physical addressing could not be undone, so the gate stays
    /// closed for the rest of this session and every handshake skips
    /// `ATSH7E0` (R2.2-3).
    private var physicalAddressingDisabled: String?
    private var initialised = false
    /// What the last successful handshake found.
    private var adapterFacts: HandshakeResult?
    /// PIDs that have answered OK (poll or probe) in this session.
    private var okPIDs: Set<OBDPID> = []
    /// Mode 01 commands (wire) that have answered OK in this session.
    private var okCommands: Set<String> = []
    private var initTask: Task<Result<ELMAdapterInfo, ELMSessionError>, Never>?

    // MARK: Polling state

    /// The plan `startPolling` was given. Never downgraded: the plan polled
    /// (`plan`) is derived from it and the gate at every (re-)init, so
    /// physical addressing lost at one re-init comes back at the next one
    /// that reopens the gate (R2.2-2).
    private var selectedPlan: PollingPlan?
    /// The plan being polled: `selectedPlan` through `effective(_:)`.
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
    /// → `ATRV` → `ATSH7E0` (only on 11-bit ISO 15765-4 CAN with a `7E8`
    /// reply to `0100`), then (if configured) start-up selection: the first
    /// of `010D0C1` → `010D0C` → `010D1` → `010D` that parses (suffix steps
    /// only if `ATSH7E0` was answered `OK`; functionally again if nothing
    /// parses physically), at `ATAT1` unless `ATAT2` is clearly faster
    /// (`adaptiveTimingSamples`, `adaptiveTimingMinimumGain`). See
    /// "Addressing and start-up selection".
    ///
    /// `ATZ` waits up to `resetTimeout`, the `0100` search `searchTimeout`,
    /// everything else `commandTimeout`. A failed step throws
    /// `.initFailed(step:reason:)` (reason = the exchange outcome) and leaves
    /// the session `failed`; a missing `ATRV` voltage and a refused `ATSH7E0`
    /// (or one skipped by the gate) are not failures. Stops polling first if
    /// it was running. Concurrent calls share one run.
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
    /// plan's `requestHeader` (nil = `7DF`) differs from the adapter's,
    /// `ATSH<header>` is sent first, then `ATATn` if the plan's
    /// `adaptiveTiming` differs (both phase `poll`), and again after every
    /// re-init. A poll goes out only once both are answered `OK`.
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
        selectedPlan = plan
        self.plan = effective(plan)
        activePIDs = plan.pids
        multiPIDActive = plan.multiPID
        // A physical plan on a closed gate is noted and never announced
        // (R2.2-1): the `adapter` row below already carries the functional
        // plan actually polled.
        if plan.requestHeader != nil, self.plan?.requestHeader == nil, let cause = physicalAddressingBlocked {
            noteState(reason: Self.physicalAddressingUnavailable(cause))
        }
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
        try await applyPhysicalAddressingIfAllowed(result)
        adapterFacts = result
        return result
    }

    /// The handshake's last, conditional step: `ATSH7E0` if the gate passes
    /// (`physicalAddressingSkipReason`), else a note. Neither a skip nor a
    /// refusal fails init.
    private func applyPhysicalAddressingIfAllowed(_ found: HandshakeResult) async throws(ELMSessionError) {
        let command = ELM327Command.physicalAddressing
        guard case .setHeader(let header) = command else { return }
        let disabled = physicalAddressingDisabled.map { "physical addressing disabled for this session: \($0)" }
        if let cause = disabled
            ?? Self.physicalAddressingCause(protocolNumber: found.protocolNumber, supportedPIDs: found.supportedPIDs) {
            physicalAddressingBlocked = cause
            noteState(reason: "\(command.wireFormat) skipped: \(cause); " + Self.staysFunctional)
            return
        }
        physicalAddressingBlocked = nil
        let headers = headersOn
        let (exchange, value) = try await perform(command, phase: .initialisation, timeout: configuration.commandTimeout) { raw in
            Self.interpretInit(command, raw: raw, headers: headers)
        }
        if value != nil {
            requestHeader = header
        } else {
            noteState(reason: "\(command.wireFormat) not accepted (\(exchange.outcome.rawValue)); " + Self.staysFunctional)
        }
    }

    static let staysFunctional = "requests stay functional (\(CANRequestHeader.functional)), no response-count suffix"

    /// The note written when a physical plan is polled functionally because
    /// the gate is closed.
    static func physicalAddressingUnavailable(_ cause: String) -> String {
        "physical addressing unavailable: \(cause); polling with functional addressing "
            + "(\(CANRequestHeader.functional)), no response-count suffix"
    }

    /// `plan` as it may be polled now: unchanged while the gate is open, else
    /// functional without the response-count suffix.
    private func effective(_ plan: PollingPlan) -> PollingPlan {
        guard plan.requestHeader != nil, physicalAddressingBlocked != nil else { return plan }
        var functional = plan
        functional.requestHeader = nil
        functional.responseCount = nil
        return functional
    }

    /// Re-derives the plan polled from `selectedPlan` after a successful
    /// re-init, noting a change of addressing either way. The caller
    /// announces the result.
    private func rederivePlan() {
        guard let selectedPlan else { return }
        let before = plan
        plan = effective(selectedPlan)
        guard let now = plan, before?.requestHeader != now.requestHeader else { return }
        if let header = now.requestHeader {
            let command = currentPlan?.primaryCommand.wireFormat ?? now.primaryCommand.wireFormat
            noteState(reason: "physical addressing available again; polling \(command) at \(header)")
        } else if let cause = physicalAddressingBlocked {
            noteState(reason: Self.physicalAddressingUnavailable(cause))
        }
    }

    /// Protocols on which `ATSH7E0` is the 11-bit OBD request ID `7E0`:
    /// ISO 15765-4 CAN 11-bit at 500 or 250 kbaud, auto-detected or not.
    static let elevenBitCANProtocols: Set<String> = ["6", "A6", "8", "A8"]

    /// Why `ATSH7E0` must not be sent, or nil if it may: `protocolNumber`
    /// (`ATDPN`) must be 11-bit ISO 15765-4 and `supportedPIDs` (the raw
    /// `0100` reply, headers on) must contain a positive `41 00` line from
    /// `7E8`.
    static func physicalAddressingCause(protocolNumber: String, supportedPIDs: String?) -> String? {
        let number = String(protocolNumber.filter { !$0.isWhitespace }).uppercased()
        guard elevenBitCANProtocols.contains(number) else {
            return "protocol \(protocolNumber) is not 11-bit ISO 15765-4 CAN (6, A6, 8, A8)"
        }
        let replies = supportedPIDs.flatMap { try? ELM327ResponseParser.replies(in: $0, headers: true) } ?? []
        guard replies.contains(where: { $0.header == "7E8" && $0.bytes.starts(with: [0x41, 0x00]) }) else {
            return "no 7E8 reply to 0100"
        }
        return nil
    }

    /// The note recorded when the gate skips `ATSH7E0`, or nil if it passes.
    static func physicalAddressingSkipReason(protocolNumber: String, supportedPIDs: String?) -> String? {
        physicalAddressingCause(protocolNumber: protocolNumber, supportedPIDs: supportedPIDs).map {
            "\(ELM327Command.physicalAddressing.wireFormat) skipped: \($0); " + staysFunctional
        }
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
            case (.echo, .ok), (.lineFeeds, .ok), (.spaces, .ok), (.headers, .ok), (.autoProtocol, .ok),
                 (.setHeader, .ok):
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

    /// One start-up selection step: PIDs in one request or singly, with or
    /// without the response-count suffix.
    private struct Candidate: Equatable {
        var multiPID: Bool
        var responseCount: Int?
    }

    private enum CandidateResult {
        /// Every sample of every command parsed with `7E8`'s values.
        /// `cost` is the latency per speed sample.
        case valid(cost: Double)
        case invalid
        /// The plain single request for this PID answered `NO DATA` and the
        /// PID has never answered OK: the NO DATA rule drops it.
        case drop(OBDPID)
    }

    /// Selection order: `010D0C1` → `010D0C` → `010D1` → `010D`. Multi-PID
    /// steps need two PIDs; suffix steps need physical addressing.
    private static func candidates(pidCount: Int, physical: Bool) -> [Candidate] {
        let order: [Candidate] = [
            Candidate(multiPID: true, responseCount: 1),
            Candidate(multiPID: true, responseCount: nil),
            Candidate(multiPID: false, responseCount: 1),
            Candidate(multiPID: false, responseCount: nil),
        ]
        return order.filter { candidate in
            (!candidate.multiPID || pidCount > 1) && (candidate.responseCount == nil || physical)
        }
    }

    /// Start-up selection (see the type's doc).
    ///
    /// A pass (`select`) takes the first candidate in `candidates` order
    /// that parses at `ATAT1`. With physical addressing the first pass runs
    /// under `7E0`; if it finds nothing, or only a plan without vehicle
    /// speed, `ATSH7DF` is sent and a second pass runs functionally. Each
    /// pass starts from the full PID list, so a PID dropped under `7E0` gets
    /// a fresh chance. The NO DATA rule is unchanged and session-wide: a PID
    /// that answered OK under either addressing (or in an earlier
    /// `initialise()`) is in `okPIDs` and never dropped; one that has only
    /// ever answered NO DATA is dropped by the functional pass only if it
    /// answers NO DATA there too.
    ///
    /// The chosen candidate is then timed at `ATAT1` and at `ATAT2`
    /// (`finishSelection`); `ATAT2` is kept only if clearly faster. Cost per
    /// speed sample, from median latencies: `latency(all)` for multi-PID,
    /// `latency(speed) + latency(others) / rpmEvery` for single PIDs.
    /// Nothing parses → the functional baseline.
    /// Leaves the adapter at the chosen timing level. The addressing is
    /// read after `ATAT1`, which settles a late `ATSH7E0` reply.
    private func probe() async throws(ELMSessionError) -> PollingPlan {
        _ = try await setAdaptiveTiming(1, phase: .probe)
        if let header = planHeader {
            let physical = try await select(physical: true)
            if let chosen = physical.chosen, physical.pids.first == PollingPlan.baseline.pids.first {
                return try await finishSelection(chosen, pids: physical.pids, header: header)
            }
            let outcome = try await setRequestHeader(.functional, phase: .probe)
            // A timed-out ATSH7DF may still be answered: wait out its grace
            // period, so a late OK counts (it sets the header itself).
            if outcome == .timeout { try await settleOwedPromptsInSlot() }
            if requestHeader == .functional {
                noteState(
                    reason: "no poll command parsed with physical addressing (\(header)); "
                        + "selecting again with functional addressing (7DF), no response-count suffix"
                )
            } else {
                // Refused, or lost (written off: only ATZ may go out now).
                // ATZ is the one sure way back to functional; the gate stays
                // closed for the session so no handshake re-sends ATSH7E0.
                let refusal = "ATSH7DF not accepted (\(outcome.rawValue))"
                physicalAddressingDisabled = refusal
                noteState(
                    reason: "no poll command parsed with physical addressing (\(header)); \(refusal); "
                        + "physical addressing disabled for this session; re-initialising without ATSH7E0"
                )
                _ = try await runHandshake(tracksStates: true)
                setState(.probing, reason: nil)
                _ = try await setAdaptiveTiming(1, phase: .probe)
            }
        }
        let functional = try await select(physical: false)
        guard let chosen = functional.chosen else {
            return fallbackPlan(pids: functional.pids.isEmpty ? PollingPlan.baseline.pids : functional.pids)
        }
        return try await finishSelection(chosen, pids: functional.pids, header: nil)
    }

    private struct Selection {
        /// The PIDs left after NO DATA drops.
        var pids: [OBDPID]
        var chosen: (candidate: Candidate, cost: Double)?
    }

    /// One selection pass from the full PID list.
    private func select(physical: Bool) async throws(ELMSessionError) -> Selection {
        let rpmEvery = PollingPlan.baseline.rpmEvery
        var pids = PollingPlan.baseline.pids
        selection: while !pids.isEmpty {
            for candidate in Self.candidates(pidCount: pids.count, physical: physical) {
                switch try await measure(candidate, pids: pids, rpmEvery: rpmEvery, mayDrop: true) {
                case .valid(let cost):
                    return Selection(pids: pids, chosen: (candidate, cost))
                case .drop(let pid):
                    pids.removeAll { $0 == pid }
                    continue selection
                case .invalid:
                    continue
                }
            }
            break
        }
        return Selection(pids: pids, chosen: nil)
    }

    /// `ATAT2` against `ATAT1` for the chosen candidate, then the plan.
    ///
    /// The candidate is sent `adaptiveTimingSamples` times at `ATAT1` (where
    /// the adapter is after selection), then, if `ATAT2` is answered `OK`,
    /// as many times at `ATAT2`. `ATAT2` is kept only if every sample parsed
    /// with the primary ECU's value for every PID and its median cost is at
    /// least `adaptiveTimingMinimumGain` below `ATAT1`'s
    /// (`isClearlyFaster`); otherwise the adapter goes back to `ATAT1`. The
    /// decision is recorded as a note (`.state`, `from == to`) starting
    /// `adaptive timing: `.
    private func finishSelection(
        _ chosen: (candidate: Candidate, cost: Double),
        pids: [OBDPID],
        header: CANRequestHeader?
    ) async throws(ELMSessionError) -> PollingPlan {
        let rpmEvery = PollingPlan.baseline.rpmEvery
        let samples = Self.adaptiveTimingSamples
        var level = 1
        var sentATAT2 = false
        let note: String
        if case .valid(let atat1) = try await measure(
            chosen.candidate, pids: pids, rpmEvery: rpmEvery, mayDrop: false, samples: samples
        ) {
            let outcome = try await setAdaptiveTiming(2, phase: .probe)
            sentATAT2 = true
            if outcome != .ok {
                note = "ATAT1 kept, ATAT2 not accepted (\(outcome.rawValue))"
            } else if case .valid(let atat2) = try await measure(
                chosen.candidate, pids: pids, rpmEvery: rpmEvery, mayDrop: false, samples: samples
            ) {
                let comparison = "median \(Self.milliseconds(atat2)) at ATAT2 vs \(Self.milliseconds(atat1)) at ATAT1 "
                    + "(\(samples) samples each; ATAT2 must be at least \(Int((Self.adaptiveTimingMinimumGain * 100).rounded()))% lower)"
                if Self.isClearlyFaster(atat2, than: atat1) {
                    level = 2
                    note = "ATAT2 kept, " + comparison
                } else {
                    note = "ATAT1 kept, " + comparison
                }
            } else {
                note = "ATAT1 kept, ATAT2 replies did not parse"
            }
        } else {
            note = "ATAT1 kept, ATAT1 replies did not parse in the timing comparison; ATAT2 not tried"
        }
        // Back to ATAT1 after any ATAT2 that wasn't kept: a timed-out ATAT2
        // may still have taken effect.
        if adaptiveTimingLevel != level || (sentATAT2 && level == 1) {
            _ = try await setAdaptiveTiming(level, phase: .probe)
        }
        noteState(reason: "adaptive timing: " + note)
        return PollingPlan(
            pids: pids,
            multiPID: chosen.candidate.multiPID,
            responseCount: chosen.candidate.responseCount,
            adaptiveTiming: level,
            rpmEvery: rpmEvery,
            timeout: configuration.commandTimeout,
            requestHeader: header
        )
    }

    /// Sends a candidate's commands, `samples` times each, stopping at the
    /// first that doesn't parse. Each command's cost is its median latency.
    private func measure(
        _ candidate: Candidate,
        pids: [OBDPID],
        rpmEvery: Int,
        mayDrop: Bool,
        samples: Int = probeSamples
    ) async throws(ELMSessionError) -> CandidateResult {
        if candidate.multiPID {
            let command = ELM327Command.currentDataMany(pids, responseCount: candidate.responseCount)
            guard case .valid(let latency) = try await measure(command, pids: pids, samples: samples) else { return .invalid }
            return .valid(cost: latency)
        }
        var latencies: [Double] = []
        for pid in pids {
            switch try await measure(.currentDataMany([pid], responseCount: candidate.responseCount), pids: [pid], samples: samples) {
            case .valid(let latency):
                latencies.append(latency)
            case .noData where mayDrop && candidate.responseCount == nil && isDroppableOnNoData(pid):
                // The one NO DATA rule: never answered OK → drop.
                return .drop(pid)
            case .noData, .invalid:
                // A PID that has answered OK keeps its place; this step
                // just doesn't count.
                return .invalid
            }
        }
        return .valid(cost: latencies[0] + latencies.dropFirst().reduce(0, +) / Double(rpmEvery))
    }

    /// The adapter's addressing as a plan field: the physical header, or
    /// nil for functional.
    private var planHeader: CANRequestHeader? {
        requestHeader.isPhysical ? requestHeader : nil
    }

    /// `PollingPlan.baseline` with `pids` and the configured command timeout:
    /// functional, no suffix, whatever the adapter's addressing (the poll
    /// loop sends `ATSH7DF` if it is physical).
    private func fallbackPlan(pids: [OBDPID]) -> PollingPlan {
        var plan = PollingPlan.baseline
        plan.pids = pids
        plan.timeout = configuration.commandTimeout
        return plan
    }

    /// `command` sent `samples` times; its median latency, or why not.
    private func measure(_ command: ELM327Command, pids: [OBDPID], samples: Int) async throws(ELMSessionError) -> ProbeResult {
        var latencies: [Double] = []
        for _ in 0..<max(samples, 1) {
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
        return .valid(latency: Self.median(latencies))
    }

    /// Median of a non-empty list; the mean of the middle two for an even
    /// count.
    static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count % 2 == 0 ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }

    /// Seconds as milliseconds with one decimal, for notes: `59.3 ms`.
    static func milliseconds(_ seconds: Double) -> String {
        String(format: "%.1f ms", seconds * 1_000)
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

    /// Sends `ATSH<header>`; on `OK` records the adapter's new addressing.
    private func setRequestHeader(_ header: CANRequestHeader, phase: ELMPhase) async throws(ELMSessionError) -> ELMOutcome {
        let command = ELM327Command.setHeader(header)
        let wire = command.wireFormat
        let (exchange, _) = try await perform(command, phase: phase, timeout: configuration.commandTimeout) { raw in
            Self.interpretAcknowledgement(raw, wire: wire)
        }
        if exchange.outcome == .ok { requestHeader = header }
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
        /// Re-initialise now, without spending retries (reason).
        case reinitialise(String)
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
                    // Let late prompts land before comparing the adapter's
                    // addressing with the plan's: a late ATSH OK changes it
                    // (B1-3, R2.1-2). Nothing after this can: only polls and
                    // manual commands (never ATSH) go out until the next
                    // iteration.
                    do throws(ELMSessionError) {
                        try await settleOwedPromptsInSlot()
                    } catch {
                        // Only a closed or shut-down session throws here.
                        break cycles
                    }
                    // Never a physical header while the gate is closed: the
                    // plan becomes functional, and the cycle is rebuilt
                    // without the suffix. Unreachable while `plan` is
                    // re-derived at every re-init; kept as a defence.
                    if plan.requestHeader != nil, let cause = physicalAddressingBlocked {
                        abandonPhysicalAddressing(because: cause)
                        continue cycles
                    }
                    let step: PollStep
                    let header = plan.requestHeader ?? .functional
                    if requestHeader != header {
                        step = await applyPlanHeader(header)
                        if case .success = step { continue attempts }
                    } else if adaptiveTimingLevel != plan.adaptiveTiming {
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
                    case .reinitialise(let reason):
                        guard await reinitialiseForPolling(after: reason) else { break cycles }
                    case .ended:
                        break cycles
                    }
                    // A re-init may have changed the plan polled (the gate
                    // closed or reopened): rebuild the cycle from it.
                    if self.plan != plan { continue cycles }
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
        // The suffix with functional addressing keeps whichever ECU answers
        // first. validate() and the loop's ATSH step make this unreachable;
        // a plan pushed past validate() still never gets it onto the wire.
        if case .currentDataMany(_, .some) = command, !requestHeader.isPhysical {
            emitRejection(phase: .poll, tx: command.wireFormat)
            stopRequested = true
            setState(
                .failed,
                reason: "\(command.wireFormat) refused: the response-count suffix needs physical addressing "
                    + "(ATSH7E0 answered OK); requests are functional"
            )
            return .ended
        }
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

    /// The plan in use becomes functional without the suffix; noted and
    /// re-announced.
    private func abandonPhysicalAddressing(because cause: String) {
        plan?.requestHeader = nil
        plan?.responseCount = nil
        noteState(reason: Self.physicalAddressingUnavailable(cause))
        emitCurrentAdapterInfo()
    }

    /// `ATSH<header>` from the poll loop. A refused `ATSH7DF` means the
    /// adapter took `ATSH7E0` but won't go back: physical addressing is
    /// disabled for the session and the session re-initialises at once, so
    /// `ATZ` restores functional addressing and no handshake re-sends
    /// `ATSH7E0` (R2.2-3). A timeout is an ordinary failure: its late OK may
    /// still settle it.
    private func applyPlanHeader(_ header: CANRequestHeader) async -> PollStep {
        do {
            let outcome = try await setRequestHeader(header, phase: .poll)
            if outcome == .ok { return .success }
            if header == .functional, outcome != .timeout {
                let refusal = "ATSH\(header) not accepted (\(outcome.rawValue))"
                physicalAddressingDisabled = refusal
                return .reinitialise("\(refusal); physical addressing disabled for this session; re-initialising without ATSH7E0")
            }
            return .failure("ATSH\(header): \(outcome.rawValue)")
        } catch {
            return step(for: error)
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
                // The gate was re-evaluated: derive the plan polled from the
                // selected one before announcing it (R2.2-1, R2.2-2).
                rederivePlan()
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
            resynchronised()
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
                resynchronised()
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

    /// A reply no command in flight takes: a late row for the command that
    /// most plausibly produced it (`takeLateOwner`), else unsolicited.
    private func payLateOrUnsolicited(_ reply: ELMRawReply) {
        if let owner = takeLateOwner(for: reply.text) {
            recordLateReply(owner, text: reply.text, completedUptime: reply.completedUptime)
        } else {
            recordUnsolicited(text: reply.text, completedUptime: reply.completedUptime)
        }
    }

    /// Removes and returns the command a late reply belongs to, routed by
    /// shape (M1-E4), oldest first, written-off commands before owed ones:
    /// - banner-shaped text (contains `ELM`, or `isBannerCandidate`) goes
    ///   only to a banner command (`ATZ`, `ATI`, `AT@1`); with none pending
    ///   it is unsolicited — a data command never prints a banner, and an
    ///   adapter that rebooted on its own does;
    /// - anything else goes to the oldest non-banner command, else to the
    ///   oldest command of any kind.
    private func takeLateOwner(for text: String) -> SentCommand? {
        let banner = text.uppercased().contains("ELM") || Self.isBannerCandidate(text, command: "")
        func isMatch(_ sent: SentCommand) -> Bool { Self.bannerCommands.contains(sent.tx) == banner }
        if let index = writtenOff.firstIndex(where: isMatch) { return writtenOff.remove(at: index) }
        if let index = owedPrompts.firstIndex(where: isMatch) { return takeOwed(at: index) }
        guard !banner else { return nil }
        if !writtenOff.isEmpty { return writtenOff.removeFirst() }
        if !owedPrompts.isEmpty { return takeOwed(at: owedPrompts.startIndex) }
        return nil
    }

    private func takeOwed(at index: Int) -> SentCommand {
        let owed = owedPrompts.remove(at: index)
        if owedPrompts.isEmpty { finishOwedWait(nil, drained: true) }
        return owed
    }

    /// `ATZ` was answered with a banner: replies line up with commands again.
    /// Written-off commands still unpaid lost their replies to the reset.
    /// Called in the actor step that resolves the `ATZ` (M1-E4), so output
    /// arriving right behind the banner, before `run()` resumes, is already
    /// unsolicited rather than paid to a written-off command.
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
    ///
    /// An `ATZ` waiting out its full window may hold banners. They are paid
    /// only after the `ATZ` itself is recorded as owed (M1-E4), so its own
    /// banner becomes its late row instead of an unsolicited one.
    private func abandonInFlight(with resolution: Resolution) {
        guard let flight = inFlight, flight.resolution == nil else { return }
        let held = flight.bannerCandidates
        inFlight?.bannerCandidates = []
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
        for reply in held { payLateOrUnsolicited(reply) }
        resolve(flight.token, with: resolution)
    }

    /// The late `>` for a command that already timed out: a `timeout`
    /// exchange with `rx`, attributed to that command.
    ///
    /// A late `OK` for an `ATSH` on a trusted link means the adapter did
    /// switch headers: believe it, with a note, so the plan's recorded
    /// addressing stays true. While desynchronised nothing is believed; the
    /// coming `ATZ` resets the addressing anyway.
    private func recordLateReply(_ owed: SentCommand, text: String, completedUptime: Double) {
        emitExchange(
            phase: owed.phase,
            tx: owed.tx,
            requestUptime: owed.requestUptime,
            rx: text,
            completedUptime: completedUptime,
            outcome: .timeout
        )
        if !desynchronised, owed.tx.hasPrefix("ATSH"),
           let header = CANRequestHeader(rawValue: String(owed.tx.dropFirst(4))),
           (try? ELM327ResponseParser.textReply(to: owed.tx, raw: text)) == .ok {
            requestHeader = header
            noteState(reason: "late OK for \(owed.tx); requests go to \(header)")
        }
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
        // Same routing as a complete late reply: by shape, oldest first,
        // written-off commands (sent before any owed one) first.
        if let owner = takeLateOwner(for: text) {
            recordLateReply(owner, text: text, completedUptime: now)
        } else {
            recordUnsolicited(text: text, completedUptime: now)
        }
    }

    /// `settleOwedPrompts` under the command slot, without sending anything:
    /// for decisions that depend on what a late reply may still change (the
    /// adapter's addressing). Throws only if the session is closed.
    private func settleOwedPromptsInSlot() async throws(ELMSessionError) {
        guard !owedPrompts.isEmpty else { return }
        try await acquireSlot()
        defer { releaseSlot() }
        await settleOwedPrompts()
        try checkOpen()
    }

    /// Waits up to the grace period for owed prompts; writes off the ones
    /// that don't come, with a note, so the next command starts clean.
    private func settleOwedPrompts() async {
        guard !owedPrompts.isEmpty else { return }
        let grace = configuration.effectiveLatePromptGrace
        if await waitForOwedPrompts(grace) { return }
        guard !owedPrompts.isEmpty, !isShutdown, !transportClosed else { return }
        let lost = owedPrompts.map(\.tx).joined(separator: ", ")
        // Their replies may still come: until ATZ is answered with a banner,
        // nothing that arrives may resolve a command.
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
        // The adapter resets on receipt; until an ATSH is answered OK again,
        // requests are functional, and until the handshake's gate passes
        // again no physical header may be sent.
        requestHeader = .functional
        physicalAddressingBlocked = "adapter reset; handshake not finished"
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
