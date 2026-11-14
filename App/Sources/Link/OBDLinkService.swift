import DriveLoggerCore
import Foundation
import Observation

/// Delay before reconnect attempt `n` (1-based): `initial × 2^(n−1)`, capped
/// at `maximum`. The attempt count resets on the first successful poll of a
/// connection (R3.1-5), not when its initialisation succeeds.
struct ReconnectBackoff: Hashable, Sendable {
    var initial: Duration
    var maximum: Duration

    init(initial: Duration = .seconds(1), maximum: Duration = .seconds(30)) {
        self.initial = initial
        self.maximum = maximum
    }

    static let `default` = ReconnectBackoff()

    func delay(forAttempt attempt: Int) -> Duration {
        let exponent = min(max(attempt, 1) - 1, 16)
        return min(initial * (1 << exponent), maximum)
    }
}

/// `OBDLinkServicing` over a `BLECentralClient`: CoreBluetooth on the
/// device (`BLECentral`), `MockELMAdapter` behind `SimulatedOBDLink`.
///
/// ## BLE link state machine
///
/// Recorded as `LinkEvent.ble` with the frozen `LinkSample.BLEState` names,
/// stamped with the uptime the BLE layer read in its delegate callback:
///
/// ```
/// unavailable ⇄ idle                         (Bluetooth off/on)
/// idle → scanning → idle                     (startScan / stopScan)
/// idle|scanning|restoring → connecting       (connect, remembered adapter at launch)
/// connecting → discovering → connected       (didConnect, UART pair + notifications)
/// connected|discovering|connecting → disconnected
///     (link lost, connect failed, the ELM session asked for a reconnect,
///     discovery and notify-enable didn't finish within `discoveryTimeout`,
///     or CoreBluetooth didn't answer a connect within `connectTimeout`)
/// disconnected → reconnecting → connecting   (after the backoff delay, or
///     at once when the connect already pending for the attempt answers)
/// reconnecting → disconnected                (that pending connect failed)
/// idle → restoring                           (relaunched by the system with our adapter)
/// any → idle                                 (disconnect / forget, or an unusable GATT layout)
/// ```
///
/// `ble` rows with `from == to` are notes, not transitions: `write failed:
/// <error>` when CoreBluetooth rejects an acknowledged write (R3.1-6).
/// A disconnect this service asked for (`.cancelled`) is never a link loss:
/// it only reaches the console (R3.1-3).
///
/// ## Connect attempts
///
/// While an adapter is wanted (`target`) and Bluetooth is on, a
/// CoreBluetooth connect is pending at every moment the link isn't up: a
/// pending connect survives the app being suspended in the background and
/// wakes it when the adapter answers; a Swift timer may not fire there.
/// The one window with no pending connect follows an immediate rejection
/// by CoreBluetooth (below); never a link loss or a watchdog timeout.
/// - Each `central.connect` is one attempt with its own `generation`; BLE
///   events of any other generation (a late `.cancelled`, `.disconnected`,
///   `.connectFailed`, `.connected` or `.ready` of an attempt this service
///   cancelled) never end, start or pass for the current one: console only.
/// - A link loss, a failed initialisation, the session's `needsReconnect`
///   and a discovery timeout re-issue the connect at once; the backoff
///   (`ReconnectBackoff`) only decides when the attempt is reported as
///   `reconnecting → connecting` (`reconnect attempt <n>`) and its connect
///   watchdog started — earlier if the pending connect answers first.
/// - Spaced cycles: when the connection being dropped never had a
///   successful poll (its initialisation failed, or the session asked for
///   a reconnect before any poll answered), the connect is still issued at
///   once, but a connection it makes before the backoff ends is held:
///   recorded as a note (`reconnect attempt <n>: connected, held until the
///   backoff ends`), its discovery result kept, and only when the backoff
///   ends does it go `reconnecting → connecting → discovering` and start
///   a session. A broken adapter that is present therefore initialises at
///   most once per backoff delay (1 s, 2 s, … 30 s), while the link is
///   never without a pending connect or a held connection. A held
///   connection that drops is connected again at once. A link loss after
///   a successful poll is not spaced: the next session starts as soon as
///   the adapter answers.
/// - Connect watchdog: a `connecting` that CoreBluetooth hasn't answered
///   within `connectTimeout` (10 s) ends as `connecting → disconnected`
///   (`<attempt>: no answer in <t>, cancelled and re-issued`): the connect
///   is cancelled and a new one issued in the same step, then the next
///   attempt's `→ reconnecting` row. One cycle is backoff + `connectTimeout`
///   (11 s, 12 s, 14 s, 18 s, 26 s, then 40 s). Every `connecting` has it:
///   reconnects, a pick, the remembered adapter at launch, restoration.
/// - A failed connect (`didFailToConnect`) is an answer, not silence, and
///   may repeat at once (pairing removed, an unknown peripheral): it is
///   re-issued at once only if it had been pending at least the next
///   backoff delay, else when that delay ends, so it can never spin. That
///   wait is the only time no connect is pending; repeated rejections write
///   one attempt's rows per backoff delay, no more.
///
/// ## Sessions and reconnects
///
/// - One `ELMSession` per connection, created when the transport is ready
///   and seeded with the previous session's `nextSeq`, read after that
///   session has shut down and its last event has been forwarded — so
///   `seq` is unique and increasing for the whole recording.
/// - The same way, the previous session's `rememberedPlan` (poll plan with
///   its `ATAT` level and `requestHeader`, the `ATZ` banner and the vehicle
///   key it was chosen on) seeds the next session **on the same adapter**
///   (peripheral identifier), which then skips start-up selection and the
///   `ATAT1`/`ATAT2` comparison if the plan still fits (same banner, same
///   vehicle: M7.1-3) and its check poll passes (M6.1-3; `ELMSession`,
///   "Remembered poll plan"). A session started on a different adapter
///   clears it, and so does `forget()`; `disconnect()` keeps it. A session
///   whose polling failed (`needsReconnect`) hands over nil, so the
///   reconnect selects again (M7.1-2). In memory only, for this app session.
/// - Reconnect on a link loss, a failed connect, a failed initialisation (a
///   write error during the handshake included: BLE stays up then), the
///   session's `needsReconnect`, and when GATT discovery stalls (R3.1-7:
///   `discoveryTimeout`, 10 s, from `→ discovering` to `.ready`). The
///   CoreBluetooth connect is pending at once (only an immediate rejection
///   by CoreBluetooth leaves a gap, see "Connect attempts"); the backoff
///   (`ReconnectBackoff`, 1 s doubling to 30 s) spaces the reported
///   attempts, the connect watchdog, and full cycles after a connection
///   that never polled. The attempt counter resets on the connection's
///   first successful poll (R3.1-5), so a link that initialises but never
///   polls still backs off.
/// - Every session event and BLE transition goes to the `linkEvents()`
///   subscriber, in the order this service handles them, and to the console.
/// - The current connection's `→ connected` and its latest initialisation
///   are also kept in `lastInitEvents`, returned only while BLE is
///   `connected` (see `OBDLinkServicing.lastInitEvents` for contents,
///   lifetime and the recorder's dedup contract).
@MainActor
@Observable
class OBDLinkService: OBDLinkServicing, OBDLinkHolding {
    static let restoreIdentifier = "DriveLogger.OBDLink"
    static let rememberedAdapterKey = "OBDLink.rememberedAdapterID"
    static let rememberedAdapterNameKey = "OBDLink.rememberedAdapterName"
    static let consoleLimit = 500
    /// Default bound of `lastInitEvents`.
    static let defaultInitEventLimit = 1_000
    /// Default `discoveryTimeout`.
    static let defaultDiscoveryTimeout: Duration = .seconds(10)
    /// Default `connectTimeout`: a connect to an advertising adapter
    /// normally completes within 1–2 s; 10 s leaves room for a slow
    /// advertising interval without leaving a dead connect pending for long.
    static let defaultConnectTimeout: Duration = .seconds(10)

