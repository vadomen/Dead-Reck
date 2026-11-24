import Foundation

/// Follows a short map link to its full URL (prompt 53a item 2). Called only after
/// the driver taps "Open link". One request goes to the link's own host (for
/// example Google); nothing goes to us. Rules:
/// - ephemeral session: no cookies, no cache, no credentials stored;
/// - HEAD first, GET only if HEAD is refused; the body is never read: the
///   request is cancelled as soon as the final response headers arrive;
/// - at most `maxRedirects` redirects, and every hop must pass
///   `MapLinkHosts.mayFollow` (https, no user info, known map host), else stop;
/// - about 8 s per request.
/// Throws `RouteServiceError`: `.nothingFound` when it had to stop (a hop that
/// is not allowed, too many redirects, a final page that is not a map link, a
/// 404), `.offline` for no network or a timeout, `.throttled` for HTTP 429,
/// `.failed` for the rest.
protocol MapLinkResolving: Sendable {
    func resolve(_ url: URL) async throws -> URL
}

struct MapLinkResolver: MapLinkResolving {
    static let timeoutS: TimeInterval = 8
    static let maxRedirects = 5

    /// Tests set `protocolClasses` here; nothing else is configurable.
    private let configure: @Sendable (URLSessionConfiguration) -> Void

    init(configure: @escaping @Sendable (URLSessionConfiguration) -> Void = { _ in }) {
        self.configure = configure
    }

    static func makeConfiguration() -> URLSessionConfiguration {
        let c = URLSessionConfiguration.ephemeral
        c.urlCache = nil
        c.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        c.httpCookieStorage = nil
        c.httpCookieAcceptPolicy = .never
        c.httpShouldSetCookies = false
        c.urlCredentialStorage = nil
        c.timeoutIntervalForRequest = timeoutS
        c.timeoutIntervalForResource = timeoutS
        c.waitsForConnectivity = false
        c.tlsMinimumSupportedProtocolVersion = .TLSv12
        return c
    }

    private enum Outcome {
        case final(URL)
        /// HEAD answered with a refusal: try GET.
        case refused
    }

    func resolve(_ url: URL) async throws -> URL {
        guard MapLinkHosts.mayFollow(url) else { throw RouteServiceError.nothingFound }
        switch try await attempt(url, method: "HEAD") {
        case .final(let final): return final
        case .refused:
            if case .final(let final) = try await attempt(url, method: "GET") { return final }
            throw RouteServiceError.failed
        }
    }

    private func attempt(_ url: URL, method: String) async throws -> Outcome {
        let configuration = Self.makeConfiguration()
        configure(configuration)
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: Self.timeoutS)
        request.httpMethod = method
        request.httpShouldHandleCookies = false
        let probe = HeaderProbe()
        let session = URLSession(configuration: configuration, delegate: probe, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: request)
        await withTaskCancellationHandler { await probe.run(task) } onCancel: { task.cancel() }
        if probe.didStop { throw RouteServiceError.nothingFound }
        let response = probe.response
        if response == nil {
            if Task.isCancelled || (probe.error as? URLError)?.code == .cancelled { throw CancellationError() }
            let ns = (probe.error ?? URLError(.unknown)) as NSError
            throw MapKitErrorMapping.map(code: ns.code, domain: ns.domain)
        }
        guard let http = response else { throw RouteServiceError.failed }
        switch http.statusCode {
        case 200..<300:
            guard let final = http.url, MapLinkHosts.mayFollow(final) else { throw RouteServiceError.nothingFound }
            return .final(final)
        case 400, 403, 405, 501:
            if method == "HEAD" { return .refused }
            throw RouteServiceError.failed
        case 404, 410: throw RouteServiceError.nothingFound
        case 429: throw RouteServiceError.throttled
        default: throw RouteServiceError.failed
        }
    }
}

/// The delegate of one request: decides every redirect hop (https and a known map
/// host, at most five) and takes the final response's headers, then cancels the
/// load so the body is never read.
private final class HeaderProbe: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    // Written from URLSession's delegate queue, read after the await: the lock covers both.
    private let lock = NSLock()
    private var hops = 0
    private var stopped = false
    private var received: HTTPURLResponse?
    private var failure: Error?
    private var continuation: CheckedContinuation<Void, Never>?
    private var finished = false

    var didStop: Bool { lock.withLock { stopped } }
    var response: HTTPURLResponse? { lock.withLock { received } }
    var error: Error? { lock.withLock { failure } }

    /// Starts `task` and returns when it has ended (headers taken and cancelled, failed, or stopped).
    func run(_ task: URLSessionDataTask) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.withLock { self.continuation = continuation }
            task.resume()
        }
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
    ) {
        let allowed = lock.withLock { () -> Bool in
            hops += 1
            if hops <= MapLinkResolver.maxRedirects, let url = request.url, MapLinkHosts.mayFollow(url) { return true }
            stopped = true
            return false
        }
        guard allowed else {
            // Stop here: the redirect's own page is not wanted either.
            completionHandler(nil)
            task.cancel()
            finish(nil)
            return
        }
        var next = request
        next.httpShouldHandleCookies = false
        completionHandler(next)
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        lock.withLock { received = response as? HTTPURLResponse }
        // Headers are all that is wanted: the load is cancelled now and the body is never read.
        completionHandler(.cancel)
        finish(nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        finish(error)
    }

    /// Ends `run` once, whichever of the three callbacks comes first.
    private func finish(_ error: Error?) {
        let pending = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            guard !finished else { return nil }
            finished = true
            failure = error
            defer { continuation = nil }
            return continuation
        }
        pending?.resume()
    }
}
