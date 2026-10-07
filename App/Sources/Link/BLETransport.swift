import CoreBluetooth
import DriveLoggerCore
import Foundation

/// `ELMTransport` over a connected BLE peripheral's UART characteristic pair.
///
/// Created by `BLECentral` once GATT discovery has chosen the pair
/// (`GATTDetection`) and notifications are on; `BLECentral` stays the
/// peripheral's delegate and forwards to it. Responsibilities here:
/// - **the only write to the adapter** (`send`; `RepositoryInvariantTests`
///   checks no other code mentions the CoreBluetooth write call), so
///   holding a `CBPeripheral` elsewhere is no way around the read-only
///   guard: `send` takes only a `ValidatedELMCommand`;
/// - split writes to `selection.maxWriteLength`, which `BLECentral` sets
///   to `maximumWriteValueLength` for the chosen write type, capped at the
///   without-response length so a write never needs a long (prepared)
///   write;
/// - wait for `canSendWriteWithoutResponse` before each unacknowledged
///   write (CoreBluetooth drops such writes when its buffer is full);
/// - deliver every notification on `incoming`, stamped by `BLECentral` in
///   the `didUpdateValueFor` delegate callback, before any hop;
/// - finish `incoming` when the peripheral disconnects (`close`).
///
/// Threading: every CoreBluetooth call runs on the central's serial queue,
/// the same queue its delegate callbacks arrive on. State shared with
/// other threads is guarded by `lock` (docs/PLAN.md §4.0).
final class BLETransport: ELMTransport {
    let incoming: AsyncStream<ELMChunk>

    /// The selection that will be recorded in the header.
    let selection: GATTSelection

    private let continuation: AsyncStream<ELMChunk>.Continuation
    private let queue: DispatchQueue
    private let uptime: any UptimeSource
    private let writeType: CBCharacteristicWriteType
    /// Longest wait for `canSendWriteWithoutResponse` per command.
    private let readinessTimeout: Duration
    private let lock = NSLock()
    // Guarded by `lock`; nil once closed. Only messaged on `queue`.
    private nonisolated(unsafe) var peripheral: CBPeripheral?
    // Guarded by `lock`; nil once closed. Only used on `queue`.
    private nonisolated(unsafe) var characteristic: CBCharacteristic?
    // Guarded by `lock`.
    private nonisolated(unsafe) var closedReason: String?
    // Guarded by `lock`. Sends waiting for `peripheralIsReady(toSendWriteWithoutResponse:)`.
    private nonisolated(unsafe) var readinessWaiters: [CheckedContinuation<Void, Never>] = []

    private enum WriteAttempt: Sendable {
        case written(uptime: Double)
        case notReady
    }

    /// - Parameters:
    ///   - characteristic: the write characteristic of `selection`.
    ///   - queue: the central's queue; every CoreBluetooth call goes there.
    ///   - uptime: stamps writes; same timebase as the notification stamps
    ///     and the `ELMSession`.
    init(
        peripheral: CBPeripheral,
        characteristic: CBCharacteristic,
        writeType: CBCharacteristicWriteType,
        selection: GATTSelection,
        queue: DispatchQueue,
        uptime: any UptimeSource = SystemUptimeSource(),
        readinessTimeout: Duration = .seconds(1)
    ) {
        self.peripheral = peripheral
        self.characteristic = characteristic
        self.writeType = writeType
        self.selection = selection
        self.queue = queue
        self.uptime = uptime
        self.readinessTimeout = readinessTimeout
        (incoming, continuation) = AsyncStream.makeStream(of: ELMChunk.self)
    }

    /// Writes `command.wireData` (CR included) in pieces of at most
    /// `selection.maxWriteLength` bytes, in order. Returns the uptime at
    /// which the **last** piece — the one the adapter acts on — was handed to
    /// CoreBluetooth, taken on the BLE queue immediately before the call.
    ///
    /// Throws `.notConnected` once closed, and `.writeFailed` if the link
    /// isn't ready for an unacknowledged write within `readinessTimeout`.
    /// Errors of acknowledged writes arrive later, in `didWriteValueFor`;
    /// `BLECentral` reports them, and the session's timeout covers the
    /// lost command.
    func send(_ command: ValidatedELMCommand) async throws -> Double {
        let chunks = BLEWriteSplitter.chunks(of: command.wireData, maxLength: selection.maxWriteLength)
        let deadline = ContinuousClock.now.advanced(by: readinessTimeout)
        var issuedAt = uptime.uptimeSeconds
        var index = 0
        while index < chunks.count {
            let chunk = chunks[index]
            let attempt: WriteAttempt = try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    guard let (peripheral, characteristic) = self.link() else {
                        continuation.resume(throwing: ELMTransportError.notConnected)
                        return
                    }
                    if self.writeType == .withoutResponse, !peripheral.canSendWriteWithoutResponse {
                        continuation.resume(returning: .notReady)
                        return
                    }
                    let now = self.uptime.uptimeSeconds
                    peripheral.writeValue(chunk, for: characteristic, type: self.writeType)
                    continuation.resume(returning: .written(uptime: now))
                }
            }
            switch attempt {
            case .written(let uptime):
                issuedAt = uptime
                index += 1
            case .notReady:
                guard ContinuousClock.now < deadline else {
                    throw ELMTransportError.writeFailed("not ready for a write without response within \(readinessTimeout)")
                }
                await waitUntilReady(atMost: .milliseconds(50))
            }
        }
        return issuedAt
    }

    // MARK: Called by BLECentral, on its queue

    /// A notification from the notify characteristic. `uptime` was read
    /// first thing in the delegate callback.
    func receive(_ bytes: Data, uptime: Double) {
        guard lock.withLock({ closedReason == nil }) else { return }
        continuation.yield(ELMChunk(bytes: bytes, uptime: uptime))
    }

    /// `peripheralIsReady(toSendWriteWithoutResponse:)`.
    func readyToSend() {
        releaseReadinessWaiters()
    }

    /// The link is gone: later sends throw `.notConnected` and `incoming`
    /// finishes, which tells the `ELMSession` its transport closed.
    /// Idempotent.
    func close(reason: String) {
        let first = lock.withLock { () -> Bool in
            guard closedReason == nil else { return false }
            closedReason = reason
            peripheral = nil
            characteristic = nil
            return true
        }
        guard first else { return }
        releaseReadinessWaiters()
        continuation.finish()
    }

    var isClosed: Bool {
        lock.withLock { closedReason != nil }
    }

    // MARK: Private

    private func link() -> (CBPeripheral, CBCharacteristic)? {
        lock.withLock {
            guard closedReason == nil, let peripheral, let characteristic else { return nil }
            return (peripheral, characteristic)
        }
    }

    /// Resumes on readiness, on close, or after `atMost` — whichever comes
    /// first; the caller re-checks. The timer covers a readiness callback
    /// that fired between the check and the wait.
    private func waitUntilReady(atMost: Duration) async {
        await withCheckedContinuation { (waiter: CheckedContinuation<Void, Never>) in
            let waiting = lock.withLock { () -> Bool in
                guard closedReason == nil else { return false }
                readinessWaiters.append(waiter)
                return true
            }
            guard waiting else {
                waiter.resume()
                return
            }
            let seconds = Double(atMost.components.seconds) + Double(atMost.components.attoseconds) * 1e-18
            queue.asyncAfter(deadline: .now() + seconds) { self.releaseReadinessWaiters() }
        }
    }

    private func releaseReadinessWaiters() {
        let waiters = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            defer { readinessWaiters = [] }
            return readinessWaiters
        }
        for waiter in waiters { waiter.resume() }
    }
}