    private(set) var state: OBDLinkState = .idle
    private(set) var discovered: [DiscoveredAdapter] = []
    private(set) var rememberedAdapterID: UUID?
    private(set) var rememberedAdapterName: String?
    private(set) var adapter: AdapterRecord?
    private(set) var plan: PollingPlan?
    private(set) var pollHz: Double = 0
    private(set) var console: [ConsoleLine] = []
    /// The BLE layer's state, as written in `link` rows.
    private(set) var bleState: LinkSample.BLEState = .idle
    /// REL-DEMO: the demo drive runs, so this link stays down
    /// (`holdForDemo()`); nothing connects, reconnects or autoconnects until
    /// `releaseDemoHold()`. Memory only.
    private(set) var isHeldForDemo = false

    /// See `OBDLinkServicing.lastInitEvents`. Empty unless BLE is
    /// `connected` (M6.1-1).
    var lastInitEvents: [LinkEvent] { bleState == .connected ? initCapture.events : [] }
    /// See `OBDLinkServicing.deliveredLinkEventCount`.
    @ObservationIgnored private(set) var deliveredLinkEventCount = 0

    /// A poll plan remembered for one adapter (peripheral identifier).
    struct RememberedPollPlan: Hashable {
        var adapterID: UUID
        var plan: RememberedPollingPlan
    }

    /// The plan the next session on `adapterID` tries before selecting
    /// (M6.1-3; `ELMSession` "Remembered poll plan"). Taken from each
    /// session when it retires, like `nextSeq`; cleared when a session
    /// starts on a different adapter and by `forget()`. Memory only, for
    /// this app session. Internal for tests.
    @ObservationIgnored private(set) var rememberedPollPlan: RememberedPollPlan?
    /// Bumped by `forget()`, so a session retired after it can't store its
    /// plan again.
    @ObservationIgnored private var pollPlanEpoch = 0
    /// The current session's adapter and the `pollPlanEpoch` it started in.
    @ObservationIgnored private var sessionAdapter: (id: UUID, epoch: Int)?

    @ObservationIgnored private let central: any BLECentralClient
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let uptime: any UptimeSource
    @ObservationIgnored private let sessionConfiguration: ELMSessionConfiguration
    @ObservationIgnored private let backoff: ReconnectBackoff
    @ObservationIgnored private let discoveryTimeout: Duration
    @ObservationIgnored private let connectTimeout: Duration
    /// Drives the service's timers (backoff, watchdogs) and its sessions'
    /// timeouts; never timestamps (those come from `uptime`).
    @ObservationIgnored private let clock: any Clock<Duration>
    /// Ends a `discovering` that never reaches `.ready` (R3.1-7). Cancelled
    /// when BLE leaves `discovering`.
    @ObservationIgnored private var discoveryWatchdog: Task<Void, Never>?
    /// Replaces a connect CoreBluetooth hasn't answered within
    /// `connectTimeout`. Cancelled when BLE leaves `connecting`.
    @ObservationIgnored private var connectWatchdog: Task<Void, Never>?
    /// The current connect attempt: bumped by every `central.connect` and
    /// every `central.cancelConnection` of the target, so BLE events of an
    /// earlier attempt never match (`BLECentralEvent`).
    @ObservationIgnored private var generation = 0
    /// A connect issued in `generation` that hasn't been answered or
    /// cancelled yet.
    @ObservationIgnored private var connectPending = false
    /// When the latest connect was issued (uptime seconds).
    @ObservationIgnored private var connectIssuedAt = 0.0
    /// The reconnect under way spaces full cycles: a connection made before
    /// its backoff ends is held ("Connect attempts", spaced cycles).
    @ObservationIgnored private var spacedCycle = false
    /// A connection made during a spaced backoff, with its `.ready` once
    /// discovery is done; resumed when the backoff ends.
    @ObservationIgnored private var heldConnection: (connectedAt: Double, ready: (link: BLELinkReady, at: Double)?)?
    /// The current connection's session has answered a poll with a value.
    @ObservationIgnored private var linkPolled = false
    @ObservationIgnored private var centralTask: Task<Void, Never>?
    @ObservationIgnored private var subscriber: AsyncStream<LinkEvent>.Continuation?
    /// The adapter the user wants connected; nil after `disconnect()`.
    @ObservationIgnored private var target: UUID?
    @ObservationIgnored private var available = false
    @ObservationIgnored private var wantsScan = false
    @ObservationIgnored private var attempt = 0
    @ObservationIgnored private var reconnectTask: Task<Void, Never>?
    /// Changes whenever a connection's transport is handed over or dropped;
    /// events and init results of an older connection don't touch the UI
    /// state any more (they are still forwarded and logged).
    @ObservationIgnored private var linkToken = 0
    @ObservationIgnored private var session: ELMSession?
    @ObservationIgnored private var sessionTask: Task<Void, Never>?
    @ObservationIgnored private var retiring: Task<Void, Never>?
    /// The retire started by the latest `dropLink()`; see
    /// `sessionsRetired()`.
    @ObservationIgnored private var lastDrop: Task<Void, Never>?
    @ObservationIgnored private var nextSeq = 0
    /// The init-and-poll run in progress, tagged with its connection's
    /// `linkToken`. A `reinitialise()` on the same connection while it runs
    /// waits for it instead of starting a second (R3.1-4). Cleared by the
    /// run itself when it ends.
    @ObservationIgnored private var initRun: (token: Int, id: Int, task: Task<Void, Never>)?
    @ObservationIgnored private var nextInitRunID = 0
    /// What the BLE layer knows about the connected adapter.
    @ObservationIgnored private var bleRecord: AdapterRecord?
    @ObservationIgnored private var lastInfo: ELMAdapterInfo?
    @ObservationIgnored private var nextConsoleID = 0
    @ObservationIgnored private var initCapture: InitCapture
    /// The adapter to connect to when the demo hold ends: the target when
    /// the hold began, or one picked during it; nil after a `disconnect()`
    /// or `forget()` during it.
    @ObservationIgnored private var demoHeldTarget: UUID?

