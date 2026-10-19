import DriveLoggerCore
import Foundation

/// The files of one pack's download in the store directory: the bytes
/// received so far and the metadata sidecar (Core's names). A kill leaves
/// both, so the next attempt resumes.
struct PackPartialFiles: Sendable {
    let partial: URL
    let metadata: URL

    /// nil when the pack's name or content hash is not valid.
    init?(directory: URL, pack: PackManifest.Pack) {
        guard let partialName = RoadPackStoreRules.partialFileName(name: pack.name, contentHash: pack.contentHash),
              let metadataName = RoadPackStoreRules.partialMetadataFileName(name: pack.name, contentHash: pack.contentHash)
        else { return nil }
        partial = directory.appendingPathComponent(partialName)
        metadata = directory.appendingPathComponent(metadataName)
    }

    /// Bytes on disk; nil when there is no partial file.
    func partialBytes() -> Int64? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: partial.path) else { return nil }
        return (attributes[.size] as? NSNumber)?.int64Value
    }

    func readMetadata() -> PackDownloadRules.PartialMetadata? {
        (try? Data(contentsOf: metadata)).flatMap(PackDownloadRules.PartialMetadata.decode)
    }

    func writeMetadata(_ value: PackDownloadRules.PartialMetadata) {
        if let data = try? value.encoded() { try? data.write(to: metadata, options: .atomic) }
    }

    func delete() {
        try? FileManager.default.removeItem(at: partial)
        try? FileManager.default.removeItem(at: metadata)
    }
}

