import Foundation
import Testing

/// Source-level checks for invariants the type system can't enforce.
///
/// Reads the repository through `#filePath`, so it runs on the Mac with
/// `swift test` like the rest of Core's suite. It inspects App sources as
/// text; Core still imports nothing from the app.
@Suite("Repository invariants")
struct RepositoryInvariantTests {
    /// `.../Core/Tests/DriveLoggerCoreTests/<this file>` → repository root.
    static let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    static func swiftFiles(under relativePath: String) throws -> [URL] {
        let directory = repositoryRoot.appendingPathComponent(relativePath)
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else {
            return []
        }
        return enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }

    /// Path relative to the repository root, `/`-separated.
    static func relativePath(of file: URL) -> String {
        let root = repositoryRoot.standardizedFileURL.path
        let path = file.standardizedFileURL.path
        guard path.hasPrefix(root + "/") else { return path }
        return String(path.dropFirst(root.count + 1))
    }

    // MARK: Writes to the adapter

    /// The one file allowed to write to a characteristic, by repository
    /// path: another file that happens to be called `BLETransport.swift` is
    /// not exempt (R1-3).
    static let writerPath = "App/Sources/Link/BLETransport.swift"

    /// Any mention of `writeValue` as a word: a call with or without a
    /// space before the parenthesis, or an unapplied method reference
    /// (`let write = peripheral.writeValue`).
    ///
    /// Simple (ASCII-style) word boundaries: with Swift's default Unicode
    /// boundaries (UAX #29) `peripheral.writeValue` is a single word, and
    /// `\b` would never match after the dot.
    static var writeValuePattern: Regex<Substring> { /\bwriteValue\b/.wordBoundaryKind(.simple) }

    /// L2CAP channels are a second byte path to the adapter that bypasses
    /// the characteristic entirely. Nothing may open one.
    static var l2capPattern: Regex<Substring> { /\bopenL2CAPChannel\b/.wordBoundaryKind(.simple) }

    /// `text` with `//` comments removed (line by line; good enough for
    /// source we write ourselves, where `//` never appears in a string that
    /// matters here).
    static func strippingLineComments(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            guard let range = line.range(of: "//") else { return String(line) }
            return String(line[..<range.lowerBound])
        }.joined(separator: "\n")
    }

    /// Why `text` (the file at `path`) breaks the write invariant, or empty.
    static func writeViolations(in text: String, path: String) -> [String] {
        let code = strippingLineComments(text)
        var problems: [String] = []
        if code.contains(l2capPattern) {
            problems.append("\(path) opens an L2CAP channel; only BLETransport.send may write to the adapter")
        }
        let writes = code.matches(of: writeValuePattern).map(\.range)
        guard !writes.isEmpty else { return problems }
        guard path == writerPath else {
            return problems + ["\(path) mentions writeValue; only BLETransport.send may write to the adapter"]
        }
        guard let body = functionBody(named: "send", in: code) else {
            return problems + ["\(path) has no func send, yet mentions writeValue"]
        }
        if writes.contains(where: { !body.contains($0.lowerBound) }) {
            problems.append("\(path) mentions writeValue outside func send")
        }
        return problems
    }

    /// The range of the first `func <name>(`'s body, braces matched.
    static func functionBody(named name: String, in code: String) -> Range<String.Index>? {
        guard let declaration = code.range(of: "func \(name)("),
              let open = code[declaration.upperBound...].firstIndex(of: "{") else { return nil }
        var depth = 0
        var index = open
        while index < code.endIndex {
            switch code[index] {
            case "{": depth += 1
            case "}":
                depth -= 1
                if depth == 0 { return open..<code.index(after: index) }
            default: break
            }
            index = code.index(after: index)
        }
        return nil
    }

    // ValidatedELMCommand can only come from ELMCommandPolicy, but App code
    // holding the CBPeripheral could still write to it directly and bypass
    // the read-only guard. Only BLETransport.send may write.
    @Test("Only BLETransport.send writes to the adapter; nothing opens an L2CAP channel")
    func onlyBLETransportWritesToPeripheral() throws {
        let files = try Self.swiftFiles(under: "App")
        #expect(!files.isEmpty, "App not found from \(Self.repositoryRoot.path)")

        for file in files {
            let path = Self.relativePath(of: file)
            let text = try String(contentsOf: file, encoding: .utf8)
            for problem in Self.writeViolations(in: text, path: path) {
                Issue.record(Comment(rawValue: problem))
            }
        }
    }

    @Test("BLETransport.send actually contains the write the check is about")
    func writerExists() throws {
        let url = Self.repositoryRoot.appendingPathComponent(Self.writerPath)
        let code = Self.strippingLineComments(try String(contentsOf: url, encoding: .utf8))
        let body = try #require(Self.functionBody(named: "send", in: code))
        #expect(code[body].contains(Self.writeValuePattern))
    }

    // R1-3: the checker itself, on inputs the old substring check missed.
    @Test("The write check catches spacing, method references, L2CAP and look-alike paths", arguments: [
        ("App/Sources/Link/Other.swift", "peripheral.writeValue (data, for: c, type: .withResponse)"),
        ("App/Sources/Link/Other.swift", "let write = peripheral.writeValue\nwrite(data, c, .withResponse)"),
        ("App/Sources/Link/Other.swift", "peripheral.openL2CAPChannel(0x80)"),
        ("App/Sources/Sensors/BLETransport.swift", "peripheral.writeValue(data, for: c, type: .withResponse)"),
        ("App/Sources/Link/BLETransport.swift", "func helper() { peripheral.writeValue(data, for: c, type: .withResponse) }\nfunc send() { }"),
        ("App/Sources/Link/BLETransport.swift", "func send() { peripheral.openL2CAPChannel(0x80) }"),
    ])
    func checkerCatches(path: String, source: String) {
        #expect(!Self.writeViolations(in: source, path: path).isEmpty)
    }

    @Test("The write check accepts the one allowed write and comments")
    func checkerAccepts() {
        let transport = """
            // writeValue is only called below.
            func send(_ command: Int) async throws -> Double {
                queue.async { if true { peripheral.writeValue(data, for: c, type: .withResponse) } }
                return 0
            }
            func other() {}
            """
        #expect(Self.writeViolations(in: transport, path: Self.writerPath).isEmpty)
        #expect(Self.writeViolations(in: "// never call writeValue here", path: "App/Sources/Link/OBDLinkService.swift").isEmpty)
    }
}