    /// - Parameters:
    ///   - central: nil creates the CoreBluetooth `BLECentral` with
    ///     `restoreIdentifier` — create the service at launch so state
    ///     restoration finds it.
    ///   - defaults: where `rememberedAdapterID` is kept.
    ///   - uptime: stamps the service's own transitions and the sessions;
    ///     the same timebase as the transport.
    ///   - initEventLimit: bound of `lastInitEvents`; smaller in tests.
    ///   - discoveryTimeout: longest time from `→ discovering` (connected)
    ///     to the UART pair being ready; after it the connection is
    ///     cancelled and retried with backoff (R3.1-7).
    ///   - connectTimeout: longest time a `connecting` waits for
    ///     CoreBluetooth to answer before the connect is cancelled and
    ///     re-issued ("Connect attempts").
    ///   - clock: drives the backoff, the watchdogs and the sessions'
    ///     timeouts; a test clock runs them without real waits.
    init(
        central: (any BLECentralClient)? = nil,
        defaults: UserDefaults = .standard,
        uptime: any UptimeSource = SystemUptimeSource(),
        sessionConfiguration: ELMSessionConfiguration = .default,
        backoff: ReconnectBackoff = .default,
        initEventLimit: Int = OBDLinkService.defaultInitEventLimit,
        discoveryTimeout: Duration = OBDLinkService.defaultDiscoveryTimeout,
        connectTimeout: Duration = OBDLinkService.defaultConnectTimeout,
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.central = central ?? BLECentral(restoreIdentifier: Self.restoreIdentifier, uptime: uptime)
        self.defaults = defaults
        self.uptime = uptime
        self.sessionConfiguration = sessionConfiguration
        self.backoff = backoff
        self.discoveryTimeout = discoveryTimeout
        self.connectTimeout = connectTimeout
        self.clock = clock
        initCapture = InitCapture(limit: initEventLimit)
        rememberedAdapterID = defaults.string(forKey: Self.rememberedAdapterKey).flatMap(UUID.init(uuidString:))
        // A name is only meaningful next to its id.
        if rememberedAdapterID != nil {
            rememberedAdapterName = defaults.string(forKey: Self.rememberedAdapterNameKey)
        }
        // Reconnected automatically once Bluetooth is on.
        target = rememberedAdapterID
        let events = self.central.events
        centralTask = Task { [weak self] in
            for await event in events {
                guard let self else { return }
                self.handle(event)
            }
        }
    }

    // MARK: OBDLinkServicing

    func startScan() {
        wantsScan = true
        discovered = []
        guard available else { return }
        central.startScan()
        if bleState == .idle {
            transition(to: .scanning, reason: nil)
            state = .scanning
        }
    }

    func stopScan() {
        wantsScan = false
        central.stopScan()
        if bleState == .scanning {
            transition(to: .idle, reason: nil)
            state = .idle
        }
    }

    func connect(to id: UUID) {
        stopScan()
        if isHeldForDemo {
            // Picked while the demo drive runs: remembered now, connected
            // when the hold ends.
            remember(id)
            demoHeldTarget = id
            return
        }
        if let target, target != id { disconnect() }
        remember(id)
        let busy: Set<LinkSample.BLEState> = [.connecting, .discovering, .connected, .reconnecting, .restoring]
        if target == id, busy.contains(bleState) { return }
        target = id
        attempt = 0
        guard available else { return }   // connects on poweredOn
        connectNow(id, reason: "adapter \(name(of: id)) picked")
    }

    func disconnect() {
        // The user's choice outlasts the demo: nothing reconnects after it.
        demoHeldTarget = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        connectWatchdog?.cancel()
        connectWatchdog = nil
        heldConnection = nil
        spacedCycle = false
        attempt = 0
        let id = target
        target = nil
        dropLink()
        if let id { cancelAttempt(id) }
        if bleState != .unavailable {
            transition(to: .idle, reason: "disconnected by the user")
            state = .idle
        }
    }