/// One HTTP request for a pack, streamed to the partial file in chunks by a
/// `URLSessionDataDelegate`. The first response is judged by Core's
/// `PackDownloadRules.decide` before any body byte is written; the body is
/// appended as it arrives, so a kill leaves a usable prefix.
///
/// Everything the delegate touches is behind `lock`; the delegate queue is
/// serial. Created per attempt, used once.
final class PackTransfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    enum Result: Sendable, Equatable {
        /// The body ended without error.
        case completed
        /// Core says the partial cannot continue: delete it, retry without `Range`.
        case restart(String)
        /// This attempt ends; the partial is kept.
        case failed(String)
        /// `cancel()` was called.
        case cancelled
        /// The connection failed.
        case transport(String)
        /// 404: the file is gone (R67.1-7); the reason is Core's.
        case notFound(String)
        /// The system refused the request because the path is cellular,
        /// expensive or constrained and the session does not allow it.
        case refused(Refusal)
    }

    enum Refusal: Sendable, Equatable {
        case cellular, expensive, constrained

        /// URLSession's answer for a path the session's flags forbid
        /// (`NSURLErrorDataNotAllowed`, or `networkUnavailableReason`).
        init?(_ error: Error) {
            guard let error = error as? URLError else { return nil }
            switch error.networkUnavailableReason {
            case .cellular?: self = .cellular
            case .expensive?: self = .expensive
            case .constrained?: self = .constrained
            case nil: if error.code == .dataNotAllowed { self = .cellular } else { return nil }
            @unknown default: return nil
            }
        }
    }

    private let request: URLRequest
    private let pack: PackManifest.Pack
    private let files: PackPartialFiles
    private let requestedOffset: Int64?
    private let configuration: URLSessionConfiguration

    private let lock = NSLock()
    private var storedETag: String?
    private var handle: FileHandle?
    private var written: Int64 = 0
    private var decided: Result?
    private var cancelRequested = false
    private var continuation: CheckedContinuation<Result, Never>?
    private var task: URLSessionDataTask?
    private var session: URLSession?

    /// - Parameters:
    ///   - requestedOffset: the `Range` start in `request`; nil without one.
    ///   - storedETag: the ETag kept with the partial.
    init(request: URLRequest, pack: PackManifest.Pack, files: PackPartialFiles, requestedOffset: Int64?,
         storedETag: String?, configuration: URLSessionConfiguration) {
        self.request = request
        self.pack = pack
        self.files = files
        self.requestedOffset = requestedOffset
        self.storedETag = storedETag
        self.configuration = configuration
        written = requestedOffset ?? 0
        super.init()
    }

    /// Bytes of the file on disk (including the part kept from before).
    var receivedBytes: Int64 { lock.withLock { written } }

    func cancel() {
        lock.withLock {
            cancelRequested = true
            task?.cancel()
        }
    }

    func run() async -> Result {
        await withCheckedContinuation { (continuation: CheckedContinuation<Result, Never>) in
            let queue = OperationQueue()
            queue.maxConcurrentOperationCount = 1
            // The delegate appends to the partial file: background-ish
            // work, never above `.utility` (UX-8, capture fidelity first).
            queue.qualityOfService = .utility
            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
            let task = session.dataTask(with: request)
            let cancelled = lock.withLock { () -> Bool in
                self.continuation = continuation
                self.session = session
                self.task = task
                return cancelRequested
            }
            if cancelled {
                finish(.cancelled)
            } else {
                task.resume()
            }
            session.finishTasksAndInvalidate()
        }
    }

    private func finish(_ result: Result) {
        let pending = lock.withLock { () -> CheckedContinuation<Result, Never>? in
            let c = continuation
            continuation = nil
            return c
        }
        pending?.resume(returning: result)
    }

    private func decide(_ result: Result) {
        lock.withLock { if decided == nil { decided = result } }
    }

    // MARK: URLSessionDataDelegate

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else {
            decide(.failed("not an HTTP response"))
            completionHandler(.cancel)
            return
        }
        let length = http.expectedContentLength >= 0 ? http.expectedContentLength : nil
        let stored = lock.withLock { storedETag }
        let etag = http.value(forHTTPHeaderField: "ETag")
        let decision = PackDownloadRules.decide(
            status: http.statusCode, requestedOffset: requestedOffset,
            contentRange: http.value(forHTTPHeaderField: "Content-Range"), etag: etag, storedETag: stored,
            expectedSize: pack.size, contentLength: length)
        switch decision {
        case .restartWithoutRange(let reason):
            decide(.restart(reason))
            completionHandler(.cancel)
        case .fail(let reason):
            decide(http.statusCode == 404 ? .notFound(reason) : .failed(reason))
            completionHandler(.cancel)
        case .append:
            do {
                let file = try FileHandle(forWritingTo: files.partial)
                let end = try file.seekToEnd()
                guard Int64(end) == requestedOffset else {
                    try? file.close()
                    decide(.restart("the partial is \(end) bytes, expected \(requestedOffset ?? -1)"))
                    completionHandler(.cancel)
                    return
                }
                lock.withLock { handle = file; written = Int64(end) }
                if let etag, stored == nil {
                    files.writeMetadata(PackDownloadRules.PartialMetadata(pack: pack, etag: etag))
                    lock.withLock { storedETag = etag }
                }
                completionHandler(.allow)
            } catch {
                decide(.failed("cannot write the file: \(error.localizedDescription)"))
                completionHandler(.cancel)
            }
        case .writeFromZero(let etag):
            do {
                try Data().write(to: files.partial)
                let file = try FileHandle(forWritingTo: files.partial)
                lock.withLock { handle = file; written = 0; storedETag = etag }
                files.writeMetadata(PackDownloadRules.PartialMetadata(pack: pack, etag: etag))
                completionHandler(.allow)
            } catch {
                decide(.failed("cannot write the file: \(error.localizedDescription)"))
                completionHandler(.cancel)
            }
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let file = lock.withLock { handle }
        guard let file else { return }
        let total = lock.withLock { written + Int64(data.count) }
        if total > pack.size {
            decide(.failed("the server sent more than \(pack.size) bytes"))
            dataTask.cancel()
            return
        }
        do {
            try file.write(contentsOf: data)
            lock.withLock { written = total }
        } catch {
            decide(.failed("cannot write the file: \(error.localizedDescription)"))
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let (file, verdict, cancelled) = lock.withLock { () -> (FileHandle?, Result?, Bool) in
            let f = handle
            handle = nil
            return (f, decided, cancelRequested)
        }
        try? file?.close()
        if let verdict {
            finish(verdict)
        } else if cancelled {
            finish(.cancelled)
        } else if let error {
            if let refusal = Refusal(error) { finish(.refused(refusal)) } else {
                finish(.transport(error.localizedDescription))
            }
        } else {
            finish(.completed)
        }
    }
}
