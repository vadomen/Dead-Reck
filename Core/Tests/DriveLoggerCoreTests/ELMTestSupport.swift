import Foundation

@testable import DriveLoggerCore

/// A virtual clock that only moves when a test advances it, and doubles as
/// the `UptimeSource` so every timestamp in a test is deterministic.
///
/// Sleepers are resumed in deadline order. Between resumptions the clock
/// yields many times so the woken task (and whatever it triggers on other
/// actors) runs before the next deadline is considered. A sleeper whose
/// deadline has already passed when it registers returns immediately; the
/// session and the mock compute their deadlines synchronously when they
/// start waiting, so a late registration can't push a deadline back.
final class TestClock: Clock, UptimeSource {
    struct Instant: InstantProtocol {
        var offset: Duration

        func advanced(by duration: Duration) -> Instant {
            Instant(offset: offset + duration)
        }

        func duration(to other: Instant) -> Duration {
            other.offset - offset
        }

        static func < (lhs: Instant, rhs: Instant) -> Bool {
            lhs.offset < rhs.offset
        }
    }

    private struct Sleeper {
        var id: UInt64
        var deadline: Instant
        var continuation: CheckedContinuation<Void, any Error>
    }

    let baseUptime: Double
    private let settleYields: Int
    private let lock = NSLock()
    // All guarded by `lock`.
    private nonisolated(unsafe) var current = Instant(offset: .zero)
    private nonisolated(unsafe) var sleepers: [Sleeper] = []
    private nonisolated(unsafe) var nextID: UInt64 = 0
    private nonisolated(unsafe) var cancelledBeforeRegistration: Set<UInt64> = []

    init(baseUptime: Double = 1_000, settleYields: Int = 200) {
        self.baseUptime = baseUptime
        self.settleYields = settleYields
    }

    var now: Instant { lock.withLock { current } }
    var minimumResolution: Duration { .nanoseconds(1) }
    var uptimeSeconds: Double { baseUptime + now.offset.seconds }
    var sleeperCount: Int { lock.withLock { sleepers.count } }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        try Task.checkCancellation()
        let id = lock.withLock {
            nextID += 1
            return nextID
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                enum Action { case resume, cancel, wait }
                let action: Action = lock.withLock {
                    if cancelledBeforeRegistration.remove(id) != nil { return .cancel }
                    if deadline <= current { return .resume }
                    sleepers.append(Sleeper(id: id, deadline: deadline, continuation: continuation))
                    return .wait
                }
                switch action {
                case .resume: continuation.resume()
                case .cancel: continuation.resume(throwing: CancellationError())
                case .wait: break
                }
            }
        } onCancel: {
            let continuation: CheckedContinuation<Void, any Error>? = lock.withLock {
                if let index = sleepers.firstIndex(where: { $0.id == id }) {
                    return sleepers.remove(at: index).continuation
                }
                cancelledBeforeRegistration.insert(id)
                return nil
            }
            continuation?.resume(throwing: CancellationError())
        }
    }

    /// Moves time forward by `duration`, waking sleepers in deadline order.
    func advance(by duration: Duration) async {
        let target = now.advanced(by: duration)
        while true {
            await settle()
            let due: [Sleeper]? = lock.withLock {
                guard let earliest = sleepers.map(\.deadline).min(), earliest <= target else { return nil }
                if current < earliest { current = earliest }
                let due = sleepers.filter { $0.deadline <= current }
                sleepers.removeAll { $0.deadline <= current }
                return due
            }
            guard let due else { break }
            for sleeper in due { sleeper.continuation.resume() }
        }
        lock.withLock {
            if current < target { current = target }
        }
        await settle()
    }

    /// Lets woken tasks run. Yields only; never sleeps in real time.
    func settle() async {
        for _ in 0..<settleYields { await Task.yield() }
    }
}

extension Duration {
    var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) * 1e-18
    }
}

/// Steps the clock until `condition` holds. Returns false if `limit` of
/// virtual time passes first, so a broken state machine fails instead of
/// hanging the suite.
@discardableResult
func driveUntil(
    _ clock: TestClock,
    step: Duration = .milliseconds(5),
    limit: Duration = .seconds(120),
    _ condition: () async -> Bool
) async -> Bool {
    let deadline = clock.now.advanced(by: limit)
    while clock.now < deadline {
        await clock.settle()
        if await condition() { return true }
        await clock.advance(by: step)
    }
    return await condition()
}

