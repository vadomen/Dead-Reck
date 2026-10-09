import Foundation

/// The live feed of navigation inputs from a recording's `LogSink` (N4 A).
///
/// Hand `tap` to the recording's `LogFileWriter`; the sink then calls it for
/// every `motion`, `location`, `obd` and `manualFix` event it accepted, in
/// write order and under the sink's lock (`LogSink`, "Tap"). Each event is
/// converted with `NavigationInput.init?(_:)` and yielded to `inputs`.
///
/// **Bounded, never blocking.** `inputs` buffers the newest `bufferLimit`
/// inputs (4096 by default, about 30 s of every stream at full rate). When a
/// consumer falls that far behind, the oldest buffered input is dropped and
/// `droppedInputs` counts it. Only navigation input is ever dropped: the log
/// row was already enqueued for the writer before the tap ran, and the
/// writer's queue is unbounded. Inputs yielded after `finish()` are ignored
/// and not counted (there is no consumer left to fall behind).
///
/// **Single consumer.** `inputs` is an `AsyncStream`: iterate it from one
/// task only (the NavigationService, N4 B). It ends after `finish()`, once
/// the buffered inputs have been taken; the recorder calls `finish()` when
/// the recording's writer has finished, so no input of that recording is
/// lost to the end of the stream.
///
/// Concurrency: the project's pattern (`LogSink`'s doc). The continuation is
/// thread-safe; the one counter is `nonisolated(unsafe)` guarded by `lock`.
public final class NavigationTap: Sendable {
    /// Inputs buffered for a consumer that has fallen behind.
    public static let defaultBufferLimit = 4096

    /// The navigation inputs, in file order. Single consumer.
    public let inputs: AsyncStream<NavigationInput>
    private let continuation: AsyncStream<NavigationInput>.Continuation
    private let lock = NSLock()
    /// Guarded by `lock`. Inputs the buffer dropped because it was full.
    private nonisolated(unsafe) var dropped = 0

    /// - Precondition: `bufferLimit > 0`.
    public init(bufferLimit: Int = NavigationTap.defaultBufferLimit) {
        precondition(bufferLimit > 0, "bufferLimit must be positive")
        (inputs, continuation) = AsyncStream.makeStream(
            of: NavigationInput.self,
            bufferingPolicy: .bufferingNewest(bufferLimit)
        )
    }

    deinit {
        continuation.finish()
    }

    /// Inputs dropped so far because the consumer fell `bufferLimit` behind.
    public var droppedInputs: Int {
        lock.withLock { dropped }
    }

    /// Converts `event` and yields it to `inputs`; ignores every kind that is
    /// not a navigation input. Never blocks: safe under `LogSink`'s lock.
    public func record(_ event: LogEvent) {
        guard let input = NavigationInput(event) else { return }
        if case .dropped = continuation.yield(input) {
            lock.withLock { dropped += 1 }
        }
    }

    /// The closure for `LogFileWriter(…, tap:)`. Keeps this tap alive for as
    /// long as the writer's sink exists.
    public var tap: @Sendable (LogEvent) -> Void {
        { [self] event in record(event) }
    }

    /// Ends `inputs` after what is buffered. Idempotent.
    public func finish() {
        continuation.finish()
    }
}
