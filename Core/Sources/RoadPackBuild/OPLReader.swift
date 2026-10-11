import DriveLoggerCore
import Foundation

/// One OSM way from an OPL file written by
/// `osmium add-locations-to-ways -f opl` (node locations on the way).
public struct OPLWay: Hashable, Sendable {
    public struct NodeRef: Hashable, Sendable {
        public var id: Int64
        /// nil when the OPL line has no location for the node.
        public var location: RoadPoint?
    }

    public var id: Int64
    public var tags: [String: String]
    public var nodes: [NodeRef]
}

/// Why an OPL file could not be read.
public struct OPLError: Error, CustomStringConvertible, Equatable {
    public var line: Int
    public var message: String
    public var description: String { "OPL line \(line): \(message)" }
}

/// Reads the ways of an OPL file (https://osmcode.org/opl-file-format/).
/// Node, relation and changeset lines are skipped: the builder needs the
/// node locations only on ways, which `add-locations-to-ways` provides.
/// Coordinates are converted to E7 exactly, from their decimal text.
public enum OPLReader {
    /// Every way in `data`, in file order.
    public static func ways(in data: Data) throws -> [OPLWay] {
        var out: [OPLWay] = []
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let bytes = raw.bindMemory(to: UInt8.self)
            var lineStart = 0
            var lineNumber = 0
            let count = bytes.count
            while lineStart < count {
                var lineEnd = lineStart
                while lineEnd < count, bytes[lineEnd] != 0x0A { lineEnd += 1 }
                lineNumber += 1
                var end = lineEnd
                if end > lineStart, bytes[end - 1] == 0x0D { end -= 1 }
                if end > lineStart, bytes[lineStart] == UInt8(ascii: "w") {
                    out.append(try parseWay(UnsafeBufferPointer(rebasing: bytes[lineStart..<end]), line: lineNumber))
                }
                lineStart = lineEnd + 1
            }
        }
        return out
    }

    public static func ways(in text: String) throws -> [OPLWay] {
        try ways(in: Data(text.utf8))
    }

    static func parseWay(_ line: UnsafeBufferPointer<UInt8>, line number: Int) throws -> OPLWay {
        func fail(_ message: String) -> OPLError { OPLError(line: number, message: message) }
        var id: Int64?
        var tags: [String: String] = [:]
        var nodes: [OPLWay.NodeRef] = []
        var sawNodes = false
        var tokenStart = 0
        let n = line.count
        while tokenStart < n {
            var tokenEnd = tokenStart
            while tokenEnd < n, line[tokenEnd] != 0x20 { tokenEnd += 1 }
            if tokenEnd > tokenStart {
                let token = UnsafeBufferPointer(rebasing: line[tokenStart..<tokenEnd])
                let body = UnsafeBufferPointer(rebasing: token[1...])
                switch token[0] {
                case UInt8(ascii: "w"):
                    guard let value = parseInteger(body) else { throw fail("bad way id") }
                    id = value
                case UInt8(ascii: "T"):
                    tags = try parseTags(body, fail: fail)
                case UInt8(ascii: "N"):
                    sawNodes = true
                    nodes = try parseNodes(body, fail: fail)
                default:
                    break  // v, d, c, t, i, u: version and changeset metadata
                }
            }
            tokenStart = tokenEnd + 1
        }
        guard let id else { throw fail("way without id") }
        guard sawNodes else { throw fail("way \(id) has no node list") }
        return OPLWay(id: id, tags: tags, nodes: nodes)
    }

    static func parseInteger(_ bytes: UnsafeBufferPointer<UInt8>) -> Int64? {
        guard !bytes.isEmpty else { return nil }
        var i = 0
        var negative = false
        if bytes[0] == UInt8(ascii: "-") { negative = true; i = 1 }
        guard i < bytes.count else { return nil }
        var value: Int64 = 0
        while i < bytes.count {
            let d = bytes[i] &- 0x30
            guard d < 10 else { return nil }
            let (m, o1) = value.multipliedReportingOverflow(by: 10)
            let (s, o2) = m.addingReportingOverflow(Int64(d))
            guard !o1, !o2 else { return nil }
            value = s
            i += 1
        }
        return negative ? -value : value
    }

    /// Decimal degrees text → E7, exactly (no floating point). At most 7
    /// decimals; more are refused rather than rounded.
    static func parseE7(_ bytes: UnsafeBufferPointer<UInt8>) -> Int32? {
        guard !bytes.isEmpty else { return nil }
        var i = 0
        var negative = false
        if bytes[0] == UInt8(ascii: "-") { negative = true; i = 1 }
        var whole: Int64 = 0
        var digits = 0
        while i < bytes.count, bytes[i] != UInt8(ascii: ".") {
            let d = bytes[i] &- 0x30
            guard d < 10, digits < 4 else { return nil }
            whole = whole * 10 + Int64(d)
            digits += 1
            i += 1
        }
        guard digits > 0 else { return nil }
        var fraction: Int64 = 0
        var fractionDigits = 0
        if i < bytes.count {
            i += 1  // "."
            while i < bytes.count {
                let d = bytes[i] &- 0x30
                guard d < 10, fractionDigits < 7 else { return nil }
                fraction = fraction * 10 + Int64(d)
                fractionDigits += 1
                i += 1
            }
        }
        while fractionDigits < 7 { fraction *= 10; fractionDigits += 1 }
        let value = whole * 10_000_000 + fraction
        let signed = negative ? -value : value
        guard signed >= Int64(Int32.min), signed <= Int64(Int32.max) else { return nil }
        return Int32(signed)
    }

    /// `k=v,k=v` with OPL `%hex%` escapes.
    static func parseTags(_ bytes: UnsafeBufferPointer<UInt8>, fail: (String) -> OPLError) throws -> [String: String] {
        var tags: [String: String] = [:]
        guard !bytes.isEmpty else { return tags }
        var start = 0
        while start <= bytes.count {
            var end = start
            while end < bytes.count, bytes[end] != UInt8(ascii: ",") { end += 1 }
            if end > start {
                let pair = UnsafeBufferPointer(rebasing: bytes[start..<end])
                guard let eq = pair.firstIndex(of: UInt8(ascii: "=")) else { throw fail("tag without '='") }
                let key = try unescape(UnsafeBufferPointer(rebasing: pair[..<eq]), fail: fail)
                let value = try unescape(UnsafeBufferPointer(rebasing: pair[(eq + 1)...]), fail: fail)
                tags[key] = value
            }
            start = end + 1
        }
        return tags
    }

    static func unescape(_ bytes: UnsafeBufferPointer<UInt8>, fail: (String) -> OPLError) throws -> String {
        guard bytes.contains(UInt8(ascii: "%")) else { return String(decoding: bytes, as: UTF8.self) }
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var i = 0
        while i < bytes.count {
            if bytes[i] == UInt8(ascii: "%") {
                var j = i + 1
                var scalar: UInt32 = 0
                while j < bytes.count, bytes[j] != UInt8(ascii: "%") {
                    guard let h = hexValue(bytes[j]), scalar < 0x11_0000 else { throw fail("bad % escape") }
                    scalar = scalar << 4 | UInt32(h)
                    j += 1
                }
                guard j < bytes.count, j > i + 1, let u = Unicode.Scalar(scalar) else { throw fail("bad % escape") }
                out.append(contentsOf: Array(String(Character(u)).utf8))
                i = j + 1
            } else {
                out.append(bytes[i])
                i += 1
            }
        }
        return String(decoding: out, as: UTF8.self)
    }

    static func hexValue(_ c: UInt8) -> UInt8? {
        switch c {
        case 0x30...0x39: c - 0x30
        case 0x41...0x46: c - 0x41 + 10
        case 0x61...0x66: c - 0x61 + 10
        default: nil
        }
    }

    /// `n<id>x<lon>y<lat>,…`; an absent location is `x` and `y` with no number.
    static func parseNodes(_ bytes: UnsafeBufferPointer<UInt8>, fail: (String) -> OPLError) throws -> [OPLWay.NodeRef] {
        var nodes: [OPLWay.NodeRef] = []
        guard !bytes.isEmpty else { return nodes }
        var start = 0
        while start < bytes.count {
            var end = start
            while end < bytes.count, bytes[end] != UInt8(ascii: ",") { end += 1 }
            let ref = UnsafeBufferPointer(rebasing: bytes[start..<end])
            guard ref.count >= 2, ref[0] == UInt8(ascii: "n") else { throw fail("bad node reference") }
            let x = ref.firstIndex(of: UInt8(ascii: "x"))
            let idEnd = x ?? ref.count
            guard let id = parseInteger(UnsafeBufferPointer(rebasing: ref[1..<idEnd])) else { throw fail("bad node id") }
            var location: RoadPoint?
            if let x {
                guard let y = ref[x...].firstIndex(of: UInt8(ascii: "y")) else { throw fail("node \(id): x without y") }
                let lonText = UnsafeBufferPointer(rebasing: ref[(x + 1)..<y])
                let latText = UnsafeBufferPointer(rebasing: ref[(y + 1)...])
                if !lonText.isEmpty || !latText.isEmpty {
                    guard let lon = parseE7(lonText), let lat = parseE7(latText) else { throw fail("node \(id): bad location") }
                    location = RoadPoint(latE7: lat, lonE7: lon)
                }
            }
            nodes.append(OPLWay.NodeRef(id: id, location: location))
            start = end + 1
        }
        return nodes
    }
}