/// Runs `work` while stepping the clock until it finishes.
func drive<T: Sendable>(
    _ clock: TestClock,
    step: Duration = .milliseconds(5),
    limit: Duration = .seconds(120),
    _ work: @escaping @Sendable () async throws -> T
) async throws -> T {
    let done = DoneFlag()
    let task = Task {
        defer { done.set() }
        return try await work()
    }
    let finished = await driveUntil(clock, step: step, limit: limit) { done.isSet }
    guard finished else {
        // Don't await work that may ignore cancellation: fail, never hang.
        task.cancel()
        throw DriveTimeout(limit: limit)
    }
    return try await task.value
}

struct DriveTimeout: Error, CustomStringConvertible {
    var limit: Duration
    var description: String { "work did not finish within \(limit) of virtual time" }
}

final class DoneFlag: Sendable {
    private let lock = NSLock()
    // Guarded by `lock`.
    private nonisolated(unsafe) var value = false
    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}

/// Collects everything a session emits, for assertions.
actor EventLog {
    private(set) var events: [ELMSessionEvent] = []
    private(set) var finished = false

    static func start(_ stream: AsyncStream<ELMSessionEvent>) -> EventLog {
        let log = EventLog()
        Task {
            for await event in stream { await log.append(event) }
            await log.finish()
        }
        return log
    }

    private func append(_ event: ELMSessionEvent) { events.append(event) }
    private func finish() { finished = true }

    var exchanges: [ELMExchange] {
        events.compactMap { if case .exchange(let exchange) = $0 { exchange } else { nil } }
    }

    var readings: [OBDReading] {
        events.compactMap { if case .reading(let reading) = $0 { reading } else { nil } }
    }

    var transitions: [(from: ELMState, to: ELMState, reason: String?)] {
        events.compactMap { if case .state(let from, let to, let reason, _) = $0 { (from, to, reason) } else { nil } }
    }

    var states: [ELMState] { transitions.map(\.to) }

    var adapterInfos: [ELMAdapterInfo] {
        events.compactMap { if case .adapter(let info, _) = $0 { info } else { nil } }
    }

    var pollRates: [Double] {
        events.compactMap { if case .pollRate(let hz, _) = $0 { hz } else { nil } }
    }

    var reconnectRequests: Int {
        events.filter { if case .needsReconnect = $0 { true } else { false } }.count
    }
}

/// Collects a transport's chunks.
actor ChunkLog {
    private(set) var chunks: [ELMChunk] = []
    private(set) var finished = false

    static func start(_ stream: AsyncStream<ELMChunk>) -> ChunkLog {
        let log = ChunkLog()
        Task {
            for await chunk in stream { await log.append(chunk) }
            await log.finish()
        }
        return log
    }

    private func append(_ chunk: ELMChunk) { chunks.append(chunk) }
    private func finish() { finished = true }

    var text: String { String(decoding: chunks.flatMap { Array($0.bytes) }, as: UTF8.self) }
}

extension MockELMAdapter.Rule {
    /// The Touareg script with every delay removed, for tests that only care
    /// about content.
    static var touaregInstant: [MockELMAdapter.Rule] {
        touareg.map { rule in
            var rule = rule
            rule.delay = .zero
            return rule
        }
    }
}

extension MockELMAdapter.Rule {
    /// The bench-car script with every delay removed.
    static var benchCarInstant: [MockELMAdapter.Rule] {
        benchCar.map { rule in
            var rule = rule
            rule.delay = .zero
            return rule
        }
    }
}

/// How often start-up selection sends the winning command when it parses at
/// both timing levels: selection's samples, then the `ATAT1`/`ATAT2`
/// comparison's at each level. Scripts that let the probe pass and then fail
/// polling answer this many times first.
let probeSendsOfChosenCommand = ELMSession.probeSamples + 2 * ELMSession.adaptiveTimingSamples

/// Short timeouts so state-machine tests need little virtual time.
extension ELMSessionConfiguration {
    static let fastTest = ELMSessionConfiguration(
        commandTimeout: .milliseconds(100),
        resetTimeout: .milliseconds(300),
        searchTimeout: .milliseconds(500),
        failuresBeforeReinit: 3,
        reinitsBeforeReconnect: 2,
        probe: false,
        rateWindow: .seconds(1),
        retryDelay: .milliseconds(10),
        reinitBackoff: .milliseconds(50)
    )
}
