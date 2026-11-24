import Foundation
import Testing

@testable import DriveLogger

/// A scripted network for `MapLinkResolver`: no request leaves the test process.
/// Scripts are keyed by the full URL string; every test uses its own path so the
/// serialized suite and the shared table never mix.
final class LinkStubProtocol: URLProtocol, @unchecked Sendable {
    enum Reply {
        case redirect(String)
        case ok
        /// Headers and one byte of body, then nothing: a resolver that waits for the end of the body hangs here.
        case okThenSilence
        case status(Int)
        case fail(URLError.Code)
    }

    struct Script {
        var any: Reply
        /// For HEAD only, when it differs.
        var head: Reply?
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var scripts: [String: Script] = [:]
    nonisolated(unsafe) private static var log: [(method: String, url: String)] = []
    nonisolated(unsafe) private static var stopped = 0

    static func reset() {
        lock.withLock {
            scripts = [:]
            log = []
            stopped = 0
        }
    }

    static func set(_ url: String, _ reply: Reply, head: Reply? = nil) {
        lock.withLock { scripts[url] = Script(any: reply, head: head) }
    }

    static var requests: [(method: String, url: String)] { lock.withLock { log } }
    static var stopCount: Int { lock.withLock { stopped } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        let method = request.httpMethod ?? "GET"
        let key = url.absoluteString
        let script = Self.lock.withLock { () -> Script? in
            Self.log.append((method, key))
            return Self.scripts[key]
        }
        guard let script else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        let reply = method == "HEAD" ? (script.head ?? script.any) : script.any
        switch reply {
        case .redirect(let to):
            let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: nil, headerFields: ["Location": to])!
            var next = URLRequest(url: URL(string: to)!)
            next.httpMethod = method
            client?.urlProtocol(self, wasRedirectedTo: next, redirectResponse: response)
        case .ok:
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
        case .okThenSilence:
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(repeating: 0x3C, count: 16_384))
        case .status(let code):
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: code, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
        case .fail(let code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        }
    }

    override func stopLoading() { Self.lock.withLock { Self.stopped += 1 } }
}

/// The short-link resolver (prompt 53a item 2): redirects, hosts, scheme, limits, errors.
@Suite("Map link resolver", .serialized)
struct MapLinkResolverTests {
    let resolver = MapLinkResolver { $0.protocolClasses = [LinkStubProtocol.self] }

    init() { LinkStubProtocol.reset() }

    static let start = "https://maps.app.goo.gl/t"

    /// A chain of `count` redirects from `start` to a full link; returns the final URL.
    @discardableResult
    static func chain(_ id: String, count: Int) -> String {
        let final = "https://www.google.com/maps/place/Test+Cove/@-45.5,-120.5,17z/\(id)"
        var hops = ["https://maps.app.goo.gl/\(id)"]
        for i in 1..<max(count, 1) { hops.append(i % 2 == 0 ? "https://goo.gl/maps/\(id)\(i)" : "https://maps.app.goo.gl/\(id)x\(i)") }
        hops.append(final)
        for i in 0..<hops.count - 1 { LinkStubProtocol.set(hops[i], .redirect(hops[i + 1])) }
        LinkStubProtocol.set(final, .ok)
        return final
    }

    @Test("A redirect chain to a full link resolves to the final URL, which the parser reads")
    func chainResolves() async throws {
        let final = Self.chain("a1", count: 2)
        let resolved = try await resolver.resolve(URL(string: "https://maps.app.goo.gl/a1")!)
        #expect(resolved.absoluteString == final)
        guard case .point(let p) = CoordinateParser.parse(resolved.absoluteString) else {
            Issue.record("no point")
            return
        }
        #expect(p.name == "Test Cove")
        #expect(LinkStubProtocol.requests.allSatisfy { $0.method == "HEAD" }, "HEAD only while HEAD works")
    }

    @Test("Five redirects are followed, a sixth stops")
    func redirectLimit() async throws {
        let final = Self.chain("b5", count: 5)
        #expect(try await resolver.resolve(URL(string: "https://maps.app.goo.gl/b5")!).absoluteString == final)
        Self.chain("b6", count: 6)
        await #expect(throws: RouteServiceError.nothingFound) { try await resolver.resolve(URL(string: "https://maps.app.goo.gl/b6")!) }
        #expect(!LinkStubProtocol.requests.contains { $0.url.hasSuffix("/b6") && $0.url.contains("google.com") }, "the page after the sixth hop is never requested")
    }

    @Test("A hop to an unknown host stops: it is never requested")
    func unknownHostStops() async {
        LinkStubProtocol.set("https://maps.app.goo.gl/c1", .redirect("https://consent.google.com/m?continue=x"))
        LinkStubProtocol.set("https://consent.google.com/m?continue=x", .ok)
        await #expect(throws: RouteServiceError.nothingFound) { try await resolver.resolve(URL(string: "https://maps.app.goo.gl/c1")!) }
        #expect(!LinkStubProtocol.requests.contains { $0.url.contains("consent.google.com") })
    }

    @Test("A hop to http stops, even to a map host")
    func httpStops() async {
        LinkStubProtocol.set("https://maps.app.goo.gl/d1", .redirect("http://www.google.com/maps/@-45.5,-120.5,17z"))
        LinkStubProtocol.set("http://www.google.com/maps/@-45.5,-120.5,17z", .ok)
        await #expect(throws: RouteServiceError.nothingFound) { try await resolver.resolve(URL(string: "https://maps.app.goo.gl/d1")!) }
        #expect(LinkStubProtocol.requests.count == 1)
    }

