import DriveLoggerCore
import Foundation

/// Where a running source hands its events: the recording's clock and sink,
/// behind a gate that `SensorSource.stop()` closes.
///
/// Frameworks may still run a handler that was already queued when updates
/// were stopped. The gate is what makes `stop()`'s promise hold — "no events
/// reach `sink` after it returns": every delivery holds `lock` while it
/// records, and `close()` takes the same lock, so once `close()` returns no
/// delivery is in progress and none will start. `sink.record` never blocks,
/// so holding the lock across it is cheap (the same pattern as Core's
/// simulated ticker).
///
/// Sendable class with lock-guarded state (docs/PLAN.md §4.0); called from
/// the frameworks' queues and from the main actor.
final class SampleGate: Sendable {
    let source: String
    let clock: SessionClock
    private let sink: LogSink
    private let lock = NSLock()
    /// Guarded by `lock`.
    private nonisolated(unsafe) var isOpen = true
    /// Guarded by `lock`. Error descriptions already written, so a sensor
    /// that fails on every callback writes one row per distinct error, not
    /// one per sample.
    private nonisolated(unsafe) var reported: Set<String> = []

    init(source: String, clock: SessionClock, sink: LogSink) {
        self.source = source
        self.clock = clock
        self.sink = sink
    }

    /// Records `event` unless the gate is closed.
    func deliver(_ event: LogEvent) {
        lock.withLock {
            guard isOpen else { return }
            sink.record(event)
        }
    }

    /// Records several events, in order, as one delivery.
    func deliver(_ events: [LogEvent]) {
        lock.withLock {
            guard isOpen else { return }
            for event in events { sink.record(event) }
        }
    }

    /// Writes a `lifecycle` `error` row `"<source>: <error>"` at `clock.now()`,
    /// once per distinct description.
    func report(_ error: any Error) {
        report(String(describing: error))
    }

    func report(_ description: String) {
        lock.withLock {
            guard isOpen, reported.insert(description).inserted else { return }
            sink.record(LogEvent(
                timestamp: clock.now(),
                payload: .lifecycle(LifecycleSample(.error, detail: "\(source): \(description)"))
            ))
        }
    }

    /// No delivery is running once this returns, and none will start.
    func close() {
        lock.withLock { isOpen = false }
    }

    var isClosed: Bool {
        lock.withLock { !isOpen }
    }
}