    /// REL-DEMO: takes the link down for the demo drive and holds it there.
    /// Like `disconnect()` (session dropped, connection cancelled, backoff
    /// cancelled, the adapter stays remembered), but the adapter it was
    /// connected or connecting to is kept for `releaseDemoHold()`, and
    /// while held nothing connects: no autoconnect on Bluetooth on or state
    /// restoration (they need a target), no reconnect, and `connect(to:)`
    /// only remembers its pick for later. Idempotent.
    func holdForDemo() {
        guard !isHeldForDemo else { return }
        isHeldForDemo = true
        demoHeldTarget = target
        reconnectTask?.cancel()
        reconnectTask = nil
        connectWatchdog?.cancel()
        connectWatchdog = nil
        heldConnection = nil
        spacedCycle = false
        attempt = 0
        target = nil
        dropLink()
        if let id = demoHeldTarget { cancelAttempt(id) }
        if ![.idle, .scanning, .unavailable].contains(bleState) {
            transition(to: .idle, reason: "held for the demo drive")
            state = .idle
        }
    }

    /// REL-DEMO: ends the hold; the adapter held (or picked during the
    /// hold) is connected again as at launch, now or on Bluetooth on.
    /// Nothing happens without one (none was wanted, or the user
    /// disconnected or forgot it during the hold). Idempotent.
    func releaseDemoHold() {
        guard isHeldForDemo else { return }
        isHeldForDemo = false
        guard let id = demoHeldTarget else { return }
        demoHeldTarget = nil
        target = id
        attempt = 0
        guard available, [.idle, .scanning].contains(bleState) else { return }   // connects on poweredOn
        connectNow(id, reason: "demo drive ended")
    }

    func forget() {
        disconnect()
        rememberedPollPlan = nil
        pollPlanEpoch += 1
        rememberedAdapterID = nil
        defaults.removeObject(forKey: Self.rememberedAdapterKey)
        setRememberedName(nil)
    }

    func sendManual(_ command: String) async throws(ELMSessionError) -> ELMExchange {
        guard let session else {
            // Same answer as the session would give for a forbidden command,
            // even with nothing connected.
            _ = try ELMCommandPolicy.validate(command, scope: .manual)
            throw .notInitialised
        }
        let token = linkToken
        do throws(ELMSessionError) {
            return try await session.sendManual(command)
        } catch {
            if case .desynchronised = error, token == linkToken {
                let polling = if case .polling = state { true } else { false }
                appendConsole(
                    .status,
                    "link desynchronised (a reply went missing): "
                        + (polling ? "re-initialising by itself" : "re-initialising") + "; retry when polling",
                    uptime.uptimeSeconds
                )
                // While polling the session re-initialises by itself.
                if !polling { Task { await self.reinitialise() } }
            }
            throw error
        }
    }

    func reinitialise() async {
        guard let session, bleState == .connected else { return }
        await initialiseAndPoll(session, token: linkToken)
    }

    func linkEvents() -> AsyncStream<LinkEvent> {
        subscriber?.finish()
        let (stream, continuation) = AsyncStream.makeStream(of: LinkEvent.self)
        subscriber = continuation
        deliveredLinkEventCount = 0
        return stream
    }

    /// Yields to the `linkEvents()` subscriber, counting what it accepted.
    private func deliver(_ event: LinkEvent) {
        if case .enqueued = subscriber?.yield(event) {
            deliveredLinkEventCount += 1
        }
    }

    // MARK: BLE events

    private func handle(_ event: BLECentralEvent) {
        switch event {
        case .availability(let availability, let at):
            handleAvailability(availability, at: at)
        case .restored(let ids, let at):
            guard let target, ids.contains(target), bleState == .idle || bleState == .unavailable else { return }
            transition(to: .restoring, reason: "relaunched by the system with the adapter", uptime: at)
        case .discovered(let found):
            discovered.removeAll { $0.id == found.id }
            discovered.append(found)
            discovered.sort(by: Self.listOrder)
        case .connected(let id, let generation, let at):
            guard id == target, [.connecting, .reconnecting, .restoring].contains(bleState) else { return }
            guard generation == self.generation else {
                staleAttempt("connected", generation: generation, at: at)
                return
            }
            connectPending = false
            if bleState == .reconnecting, spacedCycle {
                // A spaced cycle: the next session waits for the backoff.
                heldConnection = (at, nil)
                note("reconnect attempt \(attempt): connected, held until the backoff ends", uptime: at)
                return
            }
            if bleState == .reconnecting {
                // The connect pending for this attempt answered before its
                // backoff ended.
                reconnectTask?.cancel()
                reconnectTask = nil
                transition(to: .connecting, reason: "reconnect attempt \(attempt)", uptime: at)
            }
            transition(to: .discovering, reason: nil, uptime: at)
            state = .discoveringServices
            startDiscoveryWatchdog(for: id)
        case .connectFailed(let id, let generation, let reason, let at):
            guard id == target, [.connecting, .reconnecting].contains(bleState) else { return }
            guard generation == self.generation else {
                staleAttempt("connect failed", generation: generation, at: at)
                return
            }
            connectPending = false
            // Re-issued at once only after a failure that took at least the
            // next backoff delay; a quick one waits for it, so it can't spin.
            let pendingFor = at - connectIssuedAt
            let nextDelay = backoff.delay(forAttempt: attempt + 1)
            transition(to: .disconnected, reason: reason ?? "connect failed", uptime: at)
            scheduleReconnect(connectNow: pendingFor >= Self.seconds(nextDelay), spaced: spacedCycle)
        case .ready(let link, let at):
            if bleState == .reconnecting, heldConnection != nil, link.id == target, link.generation == generation {
                heldConnection?.ready = (link, at)
                return
            }
            guard link.id == target, link.generation == generation,
                  [.connecting, .discovering, .restoring].contains(bleState) else {
                if link.id == target {
                    // A connection this service has cancelled already.
                    staleAttempt("ready", generation: link.generation, at: at)
                } else {
                    central.cancelConnection(link.id)
                }
                return
            }
            let gatt = link.selection
            transition(
                to: .connected,
                reason: "\(gatt.service) notify \(gatt.notify) write \(gatt.write) \(gatt.writeType), \(gatt.maxWriteLength) B",
                uptime: at
            )
            bleRecord = AdapterRecord(
                name: link.name, identifier: link.id.uuidString, gatt: link.selection, gattTable: link.table
            )
            if link.id == rememberedAdapterID, !link.name.isEmpty { setRememberedName(link.name) }
            startSession(on: link.transport, adapterID: link.id)
        case .unusable(let id, let generation, _, let reason, let at):
            guard id == target else { return }
            guard generation == self.generation else {
                staleAttempt("unusable", generation: generation, at: at)
                return
            }
            // Not retried: the adapter's GATT layout doesn't change between
            // attempts. The table is in the console line.
            transition(to: .disconnected, reason: reason, uptime: at)
            target = nil
            dropLink()
            cancelAttempt(id)
            transition(to: .idle, reason: "no usable UART characteristics; pick another adapter")
            state = .failed(reason: reason)
        case .disconnected(let id, let generation, let reason, let at):
            if bleState == .reconnecting, heldConnection != nil, id == target, generation == self.generation {
                // The held connection dropped: connect again at once; the
                // backoff still spaces the next session.
                heldConnection = nil
                note("held connection lost (\(reason ?? "link lost")); connect re-issued", uptime: at)
                issueConnect(id)
                return
            }
            guard id == target, [.connecting, .discovering, .connected, .restoring].contains(bleState) else { return }
            guard generation == self.generation else {
                staleAttempt("disconnected (\(reason ?? "link lost"))", generation: generation, at: at)
                return
            }
            connectPending = false
            transition(to: .disconnected, reason: reason ?? "link lost", uptime: at)
            dropLink()
            scheduleReconnect()
        case .cancelled(_, _, let at):
            // The disconnect this service asked for. It may land after the
            // reconnect has started; it is not that connection's loss (R3.1-3),
            // and its generation is never the current one.
            appendConsole(.status, "ble: requested disconnect completed", at)
        case .writeFailed(let id, let reason, let at):
            guard id == target else {
                appendConsole(.status, "ble: write failed: \(reason)", at)
                return
            }
            note("write failed: \(reason)", uptime: at)
        }
    }

