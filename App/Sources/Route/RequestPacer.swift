import Foundation

/// The clock the pacer runs on, injected so tests wait for nothing.
struct PacerClock: Sendable {
    /// Seconds on any monotonic base.
    var now: @Sendable () -> TimeInterval
    var sleep: @Sendable (TimeInterval) async throws -> Void

    static let system = PacerClock(
        now: { ProcessInfo.processInfo.systemUptime },
        sleep: { try await Task.sleep(for: .seconds($0)) })
}

/// Pacing rules from the R1 spike (docs/ROUTING.md): the completer's queries
/// are debounced, requests start at least `minInterval` apart (unpaced bursts
/// are throttled by MapKit after about 60 calls), and a throttled answer is
/// retried with growing delays instead of being shown as "nothing found".
/// Cancelling the caller's task cancels any wait here.
@MainActor
final class RequestPacer {
    static let defaultDebounce: TimeInterval = 0.5
    static let defaultMinInterval: TimeInterval = 1.5
    /// First retry delay after a throttled answer; it doubles up to `maxBackoff`.
    static let baseBackoff: TimeInterval = 2
    static let maxBackoff: TimeInterval = 30
    /// Throttled attempts in a row before the flow gives up and says so.
    static let maxThrottledAttempts = 6

    private let clock: PacerClock
    let debounce: TimeInterval
    let minInterval: TimeInterval
    private var lastStart: TimeInterval?
    private var throttledInARow = 0

    init(clock: PacerClock = .system, debounce: TimeInterval = defaultDebounce, minInterval: TimeInterval = defaultMinInterval) {
        self.clock = clock
        self.debounce = debounce
        self.minInterval = minInterval
    }

    /// Delay before retry number `attempt` (1-based) after a throttled answer.
    static func backoff(attempt: Int) -> TimeInterval {
        min(maxBackoff, baseBackoff * pow(2, Double(max(attempt, 1) - 1)))
    }

    /// Waits out the debounce; throws `CancellationError` when the query changed meanwhile.
    func settle() async throws {
        try await clock.sleep(debounce)
        try Task.checkCancellation()
    }

    /// Waits until a request may start (at least `minInterval` after the last
    /// one) and takes the slot.
    func takeSlot() async throws {
        if let lastStart {
            let wait = lastStart + minInterval - clock.now()
            if wait > 0 { try await clock.sleep(wait) }
        }
        try Task.checkCancellation()
        lastStart = clock.now()
    }

    /// Runs `operation` in a paced slot (`takeSlot`); on `.throttled` waits the
    /// backoff and tries again, up to `maxThrottledAttempts` in a row, then
    /// throws `.throttled`. Any other error, and cancellation, pass through.
    func perform<T>(_ operation: () async throws -> T) async throws -> T {
        try await retrying(paced: true, operation)
    }

    /// A completer query: debounced (`settle`) instead of slotted, so typing
    /// stays responsive, but a throttled answer is retried the same way.
    func performDebounced<T>(_ operation: () async throws -> T) async throws -> T {
        try await settle()
        return try await retrying(paced: false, operation)
    }

    private func retrying<T>(paced: Bool, _ operation: () async throws -> T) async throws -> T {
        var attempt = 0
        while true {
            if paced { try await takeSlot() }
            do {
                let value = try await operation()
                throttledInARow = 0
                return value
            } catch RouteServiceError.throttled {
                attempt += 1
                throttledInARow += 1
                if attempt >= Self.maxThrottledAttempts { throw RouteServiceError.throttled }
                try await clock.sleep(Self.backoff(attempt: attempt))
                try Task.checkCancellation()
            }
        }
    }
}
