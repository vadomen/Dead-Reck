import Foundation

/// Typed coordinates and pasted map links (prompt 53a items 1 and 2): a PURE
/// parser. Foundation only, no MapKit, no network: nothing here sends anything
/// anywhere. A short link is only recognised here; following it is
/// `MapLinkResolver`, and only after the driver taps "Open link".

/// A point found in text or in a link, not yet placed on a card.
struct ParsedPoint: Equatable, Sendable {
    var latitude: Double
    var longitude: Double
    /// The place name the link carried (Google `/place/<name>/`, Apple `name=`/`q=`), else nil.
    var name: String?

    /// "-45.12346, -120.54321": the card's subtitle. Always a decimal point, whatever the locale.
    var formatted: String {
        func text(_ value: Double) -> String {
            let s = String(format: "%.5f", locale: Locale(identifier: "en_US_POSIX"), value)
            // A tiny negative rounds to "-0.00000": no sign on a zero.
            return s.hasPrefix("-") && s.dropFirst().allSatisfy({ $0 == "0" || $0 == "." }) ? String(s.dropFirst()) : s
        }
        return text(latitude) + ", " + text(longitude)
    }
}

/// What the search field's text means.
enum CoordinateInput: Equatable, Sendable {
    /// Not coordinates and not a link: the completer decides.
    case none
    /// A point (typed, `geo:`, or a full map link).
    case point(ParsedPoint)
    /// Valid only when latitude and longitude are swapped. `point` is already the swapped reading;
    /// the UI offers it as its own labelled row and never applies it silently.
    case swapped(ParsedPoint)
    /// Numbers that cannot be a latitude and a longitude.
    case outOfRange
    /// A short link of a known map host: the row says "Open link"; nothing is requested until a tap.
    case shortLink(URL)
    /// A link (or `geo:`) with no usable point, or one that is not a known https map link.
    case noPoint

    /// Text read as coordinates (valid, swapped, or numbers out of range): its row shows alone and the
    /// text is never sent to the completer.
    var isCoordinateText: Bool {
        switch self {
        case .point, .swapped, .outOfRange: true
        default: false
        }
    }

    var point: ParsedPoint? {
        switch self {
        case .point(let p), .swapped(let p): p
        default: nil
        }
    }
}

enum CoordinateParser {
    /// Longer text is never parsed as a link (a hostile paste).
    static let maxLinkLength = 2_048
    /// Typed coordinates are short; longer text is a search.
    static let maxTextLength = 128
    static let maxNameLength = 80