    private func handleAvailability(_ availability: BLEAvailability, at: Double) {
        switch availability {
        case .poweredOn:
            available = true
            if bleState == .unavailable {
                transition(to: .idle, reason: "Bluetooth on", uptime: at)
                state = .idle
            }
            if wantsScan, bleState == .idle {
                central.startScan()
                transition(to: .scanning, reason: nil, uptime: at)
                state = .scanning
            }
            if let target, [.idle, .scanning, .restoring].contains(bleState) {
                connectNow(target, reason: bleState == .restoring ? "restoring" : "remembered adapter")
            }
        case .unavailable(let reason):
            available = false
            reconnectTask?.cancel()
            reconnectTask = nil
            connectWatchdog?.cancel()
            connectWatchdog = nil
            // Every connection and pending connect is gone with it.
            connectPending = false
            heldConnection = nil
            generation += 1
            dropLink()
            transition(to: .unavailable, reason: reason, uptime: at)
            state = .unavailable(reason: reason)
        }
    }

    private func startDiscoveryWatchdog(for id: UUID) {
        discoveryWatchdog?.cancel()
        let timeout = discoveryTimeout
        let wait = clock.linkSleeper(after: timeout)
        discoveryWatchdog = Task { [weak self] in
            try? await wait()
            guard !Task.isCancelled, let self, self.target == id, self.bleState == .discovering else { return }
            // Not `unusable`: a missed callback says nothing about the
            // adapter's layout, so this is retried like a link loss.
            self.transition(to: .disconnected, reason: "GATT discovery timed out after \(timeout)")
            self.dropLink()
            self.cancelAttempt(id)
            self.scheduleReconnect()
        }
    }

    /// `connecting` with a bounded wait: the connect pending for this
    /// attempt (a reconnect's, issued with its `→ reconnecting`), or a new
    /// one.
    private func connectNow(_ id: UUID, reason: String?) {
        transition(to: .connecting, reason: reason)
        state = attempt > 0 ? .reconnecting(attempt: attempt) : .connecting
        if !connectPending { issueConnect(id) }
        startConnectWatchdog(for: id)
    }

    private func issueConnect(_ id: UUID) {
        generation += 1
        connectPending = true
        connectIssuedAt = uptime.uptimeSeconds
        central.connect(id, generation: generation)
    }

    /// Ends the current attempt: its pending connect or connection is
    /// cancelled, and its late events no longer match.
    private func cancelAttempt(_ id: UUID) {
        generation += 1
        connectPending = false
        central.cancelConnection(id)
    }

    /// No answer from CoreBluetooth within `connectTimeout`: cancel the
    /// connect and issue the next attempt's in the same step, so a connect
    /// stays pending even if this app is suspended before the backoff ends.
    private func startConnectWatchdog(for id: UUID) {
        connectWatchdog?.cancel()
        let timeout = connectTimeout
        let watched = generation
        let label = attempt > 0 ? "reconnect attempt \(attempt)" : "connect"
        let wait = clock.linkSleeper(after: timeout)
        connectWatchdog = Task { [weak self] in
            try? await wait()
            guard !Task.isCancelled, let self, self.target == id, self.bleState == .connecting,
                  self.generation == watched, self.available else { return }
            self.transition(to: .disconnected, reason: "\(label): no answer in \(timeout), cancelled and re-issued")
            self.cancelAttempt(id)
            self.scheduleReconnect()
        }
    }

    /// The next attempt: its connect is issued now (unless `connectNow` is
    /// false, after a quick connect failure), and it is reported as
    /// `reconnecting → connecting` after the backoff delay, or as soon as
    /// that connect answers.
    private func scheduleReconnect(connectNow issue: Bool = true, spaced: Bool = false) {
        heldConnection = nil
        spacedCycle = spaced
        guard let target else {
            transition(to: .idle, reason: nil)
            state = .idle
            return
        }
        attempt += 1
        let attempt = attempt
        let delay = backoff.delay(forAttempt: attempt)
        let issuing = issue && available && !connectPending
        transition(
            to: .reconnecting,
            reason: "attempt \(attempt) in \(delay)" + (issuing || connectPending ? ", connect pending" : "")
                + (spaced ? ", next session after the backoff" : "")
        )
        state = .reconnecting(attempt: attempt)
        if issuing { issueConnect(target) }
        reconnectTask?.cancel()
        let wait = clock.linkSleeper(after: delay)
        reconnectTask = Task { [weak self] in
            try? await wait()
            guard !Task.isCancelled, let self, self.target == target, self.bleState == .reconnecting, self.available else {
                return
            }
            if let held = self.heldConnection {
                self.resumeHeld(held, id: target)
            } else {
                self.connectNow(target, reason: "reconnect attempt \(attempt)")
            }
        }
    }