    @Test("A hop to a look-alike host stops")
    func lookAlikeStops() async {
        LinkStubProtocol.set("https://maps.app.goo.gl/e1", .redirect("https://maps.google.com.evil.example/?q=-45.1,-120.5"))
        await #expect(throws: RouteServiceError.nothingFound) { try await resolver.resolve(URL(string: "https://maps.app.goo.gl/e1")!) }
        #expect(LinkStubProtocol.requests.count == 1)
    }

    @Test("A start that is not an allowed link is refused before any request")
    func badStart() async {
        for text in ["http://maps.app.goo.gl/x", "https://evil.example/x", "https://consent.google.com/x", "javascript:alert(1)"] {
            await #expect(throws: RouteServiceError.nothingFound) { try await resolver.resolve(URL(string: text)!) }
        }
        #expect(LinkStubProtocol.requests.isEmpty)
    }

    @Test("A final page that is not a map link is no point")
    func finalNotAMap() async {
        LinkStubProtocol.set("https://maps.app.goo.gl/f1", .ok)
        // The page itself is fine and a map host: the parser then finds no point in it.
        let resolved = try? await resolver.resolve(URL(string: "https://maps.app.goo.gl/f1")!)
        #expect(resolved?.absoluteString == "https://maps.app.goo.gl/f1")
        #expect(resolved.map { CoordinateParser.parse($0.absoluteString) } == .shortLink(resolved!), "a short link again is no point for the flow")
    }

    @Test("A timeout or no network is offline; a cancelled load is cancellation")
    func networkErrors() async {
        LinkStubProtocol.set("https://maps.app.goo.gl/g1", .fail(.timedOut))
        await #expect(throws: RouteServiceError.offline) { try await resolver.resolve(URL(string: "https://maps.app.goo.gl/g1")!) }
        LinkStubProtocol.set("https://maps.app.goo.gl/g2", .fail(.notConnectedToInternet))
        await #expect(throws: RouteServiceError.offline) { try await resolver.resolve(URL(string: "https://maps.app.goo.gl/g2")!) }
        LinkStubProtocol.set("https://maps.app.goo.gl/g3", .fail(.badServerResponse))
        await #expect(throws: RouteServiceError.failed) { try await resolver.resolve(URL(string: "https://maps.app.goo.gl/g3")!) }
    }

    @Test("HTTP statuses: 429 is throttled, 404 is no point, 500 is a failure")
    func statuses() async {
        LinkStubProtocol.set("https://maps.app.goo.gl/h1", .status(429))
        await #expect(throws: RouteServiceError.throttled) { try await resolver.resolve(URL(string: "https://maps.app.goo.gl/h1")!) }
        LinkStubProtocol.set("https://maps.app.goo.gl/h2", .status(404))
        await #expect(throws: RouteServiceError.nothingFound) { try await resolver.resolve(URL(string: "https://maps.app.goo.gl/h2")!) }
        LinkStubProtocol.set("https://maps.app.goo.gl/h3", .status(500))
        await #expect(throws: RouteServiceError.failed) { try await resolver.resolve(URL(string: "https://maps.app.goo.gl/h3")!) }
    }

    @Test("HEAD refused falls back to GET once; a working HEAD never uses GET")
    func headFallback() async throws {
        LinkStubProtocol.set("https://maps.app.goo.gl/i1", .ok, head: .status(405))
        let resolved = try await resolver.resolve(URL(string: "https://maps.app.goo.gl/i1")!)
        #expect(resolved.absoluteString == "https://maps.app.goo.gl/i1")
        #expect(LinkStubProtocol.requests.map(\.method) == ["HEAD", "GET"])
        LinkStubProtocol.reset()
        LinkStubProtocol.set("https://maps.app.goo.gl/i2", .status(405))
        await #expect(throws: RouteServiceError.failed) { try await resolver.resolve(URL(string: "https://maps.app.goo.gl/i2")!) }
        #expect(LinkStubProtocol.requests.map(\.method) == ["HEAD", "GET"], "GET refused too: one retry, no loop")
    }

    @Test("The body is never waited for: the request is cancelled when the final headers arrive")
    func bodyNeverRead() async throws {
        // HEAD is refused, so the GET runs: its body would never end.
        LinkStubProtocol.set("https://maps.app.goo.gl/j1", .okThenSilence, head: .status(405))
        let resolved = try await resolver.resolve(URL(string: "https://maps.app.goo.gl/j1")!)
        #expect(resolved.absoluteString == "https://maps.app.goo.gl/j1")
        #expect(LinkStubProtocol.stopCount >= 1)
    }

    @Test("The session is ephemeral: no cache, no cookies, no credentials, 8 s")
    func configuration() {
        let c = MapLinkResolver.makeConfiguration()
        #expect(c.urlCache == nil && c.httpCookieStorage == nil && c.urlCredentialStorage == nil)
        #expect(c.httpCookieAcceptPolicy == .never && !c.httpShouldSetCookies)
        #expect(c.requestCachePolicy == .reloadIgnoringLocalAndRemoteCacheData)
        #expect(c.timeoutIntervalForRequest == 8 && c.timeoutIntervalForResource == 8)
        #expect(!c.waitsForConnectivity)
        #expect(MapLinkResolver.maxRedirects == 5)
    }
}