    static func parse(_ raw: String) -> CoordinateInput {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .none }
        if let candidate = linkCandidate(text) {
            guard candidate.utf8.count <= maxLinkLength else { return .noPoint }
            if candidate.lowercased().hasPrefix("geo:") { return parseGeo(candidate) }
            return MapLinkParser.parse(candidate.contains("://") ? candidate : "https://" + candidate)
        }
        guard text.utf8.count <= maxTextLength else { return .none }
        return parseText(text)
    }

    /// True for text that is a link, a `geo:` URI or any other scheme: such text never goes to the completer.
    static func isLinkLike(_ raw: String) -> Bool {
        linkCandidate(raw.trimmingCharacters(in: .whitespacesAndNewlines)) != nil
    }

    // MARK: Link detection

    private static let dangerousSchemes: Set<String> = ["javascript", "data", "file", "vbscript", "mailto", "tel", "sms", "blob", "about"]

    /// The part of `text` that is a link: the whole text, or the first whitespace-separated word with
    /// a scheme (a share text can carry a title before the link). Nil when it is not link-like.
    private static func linkCandidate(_ text: String) -> String? {
        if text.lowercased().hasPrefix("geo:") { return text }
        let words = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        for word in words {
            if word.contains("://") { return word.trimmingCharacters(in: CharacterSet(charactersIn: ".,;)>\"'")) }
            if let colon = word.firstIndex(of: ":"), dangerousSchemes.contains(word[..<colon].lowercased()) { return word }
        }
        if words.count == 1, let first = text.first, first.isLetter, text.contains("."),
           let components = URLComponents(string: "https://" + text), let host = components.host?.lowercased(),
           MapLinkHosts.match(host: host, path: components.percentEncodedPath) != nil {
            return text
        }
        return nil
    }

    // MARK: Typed coordinates

    private static let numberPattern = #"^[+-]?[0-9]{1,7}([.,][0-9]{1,15})?$"#

    /// A decimal number, point or comma, as typed. Nil for anything else (NaN, inf, exponents, groups).
    static func number(_ token: String, allowComma: Bool = true) -> Double? {
        guard token.range(of: numberPattern, options: .regularExpression) != nil else { return nil }
        let normalised = token.replacingOccurrences(of: ",", with: ".")
        if !allowComma, token.contains(",") { return nil }
        guard let value = Double(normalised), value.isFinite else { return nil }
        return value
    }

    static func inRange(_ latitude: Double, _ longitude: Double) -> Bool {
        latitude.isFinite && longitude.isFinite && abs(latitude) <= 90 && abs(longitude) <= 180
    }

    private static func parseText(_ input: String) -> CoordinateInput {
        let allowed = CharacterSet(charactersIn: "0123456789+-.,;\u{00B0}\u{2212} \t\u{00A0}NSEWnsew")
        guard input.unicodeScalars.allSatisfy(allowed.contains) else { return .none }
        let text = input.replacingOccurrences(of: "\u{00B0}", with: " ").replacingOccurrences(of: "\u{2212}", with: "-")
        let hasSemicolon = text.contains(";")
        var tokens: [String] = []
        var sawComma = false
        for word in text.split(whereSeparator: { $0.isWhitespace || $0 == ";" || $0 == "\u{00A0}" }) {
            for var part in splitLetters(String(word)) {
                while part.hasSuffix(",") { part.removeLast(); sawComma = true }
                if !part.isEmpty { tokens.append(part) }
            }
        }
        // "50.45,30.52" with no space: one token with one comma between two numbers.
        if tokens.count == 1, tokens[0].filter({ $0 == "," }).count == 1, let comma = tokens[0].firstIndex(of: ",") {
            let single = tokens[0]
            tokens = [String(single[..<comma]), String(single[single.index(after: comma)...])]
            sawComma = true
        }
        let letters = tokens.filter { isLetterToken($0) }
        if letters.isEmpty {
            guard tokens.count == 2, let a = number(tokens[0]), let b = number(tokens[1]) else { return .none }
            let deliberate = sawComma || hasSemicolon || tokens.contains { $0.contains(".") || $0.contains(",") }
            return classify(first: a, second: b, deliberate: deliberate, allowSwap: true)
        }
        guard letters.count == 2, tokens.count == 4 else { return .none }
        // Letters before their numbers (N 50.1 E 30.2) or after them (50.1 N 30.2 E).
        let prefix = isLetterToken(tokens[0])
        let pairs: [(letter: String, value: String)] = prefix
            ? [(tokens[0], tokens[1]), (tokens[2], tokens[3])]
            : [(tokens[1], tokens[0]), (tokens[3], tokens[2])]
        var latitude: Double?
        var longitude: Double?
        for pair in pairs {
            guard !isLetterToken(pair.value), !pair.value.hasPrefix("-"), !pair.value.hasPrefix("+"),
                  let value = number(pair.value) else { return .none }
            switch pair.letter.uppercased() {
            case "N": guard latitude == nil else { return .none }; latitude = value
            case "S": guard latitude == nil else { return .none }; latitude = -value
            case "E": guard longitude == nil else { return .none }; longitude = value
            case "W": guard longitude == nil else { return .none }; longitude = -value
            default: return .none
            }
        }
        guard let latitude, let longitude else { return .none }
        return inRange(latitude, longitude) ? .point(ParsedPoint(latitude: latitude, longitude: longitude)) : .outOfRange
    }

    private static func classify(first: Double, second: Double, deliberate: Bool, allowSwap: Bool) -> CoordinateInput {
        if inRange(first, second) { return .point(ParsedPoint(latitude: first, longitude: second)) }
        guard deliberate else { return .none }
        if allowSwap, inRange(second, first) { return .swapped(ParsedPoint(latitude: second, longitude: first)) }
        return .outOfRange
    }

    private static func isLetterToken(_ token: String) -> Bool {
        token.count == 1 && "NSEWnsew".contains(token)
    }

    /// "50.45N" -> ["50.45", "N"]; "N50.45" -> ["N", "50.45"]; a word with a longer letter run stays whole (and fails later).
    private static func splitLetters(_ word: String) -> [String] {
        var out: [String] = []
        var current = ""
        var currentIsLetter: Bool?
        for ch in word {
            let isLetter = ch.isLetter
            if let currentIsLetter, currentIsLetter != isLetter {
                out.append(current)
                current = ""
            }
            current.append(ch)
            currentIsLetter = isLetter
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    // MARK: geo: URIs

    /// `geo:lat,lon[,alt][;crs=..;u=..][?q=...]` (RFC 5870, with Android's `geo:0,0?q=lat,lon`).
    private static func parseGeo(_ text: String) -> CoordinateInput {
        var rest = String(text.dropFirst(4))
        var query = ""
        if let q = rest.firstIndex(of: "?") {
            query = String(rest[rest.index(after: q)...])
            rest = String(rest[..<q])
        }
        let coordinates = rest.split(separator: ";", omittingEmptySubsequences: false).first.map(String.init) ?? ""
        let parts = coordinates.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2 || parts.count == 3,
              let latitude = number(parts[0], allowComma: false), let longitude = number(parts[1], allowComma: false)
        else { return .noPoint }
        if parts.count == 3, number(parts[2], allowComma: false) == nil { return .noPoint }
        var label: String?
        var queryPair: (Double, Double)?
        for item in MapLinkParser.queryItems(query) where item.name == "q" {
            if let pair = MapLinkParser.pair(item.value) { queryPair = pair } else { label = MapLinkParser.cleanName(item.value) }
        }
        if latitude == 0, longitude == 0, let queryPair {
            return MapLinkParser.finish(latitude: queryPair.0, longitude: queryPair.1, name: nil)
        }
        if latitude == 0, longitude == 0, label != nil { return .noPoint }
        return MapLinkParser.finish(latitude: latitude, longitude: longitude, name: label)
    }
}

// MARK: - Map links

/// Which hosts are map links. Explicit on purpose: this is the whole allowlist, for parsing and for
/// every hop of a followed short link (`docs/ROUTING.md`).
enum MapLinkHosts {
    enum Provider: Equatable, Sendable { case google, apple, osm }
    struct Match: Equatable, Sendable {
        var provider: Provider
        /// A short link: the point is not in the URL, it takes a redirect to get it.
        var isShort: Bool
    }

    /// For the docs and a test that pins them.
    static let documented = [
        "google.com and google.co.xx / google.com.xx / google.xx (two-letter country code), as www., bare (path /maps...) or maps. (any path)",
        "maps.app.goo.gl; goo.gl (path /maps...); g.co (path /kgs...)",
        "maps.apple.com; maps.apple (short)",
        "openstreetmap.org, www.openstreetmap.org, osm.org, www.osm.org (osm.org/go/... is short)",
    ]

    /// `host` lower-cased, no trailing dot; `path` as in the URL (case preserved is fine).
    static func match(host: String, path: String) -> Match? {
        let host = host.lowercased()
        let path = path.lowercased()
        if let google = googlePrefix(host) {
            if google == "maps." || path == "/maps" || path.hasPrefix("/maps/") { return Match(provider: .google, isShort: false) }
            return nil
        }
        switch host {
        case "maps.app.goo.gl": return Match(provider: .google, isShort: true)
        case "goo.gl": return path.hasPrefix("/maps") ? Match(provider: .google, isShort: true) : nil
        case "g.co": return path.hasPrefix("/kgs") ? Match(provider: .google, isShort: true) : nil
        case "maps.apple.com": return Match(provider: .apple, isShort: false)
        case "maps.apple": return Match(provider: .apple, isShort: true)
        case "openstreetmap.org", "www.openstreetmap.org", "osm.org", "www.osm.org":
            return Match(provider: .osm, isShort: false)
        default: return nil
        }
    }

    /// "www." / "maps." / "" when `host` is a Google domain, else nil.
    private static func googlePrefix(_ host: String) -> String? {
        var rest = host
        var prefix = ""
        for candidate in ["www.", "maps."] where rest.hasPrefix(candidate) {
            prefix = candidate
            rest.removeFirst(candidate.count)
            break
        }
        guard rest.hasPrefix("google.") else { return nil }
        let tld = rest.dropFirst("google.".count).split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        func twoLetters(_ s: String) -> Bool { s.count == 2 && s.allSatisfy { $0 >= "a" && $0 <= "z" } }
        switch tld.count {
        case 1: return (tld[0] == "com" || twoLetters(tld[0])) ? prefix : nil
        case 2: return ((tld[0] == "co" || tld[0] == "com") && twoLetters(tld[1])) ? prefix : nil
        default: return nil
        }
    }

    /// The rule for every hop of a followed link: https, no user info, the default port, a known map host.
    static func mayFollow(_ url: URL) -> Bool {
        guard let c = URLComponents(url: url, resolvingAgainstBaseURL: false), c.scheme?.lowercased() == "https",
              c.user == nil, c.password == nil, c.port == nil || c.port == 443, let host = c.host
        else { return false }
        return match(host: normalisedHost(host), path: c.percentEncodedPath) != nil
    }

    static func normalisedHost(_ host: String) -> String {
        var h = host.lowercased()
        while h.hasSuffix(".") { h.removeLast() }
        return h
    }
}

enum MapLinkParser {
    static func parse(_ string: String) -> CoordinateInput {
        guard string.utf8.count <= CoordinateParser.maxLinkLength,
              let c = URLComponents(string: string), c.scheme?.lowercased() == "https",
              c.user == nil, c.password == nil, c.port == nil || c.port == 443,
              let rawHost = c.host, !rawHost.isEmpty,
              let match = MapLinkHosts.match(host: MapLinkHosts.normalisedHost(rawHost), path: c.percentEncodedPath),
              let url = c.url
        else { return .noPoint }
        let path = c.percentEncodedPath
        if match.isShort {
            let meaningful = path.count > 1
            return meaningful ? .shortLink(url) : .noPoint
        }
        let found: (lat: Double, lon: Double, name: String?)?
        switch match.provider {
        case .google: found = google(c)
        case .apple: found = apple(c)
        case .osm: found = osm(c)
        }
        if let found { return finish(latitude: found.lat, longitude: found.lon, name: found.name) }
        // Short forms on a full host: maps.apple.com/p/<token>, osm.org/go/<code>.
        let lower = path.lowercased()
        if (match.provider == .apple && lower.hasPrefix("/p/")) || (match.provider == .osm && lower.hasPrefix("/go/")) {
            return .shortLink(url)
        }
        return .noPoint
    }

    static func finish(latitude: Double, longitude: Double, name: String?) -> CoordinateInput {
        CoordinateParser.inRange(latitude, longitude)
            ? .point(ParsedPoint(latitude: latitude, longitude: longitude, name: name)) : .outOfRange
    }

    // MARK: Providers

    private typealias Found = (lat: Double, lon: Double, name: String?)

    /// Place point beats view centre: `!3d!4d`, then `q`/`query`/`destination`, then a `/place/lat,lon` segment, then `@lat,lon`.
    private static func google(_ c: URLComponents) -> Found? {
        let items = queryItems(c.percentEncodedQuery ?? "")
        let segments = pathSegments(c)
        var name: String?
        if let i = segments.firstIndex(where: { $0.lowercased() == "place" }), segments.indices.contains(i + 1) {
            let segment = segments[i + 1]
            if pair(segment) == nil, !segment.hasPrefix("@") { name = cleanName(segment) }
        }
        let decoded = (c.percentEncodedPath + "?" + (c.percentEncodedQuery ?? "")).removingPercentEncoding ?? ""
        if let m = lastMatch(#"!3d(-?[0-9]+([.][0-9]+)?)!4d(-?[0-9]+([.][0-9]+)?)"#, in: decoded),
           let lat = Double(m[0]), let lon = Double(m[2]) {
            return (lat, lon, name)
        }
        for key in ["q", "query", "destination"] {
            for item in items where item.name == key {
                if let p = pair(item.value) { return (p.0, p.1, nil) }
            }
        }
        if let i = segments.firstIndex(where: { ["place", "search"].contains($0.lowercased()) }), segments.indices.contains(i + 1),
           let p = pair(decodeComponent(segments[i + 1])) {
            return (p.0, p.1, nil)
        }
        if let m = lastMatch(#"@(-?[0-9]+([.][0-9]+)?),(-?[0-9]+([.][0-9]+)?)"#, in: decoded),
           let lat = Double(m[0]), let lon = Double(m[2]) {
            return (lat, lon, name)
        }
        return nil
    }

    /// `coordinate=`, then `q=lat,lon`, then `ll=`, then `sll=`. The name is `name=`, else a `q=` that is not a pair.
    private static func apple(_ c: URLComponents) -> Found? {
        let items = queryItems(c.percentEncodedQuery ?? "")
        func value(_ key: String) -> String? { items.first { $0.name == key }?.value }
        var name = value("name").flatMap(cleanName)
        if name == nil, let q = value("q"), pair(q) == nil { name = cleanName(q) }
        for key in ["coordinate", "q", "ll", "sll"] {
            if let v = value(key), let p = pair(v) { return (p.0, p.1, name) }
        }
        return nil
    }

    /// `mlat`/`mlon` (the marker), then `#map=zoom/lat/lon` (the view).
    private static func osm(_ c: URLComponents) -> Found? {
        let items = queryItems(c.percentEncodedQuery ?? "")
        if let a = items.first(where: { $0.name == "mlat" })?.value, let b = items.first(where: { $0.name == "mlon" })?.value,
           let lat = CoordinateParser.number(a, allowComma: false), let lon = CoordinateParser.number(b, allowComma: false) {
            return (lat, lon, nil)
        }
        let fragment = (c.percentEncodedFragment ?? "").removingPercentEncoding ?? ""
        for part in fragment.split(separator: "&") where part.hasPrefix("map=") {
            let fields = part.dropFirst(4).split(separator: "/").map(String.init)
            if fields.count == 3, let lat = CoordinateParser.number(fields[1], allowComma: false),
               let lon = CoordinateParser.number(fields[2], allowComma: false) {
                return (lat, lon, nil)
            }
        }
        return nil
    }

    // MARK: Helpers

    private static let pairPattern = #"^[ ]*([+-]?[0-9]{1,7}([.][0-9]{1,15})?)[ ]*,[ ]*([+-]?[0-9]{1,7}([.][0-9]{1,15})?)[ ]*$"#

    /// "lat,lon" with decimal points; nil for anything else.
    static func pair(_ s: String) -> (Double, Double)? {
        guard s.utf8.count <= 80, let m = firstMatch(pairPattern, in: s), let a = Double(m[0]), let b = Double(m[2]),
              a.isFinite, b.isFinite else { return nil }
        return (a, b)
    }

    static func queryItems(_ query: String) -> [(name: String, value: String)] {
        query.split(separator: "&").compactMap { part in
            let pieces = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let key = pieces.first, !key.isEmpty else { return nil }
            let value = pieces.count > 1 ? decodeComponent(String(pieces[1])) : ""
            return (decodeComponent(String(key)).lowercased(), value)
        }
    }

    private static func pathSegments(_ c: URLComponents) -> [String] {
        c.percentEncodedPath.split(separator: "/", omittingEmptySubsequences: true).map { decodeComponent(String($0)) }
    }

    static func decodeComponent(_ s: String) -> String {
        let plus = s.replacingOccurrences(of: "+", with: " ")
        return plus.removingPercentEncoding ?? plus
    }

    /// A name for the card: no control characters, trimmed, at most `maxNameLength`; nil when empty.
    static func cleanName(_ s: String) -> String? {
        let cleaned = decodeComponent(s).unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        let text = String(String.UnicodeScalarView(cleaned)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return String(text.prefix(CoordinateParser.maxNameLength))
    }

    private static func firstMatch(_ pattern: String, in s: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = s as NSString
        guard let m = regex.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return (1..<m.numberOfRanges).map { m.range(at: $0).location == NSNotFound ? "" : ns.substring(with: m.range(at: $0)) }
    }

    private static func lastMatch(_ pattern: String, in s: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = s as NSString
        guard let m = regex.matches(in: s, range: NSRange(location: 0, length: ns.length)).last else { return nil }
        return (1..<m.numberOfRanges).map { m.range(at: $0).location == NSNotFound ? "" : ns.substring(with: m.range(at: $0)) }
    }
}