    /// The spaced backoff ended with a connection held: report it and go on
    /// as if it had just connected (and, if discovery is done, become ready).
    private func resumeHeld(_ held: (connectedAt: Double, ready: (link: BLELinkReady, at: Double)?), id: UUID) {
        heldConnection = nil
        spacedCycle = false
        transition(to: .connecting, reason: "reconnect attempt \(attempt)")
        transition(to: .discovering, reason: nil)
        state = .discoveringServices
        startDiscoveryWatchdog(for: id)
        if let ready = held.ready { handle(.ready(ready.link, uptime: uptime.uptimeSeconds)) }
    }

    /// The ELM side asked for a fresh connection (`needsReconnect`, or
    /// initialisation failed): drop the BLE link and reconnect with backoff.
    /// Only from `connected`, so a second request while a reconnect is
    /// under way adds no attempt.
    private func requestReconnect(reason: String) {
        guard let target, bleState == .connected else { return }
        // A connection that never answered a poll: space the next full
        // cycle, so a broken adapter can't re-initialise in a fast loop.
        let spaced = !linkPolled
        transition(to: .disconnected, reason: reason)
        dropLink()
        cancelAttempt(target)
        scheduleReconnect(spaced: spaced)
    }

    /// A BLE event of an attempt this service has already cancelled or
    /// replaced: console only; it neither ends nor starts the current one.
    private func staleAttempt(_ what: String, generation: Int, at: Double) {
        appendConsole(.status, "ble: \(what) of an earlier attempt ignored (generation \(generation), current \(self.generation))", at)
    }

