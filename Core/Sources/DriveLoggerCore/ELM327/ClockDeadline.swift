extension Clock where Duration == Swift.Duration {
    /// Fixes a deadline `duration` from **now** and returns a closure that
    /// sleeps until it.
    ///
    /// `sleep(for:)` reads `now` only when the sleep starts, which for a sleep
    /// inside a new `Task` is some time after the code that decided to wait.
    /// Fixing the deadline synchronously keeps timeouts and reply delays
    /// measured from the moment they were decided, and makes them
    /// deterministic under a test clock: a sleeper that registers late still
    /// wakes at the right virtual instant.
    ///
    /// A protocol-extension member rather than a generic function so it can be
    /// called on an `any Clock<Duration>` (implicit existential opening into a
    /// generic parameter doesn't happen here once Foundation is imported).
    func sleeper(untilAfter duration: Swift.Duration) -> @Sendable () async throws -> Void {
        let deadline = now.advanced(by: duration)
        return { try await self.sleep(until: deadline, tolerance: nil) }
    }
}