    private nonisolated static func seconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) * 1e-18
    }

    // MARK: ELM sessions

    private func startSession(on transport: any ELMTransport, adapterID: UUID) {
        linkToken += 1
        let token = linkToken
        linkPolled = false
        initCapture.sessionStarted(token: token)
        state = .initialising
        Task {
            // The previous connection's session must be gone, and its last
            // `seq` and remembered plan known, before this one starts.
            await retireSession()
            guard token == linkToken else { return }
            // A plan chosen on another adapter is never offered.
            if rememberedPollPlan?.adapterID != adapterID { rememberedPollPlan = nil }
            let session = ELMSession(
                transport: transport,
                configuration: sessionConfiguration,
                uptime: uptime,
                clock: clock,
                firstSeq: nextSeq,
                rememberedPlan: rememberedPollPlan?.plan
            )
            self.session = session
            sessionAdapter = (adapterID, pollPlanEpoch)
            let events = session.events
            // Ends when the session's events finish (shutdown or link loss).
            sessionTask = Task {
                for await event in events {
                    self.handleSession(event, token: token)
                }
            }
            await initialiseAndPoll(session, token: token)
        }
    }

    /// Initialises `session` and starts polling — or, if a run for this
    /// connection is already going (the first one after connecting, or an
    /// earlier `reinitialise()`), waits for that one. `ELMSession.initialise()`
    /// shares concurrent calls too, but each caller would then call
    /// `startPolling`: the second gets `.notInitialised` and its error path
    /// reconnected a healthy link (R3.1-4). Registering is synchronous, so
    /// there is no window for a second run.
    private func initialiseAndPoll(_ session: ELMSession, token: Int) async {
        if let run = initRun, run.token == token {
            await run.task.value
            return
        }
        nextInitRunID += 1
        let id = nextInitRunID
        let task = Task {
            await self.runInitialiseAndPoll(session, token: token)
            // Cleared here, not by the awaiting caller, so a reinitialise()
            // after the run ends can't join a finished run.
            if self.initRun?.id == id { self.initRun = nil }
        }
        initRun = (token, id, task)
        await task.value
    }

    private func runInitialiseAndPoll(_ session: ELMSession, token: Int) async {
        do throws(ELMSessionError) {
            let info = try await session.initialise()
            guard token == linkToken else { return }
            // `attempt` is not reset here but on the first successful poll
            // (`handleSession`): init can pass on a link where every poll
            // then fails, and that cycle must back off too (R3.1-5).
            try await session.startPolling(info.plan)
        } catch {
            guard token == linkToken else { return }
            switch error {
            case .cancelled, .transport(.disconnected), .transport(.notConnected):
                // Link loss (or shutdown): the BLE layer reports it and the
                // `.disconnected` handler reconnects.
                return
            default:
                // Everything else, `.transport(.writeFailed)` included (R3.1-1):
                // BLE may still be connected and no `.disconnected` will come,
                // so drop the connection and reconnect from here.
                appendConsole(.status, "init failed: \(error)", uptime.uptimeSeconds)
                requestReconnect(reason: "initialisation failed: \(error)")
            }
        }
    }

    /// Stops using the current connection: UI state no longer follows its
    /// session, which is shut down in the background (`retireSession`).
    private func dropLink() {
        linkToken += 1
        pollHz = 0
        lastDrop = Task { await retireSession() }
    }

    /// Returns once every session dropped so far has been retired (its
    /// `nextSeq` and remembered plan taken, or not, per `pollPlanEpoch`):
    /// `retireSession` waits for every retire before it. For tests: a
    /// deterministic wait instead of a sleep (M7.1-6).
    func sessionsRetired() async {
        await lastDrop?.value
    }

    /// Shuts the current session down, waits until its last event has been
    /// forwarded, and keeps its `nextSeq` and its remembered plan (unless
    /// `forget()` came after it started). Concurrent calls share one run.
    private func retireSession() async {
        if let old = session {
            session = nil
            let consumer = sessionTask
            sessionTask = nil
            let adapter = sessionAdapter
            sessionAdapter = nil
            let previous = retiring
            retiring = Task {
                await previous?.value
                await old.shutdown()
                await consumer?.value
                self.nextSeq = max(self.nextSeq, await old.nextSeq)
                let plan = await old.rememberedPlan
                if let adapter, adapter.epoch == self.pollPlanEpoch {
                    self.rememberedPollPlan = plan.map { RememberedPollPlan(adapterID: adapter.id, plan: $0) }
                }
            }
        }
        await retiring?.value
    }

    private func handleSession(_ event: ELMSessionEvent, token: Int) {
        let current = token == linkToken
        if current {
            switch event {
            case .state(let from, let to, let reason, _) where from != to:
                applySessionState(to, reason: reason)
            case .adapter(let info, _):
                lastInfo = info
                var record = bleRecord ?? AdapterRecord(name: "", identifier: "")
                record.elmVersion = info.elmVersion
                record.protocolNumber = info.protocolNumber
                record.voltage = info.voltage
                adapter = record
                plan = info.plan
                if case .polling = state { state = .polling(protocolNumber: info.protocolNumber, voltage: info.voltage) }
            case .pollRate(let hz, _):
                pollHz = hz
            case .reading:
                // A poll answered with a value (only `ok` polls yield
                // readings; the plan's own `ATSH`/`ATAT` exchanges are poll
                // phase too, but prove nothing): the link works end to end,
                // so the next loss starts the backoff from 1 s again (R3.1-5).
                attempt = 0
                linkPolled = true
            default:
                break
            }
        }
        // After the state above, so a subscriber reading `adapter` when it
        // handles an `.adapter` event sees this one's BLE half.
        let linkEvent = LinkEvent.session(event)
        initCapture.session(linkEvent, token: token)
        deliver(linkEvent)
        appendConsole(for: event)
        if current, case .needsReconnect = event {
            requestReconnect(reason: "ELM session asked for a reconnect")
        }
    }

    private func applySessionState(_ elm: ELMState, reason: String?) {
        switch elm {
        case .resetting, .initialising, .searching, .probing, .reinitialising:
            state = .initialising
        case .ready:
            state = .ready
            pollHz = 0
        case .polling, .retrying:
            state = .polling(protocolNumber: lastInfo?.protocolNumber ?? "", voltage: lastInfo?.voltage)
        case .failed:
            // A reconnect, if one follows, sets `.reconnecting`.
            state = .failed(reason: reason ?? LinkReason.sessionFailed.text)
            pollHz = 0
        case .idle:
            break
        }
    }

    // MARK: Console and log

    private func transition(to new: LinkSample.BLEState, reason: String?, uptime at: Double? = nil) {
        guard new != bleState else { return }
        let old = bleState
        bleState = new
        if old == .discovering {
            discoveryWatchdog?.cancel()
            discoveryWatchdog = nil
        }
        if old == .connecting {
            connectWatchdog?.cancel()
            connectWatchdog = nil
        }
        let stamp = at ?? uptime.uptimeSeconds
        let event = LinkEvent.ble(from: old, to: new, reason: reason, uptime: stamp)
        initCapture.ble(event, from: old, to: new)
        deliver(event)
        appendConsole(.status, "ble: \(old.rawValue) → \(new.rawValue)" + (reason.map { " (\($0))" } ?? ""), stamp)
    }

    /// A `ble` row with `from == to`: a fact about the link, not a transition.
    private func note(_ reason: String, uptime at: Double) {
        let event = LinkEvent.ble(from: bleState, to: bleState, reason: reason, uptime: at)
        initCapture.ble(event, from: bleState, to: bleState)
        deliver(event)
        appendConsole(.status, "ble: \(reason)", at)
    }

    private func appendConsole(for event: ELMSessionEvent) {
        switch event {
        case .exchange(let exchange):
            let tx = exchange.tx.isEmpty ? "(unsolicited)" : exchange.tx
            appendConsole(.tx, tx, exchange.requestUptime)
            let rx = exchange.rx.map { ELM327ResponseParser.lines(in: $0).joined(separator: " | ") }
            let outcome = exchange.outcome == .ok ? "" : " [\(exchange.outcome.rawValue)]"
            appendConsole(.rx, (rx ?? "—") + outcome, exchange.completedUptime)
        case .state(let from, let to, let reason, let at):
            let text = from == to ? "elm: \(reason ?? "")" : "elm: \(from.rawValue) → \(to.rawValue)" + (reason.map { " (\($0))" } ?? "")
            appendConsole(.status, text, at)
        case .adapter(let info, let at):
            let plan = info.plan
            appendConsole(
                .status,
                "adapter: \(info.elmVersion), protocol \(info.protocolNumber), "
                    + (info.voltage.map { String(format: "%.1f V", $0) } ?? "no voltage")
                    + ", polling \(plan.primaryCommand.wireFormat) at \(plan.requestHeader?.rawValue ?? "7DF"), ATAT\(plan.adaptiveTiming)",
                at
            )
        case .needsReconnect(let at):
            appendConsole(.status, "elm: needs reconnect", at)
        case .reading, .pollRate:
            break
        }
    }

    private func appendConsole(_ direction: ConsoleLine.Direction, _ text: String, _ at: Double) {
        console.append(ConsoleLine(id: nextConsoleID, direction: direction, text: text, uptime: at))
        nextConsoleID += 1
        if console.count > Self.consoleLimit { console.removeFirst(console.count - Self.consoleLimit) }
    }

    // MARK: Helpers

    private func remember(_ id: UUID) {
        if let found = discovered.first(where: { $0.id == id }) {
            setRememberedName(found.name)
        } else if id != rememberedAdapterID {
            // A different adapter without a scan row: its name comes with
            // the connection (`.ready`); the old one's must not stay.
            setRememberedName(nil)
        }
        rememberedAdapterID = id
        defaults.set(id.uuidString, forKey: Self.rememberedAdapterKey)
    }

    private func setRememberedName(_ name: String?) {
        guard name != rememberedAdapterName else { return }
        rememberedAdapterName = name
        if let name {
            defaults.set(name, forKey: Self.rememberedAdapterNameKey)
        } else {
            defaults.removeObject(forKey: Self.rememberedAdapterNameKey)
        }
    }

    private func name(of id: UUID) -> String {
        discovered.first { $0.id == id }?.name ?? id.uuidString
    }

    /// Name fragments of OBD adapters, listed first in the picker.
    nonisolated static let adapterNameHints = ["vlink", "icar", "vgate", "obd", "elm", "veepeak"]

    nonisolated static func isLikelyAdapter(_ adapter: DiscoveredAdapter) -> Bool {
        let name = adapter.name.lowercased()
        return adapterNameHints.contains { name.contains($0) }
    }

    /// Likely adapters first, then strongest signal, then name.
    nonisolated static func listOrder(_ lhs: DiscoveredAdapter, _ rhs: DiscoveredAdapter) -> Bool {
        let (left, right) = (isLikelyAdapter(lhs), isLikelyAdapter(rhs))
        if left != right { return left }
        if lhs.rssi != rhs.rssi { return lhs.rssi > rhs.rssi }
        return lhs.name < rhs.name
    }
}

extension Clock where Duration == Swift.Duration {
    /// Fixes a deadline `duration` from now and returns a closure that
    /// sleeps until it, so a timer started in a new `Task` is measured from
    /// the moment it was decided (and is deterministic under a test clock).
    /// A protocol-extension member so it can be called on `any Clock<Duration>`.
    func linkSleeper(after duration: Swift.Duration) -> @Sendable () async throws -> Void {
        let deadline = now.advanced(by: duration)
        (self as? any LinkDeadlineReserving)?.reserve(deadline)
        return { try await self.sleep(until: deadline, tolerance: nil) }
    }
}

/// A virtual test clock that wants to know a timer's deadline the moment
/// it is decided: the timer registers its sleep later, from the cooperative
/// pool, and the clock must not move time past it meanwhile. `linkSleeper`
/// calls it synchronously; `ContinuousClock` doesn't conform.
protocol LinkDeadlineReserving: AnyObject, Sendable {
    func reserve(_ deadline: any InstantProtocol)
}

/// The events behind `lastInitEvents`: the current connection's BLE
/// transition into `connected`, then the latest initialisation of that
/// connection's session, from its first event to its transition into
/// `polling` or `failed`, then (M7.1-5) the latest `.adapter` event and the
/// latest ELM transition delivered after that init ended, in arrival order,
/// so the replay ends with the plan actually polled (e.g. after a PID was
/// dropped on NO DATA) and the state the link is in. Fed by
/// `OBDLinkService` in delivery order.
///
/// Emptied when BLE leaves `connected` (M6.1-1): a connection that has
/// dropped is never replayed. Session events are matched by the token of
/// the session they come from, so a previous connection's events, which can
/// arrive after a new connection is up, never match.
struct InitCapture {
    let limit: Int
    private var connection: [LinkEvent] = []
    private var initialisation: [LinkEvent] = []
    /// The session of the captured connection; nil until it exists.
    private var sessionToken: Int?
    /// Collecting the init: from the session's first event, or the start of
    /// a re-init, until `polling` or `failed`.
    private var initialising = false
    /// After the init ended: the latest `.adapter` event and the latest ELM
    /// transition (`from != to`), at most one of each, oldest first.
    private var afterInit: [LinkEvent] = []

    init(limit: Int) {
        self.limit = max(limit, 1)
    }

    var events: [LinkEvent] { connection + initialisation + afterInit }

    mutating func ble(_ event: LinkEvent, from: LinkSample.BLEState, to: LinkSample.BLEState) {
        // A note (`write failed: …`) neither starts nor ends a connection,
        // and isn't part of the replayed init.
        guard from != to else { return }
        if to == .connected {
            // A new connection: everything starts again from here.
            reset()
            connection = [event]
        } else if from == .connected {
            // The connection ended (dropped, disconnected, Bluetooth off).
            reset()
        }
        trim()
    }

    private mutating func reset() {
        connection = []
        initialisation = []
        afterInit = []
        sessionToken = nil
        initialising = false
    }

    /// The connected transport got its session (`token`); its first event
    /// starts the init.
    mutating func sessionStarted(token: Int) {
        sessionToken = token
        initialisation = []
        afterInit = []
        initialising = true
    }

    mutating func session(_ event: LinkEvent, token: Int) {
        guard token == sessionToken, case .session(let sessionEvent) = event else { return }
        switch sessionEvent {
        case .pollRate, .needsReconnect:
            return
        case .state(let from, let to, _, _) where from != to && !initialising && (to == .resetting || to == .reinitialising):
            // A new init on this connection replaces the last one.
            initialisation = []
            afterInit = []
            initialising = true
        default:
            break
        }
        guard initialising else {
            keepAfterInit(sessionEvent, as: event)
            return
        }
        initialisation.append(event)
        if case .state(let from, let to, _, _) = sessionEvent, from != to, to == .polling || to == .failed {
            initialising = false
        }
        trim()
    }

    /// After the init: a newer `.adapter` event or ELM transition replaces
    /// the one of its kind and goes last. Notes, exchanges and readings
    /// are poll traffic and not kept.
    private mutating func keepAfterInit(_ sessionEvent: ELMSessionEvent, as event: LinkEvent) {
        let isAdapter: (LinkEvent) -> Bool = { if case .session(.adapter) = $0 { true } else { false } }
        let isTransition: (LinkEvent) -> Bool = {
            if case .session(.state(let from, let to, _, _)) = $0 { from != to } else { false }
        }
        switch sessionEvent {
        case .adapter:
            afterInit.removeAll(where: isAdapter)
        case .state(let from, let to, _, _) where from != to:
            afterInit.removeAll(where: isTransition)
        default:
            return
        }
        afterInit.append(event)
        trim()
    }

    /// Drops the oldest events beyond `limit`: the connection part first,
    /// then the start of the init, and `afterInit` (at most two) only with a
    /// limit below three.
    private mutating func trim() {
        let excess = connection.count + initialisation.count + afterInit.count - limit
        guard excess > 0 else { return }
        let fromConnection = min(excess, connection.count)
        connection.removeFirst(fromConnection)
        let fromInit = min(excess - fromConnection, initialisation.count)
        initialisation.removeFirst(fromInit)
        afterInit.removeFirst(min(excess - fromConnection - fromInit, afterInit.count))
    }
}
